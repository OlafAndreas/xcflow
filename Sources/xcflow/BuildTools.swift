import Foundation

extension XcodeCloudTools {
    func listWorkflows(_ client: AppStoreConnectClient, product: String?) async throws -> String {
        let products = try await builds.products(client, matching: product)
        let workflows = try await builds.workflows(client, in: products)
        return products.map { product in
            let lines = workflows.filter { $0.product.id == product.id }.map { workflow in
                let state = workflow.json.attributes["isEnabled"] as? Bool == false ? " [disabled]" : ""
                return "  - \(workflow.name)\(state)  id=\(workflow.id)"
            }
            return ([product.label] + (lines.isEmpty ? ["  (no workflows)"] : lines)).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

extension Builds {
    func listBuilds(_ client: AppStoreConnectClient, workflow reference: String?, branch: String?, limit: Int) async throws -> String {
        let paths: [String]
        if let reference {
            paths = ["/v1/ciWorkflows/\(try await workflow(client, reference).id)/buildRuns"]
        } else {
            paths = try await products(client).map { "/v1/ciProducts/\($0.id)/buildRuns" }
        }

        let fetchLimit = branch == nil ? limit : 200
        var runs: [JSON] = []
        var included: [JSON] = []
        for path in paths {
            let page = try await client.getAll(path, query: [
                "sort": "-number",
                "limit": String(min(fetchLimit, 200)),
                "include": "workflow,sourceBranchOrTag,pullRequest",
                "fields[ciWorkflows]": "name",
                "fields[scmGitReferences]": "name",
                "fields[scmPullRequests]": "number,sourceBranchName"
            ], limit: fetchLimit)
            runs += page.data
            included += page.included
        }

        let names = Dictionary(included.map { ($0.id, $0.string("name") ?? "?") }) { first, _ in first }
        let lines = runs
            .filter { run in branch == nil || Self.source(of: run, included: included).branch == branch }
            .sorted { ($0.attributes["number"] as? Int ?? 0) > ($1.attributes["number"] as? Int ?? 0) }
            .prefix(limit)
            .map { run in
                let attributes = run.attributes
                let status = attributes["completionStatus"] as? String ?? attributes["executionProgress"] as? String ?? "?"
                let workflowName = run.relationshipID("workflow").flatMap { names[$0] } ?? "?"
                let branchName = Self.source(of: run, included: included).label
                let duration = Format.duration(from: attributes["startedDate"], to: attributes["finishedDate"]).map { " (\($0))" } ?? ""
                return "#\(attributes["number"] ?? "?") \(status)  \(workflowName)  \(branchName)  \(Format.date(attributes["createdDate"]))\(duration)"
            }
        return lines.isEmpty ? "No builds found." : lines.joined(separator: "\n")
    }

    func getBuild(_ client: AppStoreConnectClient, build reference: String) async throws -> String {
        let runID = try await buildRunID(client, reference)
        let response = try await client.get("/v1/ciBuildRuns/\(runID)", query: ["include": "workflow,sourceBranchOrTag,product,pullRequest"])
        let run = response["data"] as? JSON ?? [:]
        let included = response["included"] as? [JSON] ?? []
        let attributes = run.attributes
        let commit = attributes["sourceCommit"] as? JSON ?? [:]
        let author = (commit["author"] as? JSON)?["displayName"] as? String ?? "?"

        func includedName(_ relationship: String) -> String {
            run.relationshipID(relationship).flatMap { id in included.first { $0.id == id }?.string("name") } ?? "?"
        }

        var lines = [
            "Build #\(attributes["number"] ?? "?") – \(attributes["completionStatus"] as? String ?? attributes["executionProgress"] as? String ?? "?")",
            "Workflow: \(includedName("workflow"))  Product: \(includedName("product"))",
            "Branch: \(Self.source(of: run, included: included).label)  Started: \(Format.date(attributes["startedDate"]))  Reason: \(attributes["startReason"] as? String ?? "?")",
            "Commit: \((commit["commitSha"] as? String)?.prefix(9) ?? "?") \(commit["message"] as? String ?? "") (\(author))",
            "Id: \(runID)"
        ]
        if let cancelReason = attributes["cancelReason"] as? String {
            lines.append("Cancelled: \(cancelReason)")
        }

        let actions = try await client.getAll("/v1/ciBuildRuns/\(runID)/actions").data
            .sorted { ($0.string("startedDate") ?? "~") < ($1.string("startedDate") ?? "~") }
        lines.append("\nActions:")
        for action in actions {
            let actionAttributes = action.attributes
            let status = actionAttributes["completionStatus"] as? String ?? actionAttributes["executionProgress"] as? String ?? "?"
            let duration = Format.duration(from: actionAttributes["startedDate"], to: actionAttributes["finishedDate"]).map { " (\($0))" } ?? ""
            lines.append("- \(action.string("name") ?? "?"): \(status)\(duration)")

            guard ["FAILED", "ERRORED"].contains(status) else {
                continue
            }
            lines += try await problems(client, actionID: action.id).map { "    \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    private static func source(of run: JSON, included: [JSON]) -> (branch: String?, label: String) {
        func find(_ relationship: String) -> JSON? {
            run.relationshipID(relationship).flatMap { id in included.first { $0.id == id } }
        }
        let pullRequest = find("pullRequest")
        let branch = find("sourceBranchOrTag")?.string("name") ?? pullRequest?.string("sourceBranchName")
        let prefix = switch (run.relationshipID("pullRequest"), pullRequest?.attributes["number"]) {
        case (nil, _): ""
        case (_, let number?): "PR #\(number) "
        case (_, nil): "PR "
        }
        return (branch, prefix + (branch ?? "(branch deleted)"))
    }

    private func problems(_ client: AppStoreConnectClient, actionID: String) async throws -> [String] {
        let issues = try await client.getAll("/v1/ciBuildActions/\(actionID)/issues", query: ["limit": "200"]).data
        let errors = issues.filter { $0.string("issueType") != "WARNING" }
        let warningCount = issues.count - errors.count

        var lines = errors.prefix(25).map { issue in
            let source = issue.attributes["fileSource"] as? JSON
            let path = (source?["path"] as? String).map { $0.replacingOccurrences(of: "file://\(Self.repositoryRoot)", with: "") }
            let location = path.map { "\($0):\(source?["lineNumber"] ?? "?") " } ?? ""
            return "\(issue.string("issueType") ?? "ISSUE"): \(location)\(issue.string("message") ?? "")"
        }
        if errors.count > 25 {
            lines.append("… \(errors.count - 25) more errors")
        }
        if warningCount > 0 {
            lines.append("(\(warningCount) warnings)")
        }

        let tests = try await client.getAll("/v1/ciBuildActions/\(actionID)/testResults", query: ["limit": "200"]).data
        let failures = tests.filter { ["FAILURE", "MIXED"].contains($0.string("status")) }
        lines += failures.prefix(25).map { test in
            let message = test.string("message").map { " – \($0)" } ?? ""
            return "TEST FAILED: \(test.string("className") ?? "?").\(test.string("name") ?? "?")\(message)"
        }
        if failures.count > 25 {
            lines.append("… \(failures.count - 25) more failing tests")
        }
        return lines
    }

    func startBuild(_ client: AppStoreConnectClient, workflow reference: String, branch: String, clean: Bool?) async throws -> String {
        try await start(client, workflow: reference, reference: branch, clean: clean).text
    }

    func start(_ client: AppStoreConnectClient, workflow reference: String, reference branch: String, clean: Bool?) async throws -> (text: String, runID: String) {
        let workflow = try await workflow(client, reference)
        let detail = try await client.get("/v1/ciWorkflows/\(workflow.id)", query: ["include": "repository", "fields[ciWorkflows]": "name,repository"])
        guard let repositoryID = (detail["data"] as? JSON)?.relationshipID("repository") else {
            throw ToolError.notFound("Workflow \(workflow.name) has no repository.")
        }

        let references = try await client.getAll(
            "/v1/scmRepositories/\(repositoryID)/gitReferences",
            query: ["limit": "200", "fields[scmGitReferences]": "name,kind,isDeleted"],
            until: { $0.string("name") == branch && $0.attributes["isDeleted"] as? Bool != true }
        ).data
        guard let gitReference = references.first(where: { $0.string("name") == branch && $0.attributes["isDeleted"] as? Bool != true }) else {
            throw ToolError.notFound("No branch or tag named \"\(branch)\" in the repository. Is it pushed?")
        }

        var attributes: JSON = [:]
        if let clean {
            attributes["clean"] = clean
        }
        let response = try await client.post("/v1/ciBuildRuns", body: [
            "data": [
                "type": "ciBuildRuns",
                "attributes": attributes,
                "relationships": [
                    "workflow": ["data": ["type": "ciWorkflows", "id": workflow.id]],
                    "sourceBranchOrTag": ["data": ["type": "scmGitReferences", "id": gitReference.id]]
                ]
            ] as JSON
        ])
        let run = response["data"] as? JSON ?? [:]
        return ("Started build #\(run.attributes["number"] ?? "?") of \(workflow.name) (\(workflow.product.label)) on \(branch). Id: \(run.id)", run.id)
    }
}
