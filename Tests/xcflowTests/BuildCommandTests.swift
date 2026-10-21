import Foundation
import Testing
@testable import xcflow

private final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var outLines: [String] = []
    private var errLines: [String] = []

    var out: [String] {
        lock.withLock { outLines }
    }

    var err: [String] {
        lock.withLock { errLines }
    }

    func addOut(_ line: String) {
        lock.withLock { outLines.append(line) }
    }

    func addErr(_ line: String) {
        lock.withLock { errLines.append(line) }
    }
}

extension CannedAPISuites {
    @Suite struct BuildCommandTests {
        private static let runKey = "GET /v1/ciBuildRuns/run-12"

        private static func poll(_ progress: String, status: String? = nil) -> CannedResponse {
            var attributes: [String: Any] = ["number": 12, "executionProgress": progress]
            if let status {
                attributes["completionStatus"] = status
                attributes["startedDate"] = "2026-10-20T10:00:00Z"
                attributes["finishedDate"] = "2026-10-20T10:12:00Z"
            }
            return .json(["data": ["type": "ciBuildRuns", "id": "run-12", "attributes": attributes]])
        }

        private static var workflowJSON: JSON { ["type": "ciWorkflows", "id": "wf-1", "attributes": ["name": "Nightly tests"]] }

        private static func table(polls: [CannedResponse]) -> [String: [CannedResponse]] { [
            "GET /v1/ciProducts": [.json([
                "data": [["type": "ciProducts", "id": "prod-1", "attributes": ["name": "Trener123"], "relationships": ["app": ["data": ["type": "apps", "id": "app-1"]]]]],
                "included": [["type": "apps", "id": "app-1", "attributes": ["bundleId": "com.example.app"]]]
            ])],
            "GET /v1/ciProducts/prod-1/buildRuns": [.json(["data": [["type": "ciBuildRuns", "id": "run-12", "attributes": ["number": 12]]]])],
            "GET /v1/ciProducts/prod-1/workflows": [.json(["data": [workflowJSON]])],
            "GET /v1/ciWorkflows/wf-1": [.json(["data": ["type": "ciWorkflows", "id": "wf-1", "attributes": ["name": "Nightly tests"], "relationships": ["repository": ["data": ["type": "scmRepositories", "id": "repo-1"]]]]])],
            "GET /v1/scmRepositories/repo-1/gitReferences": [.json(["data": [
                ["type": "scmGitReferences", "id": "ref-main", "attributes": ["name": "main", "kind": "BRANCH", "isDeleted": false]],
                ["type": "scmGitReferences", "id": "ref-v1", "attributes": ["name": "v1", "kind": "TAG", "isDeleted": false]]
            ]])],
            "POST /v1/ciBuildRuns": [.json(["data": ["type": "ciBuildRuns", "id": "run-12", "attributes": ["number": 12]]])],
            runKey: polls,
            "GET /v1/ciBuildRuns/run-12/actions": [.json(["data": []])]
        ] }

        private static func root() throws -> String {
            let root = FileManager.default.temporaryDirectory.appending(path: "xcflow-command-\(UUID().uuidString)/XcodeCloud")
            try FileManager.default.createDirectory(at: root.appending(path: "com.example.app"), withIntermediateDirectories: true)
            return root.path(percentEncoded: false)
        }

        private func run(
            _ command: String, _ arguments: [String], polls: [CannedResponse] = [poll("COMPLETE", status: "SUCCEEDED")],
            extra: [String: [CannedResponse]] = [:], output: Output
        ) async throws -> Int32 {
            CannedAPI.reset(Self.table(polls: polls).merging(extra) { _, new in new })
            return await BuildCommand.run(
                command, arguments: arguments + ["--root", try Self.root()], client: try CannedAPI.client(),
                pollEvery: .milliseconds(1), contactLimit: .milliseconds(200),
                out: { output.addOut($0) }, err: { output.addErr($0) }
            )
        }

        @Test func runWithoutWaitPrintsTheStartedLine() async throws {
            let output = Output()
            let code = try await run("run", ["Nightly tests", "--branch", "main"], output: output)
            #expect(code == 0)
            #expect(output.out == ["Started build #12 of Nightly tests (Trener123 (com.example.app)) on main. Id: run-12"])
            #expect(output.err.isEmpty)
        }

        @Test func runWithWaitPrintsStartedThenSummary() async throws {
            let output = Output()
            let code = try await run("run", ["Nightly tests", "--branch", "main", "--wait"], polls: [Self.poll("PENDING"), Self.poll("RUNNING"), Self.poll("COMPLETE", status: "SUCCEEDED")], output: output)
            #expect(code == 0)
            #expect(output.out.count == 2)
            #expect(output.out.first?.hasPrefix("Started build #12") == true)
            #expect(output.out.last?.hasPrefix("Build #12 – SUCCEEDED") == true)
            #expect(output.err.count == 3)
            #expect(output.err.prefix(2) == ["Build #12 queued", "Build #12 running"])
            #expect(output.err.last?.hasPrefix("Build #12 finished: SUCCEEDED") == true)
        }

        @Test func aFailedBuildExitsOne() async throws {
            let output = Output()
            let code = try await run("run", ["Nightly tests", "--branch", "main", "--wait"], polls: [Self.poll("RUNNING"), Self.poll("COMPLETE", status: "FAILED")], output: output)
            #expect(code == 1)
            #expect(output.out.last?.hasPrefix("Build #12 – FAILED") == true)
        }

        @Test func buildWithoutWaitIsAReport() async throws {
            let output = Output()
            let code = try await run("build", ["12"], polls: [Self.poll("COMPLETE", status: "FAILED")], output: output)
            #expect(code == 0)
            #expect(output.out.first?.hasPrefix("Build #12 – FAILED") == true)
        }

        @Test func buildWaitOnAFinishedBuildReturnsItsStatusAtOnce() async throws {
            let output = Output()
            let code = try await run("build", ["#12", "--wait"], polls: [Self.poll("COMPLETE", status: "FAILED")], output: output)
            #expect(code == 1)
            #expect(output.err.count == 1)
        }

        @Test func branchAndTagAreExclusive() async throws {
            let both = Output()
            #expect(try await run("run", ["Nightly tests", "--branch", "main", "--tag", "v1"], output: both) == 64)
            #expect(both.err.first?.isEmpty == false)
            #expect(CannedAPI.requests.isEmpty)

            let neither = Output()
            #expect(try await run("run", ["Nightly tests"], output: neither) == 64)
            #expect(CannedAPI.requests.isEmpty)
        }

        @Test func usageErrorsExitSixtyFourBeforeAnyRequest() async throws {
            for (command, arguments) in [("builds", ["--limit", "x"]), ("build", []), ("logs", ["12", "--bogus"]), ("build", ["12", "--timeout"]), ("builds", ["--all", "--product", "x"])] {
                let output = Output()
                #expect(try await run(command, arguments, output: output) == 64)
                #expect(CannedAPI.requests.isEmpty)
            }
        }

        @Test func tagAndBranchLookTheSame() async throws {
            let output = Output()
            let code = try await run("run", ["Nightly tests", "--tag", "v1", "--clean"], output: output)
            #expect(code == 0)
            let post = try #require(CannedAPI.requests.first { $0.method == "POST" })
            let data = try #require(post.json?["data"] as? JSON)
            let relationships = data["relationships"] as? JSON
            #expect(((relationships?["sourceBranchOrTag"] as? JSON)?["data"] as? JSON)?["id"] as? String == "ref-v1")
            #expect(data.attributes["clean"] as? Bool == true)
        }

        @Test func timeoutExitsOneTwentyFour() async throws {
            let output = Output()
            let code = try await run("build", ["12", "--wait", "--timeout", "0.0005"], polls: [Self.poll("RUNNING")], output: output)
            #expect(code == 124)
            #expect(output.err.last == "Timed out after 0.0005 minutes; build #12 is still running. Id: run-12")
        }

        @Test func lostContactExitsTwo() async throws {
            let output = Output()
            let code = try await run("build", ["12", "--wait"], polls: [.status(500)], output: output)
            #expect(code == 2)
            #expect(output.err.last?.hasPrefix("Lost contact with App Store Connect for ") == true)
            #expect(output.err.last?.hasSuffix("; build #12 may still be running. Id: run-12") == true)
        }

        @Test func lostContactAfterRunShowsTheStartedNumber() async throws {
            let output = Output()
            let code = try await run("run", ["Nightly tests", "--branch", "main", "--wait"], polls: [.status(500)], output: output)
            #expect(code == 2)
            #expect(output.err.last?.hasSuffix("; build #12 may still be running. Id: run-12") == true)
        }

        @Test func lostContactOnAnIDShowsTheID() async throws {
            let output = Output()
            let code = try await run("build", ["run-12", "--wait"], polls: [.status(500)], output: output)
            #expect(code == 2)
            #expect(output.err.last?.hasSuffix("; build #run-12 may still be running. Id: run-12") == true)
        }

        @Test func aFailingSummaryKeepsTheStatusExit() async throws {
            let output = Output()
            let code = try await run("build", ["#12", "--wait"], polls: [Self.poll("COMPLETE", status: "FAILED"), .status(404)], output: output)
            #expect(code == 1)
            #expect(output.out.isEmpty)
            #expect(output.err.last?.hasPrefix("Couldn't fetch the summary: ") == true)
        }

        @Test func aTimeoutAboveAWeekIsAUsageError() async throws {
            for timeout in ["10081", "1e40"] {
                let output = Output()
                #expect(try await run("build", ["12", "--wait", "--timeout", timeout], output: output) == 64)
                #expect(output.err.first == "--timeout takes at most 10080 minutes (one week), not \"\(timeout)\".")
                #expect(CannedAPI.requests.isEmpty)
            }
        }

        @Test func runOnABranchThatIsNotPushedExitsTwo() async throws {
            let output = Output()
            let code = try await run("run", ["Nightly tests", "--branch", "nope"], output: output)
            #expect(code == 2)
            #expect(output.err.first == "run failed: No branch or tag named \"nope\" in the repository. Is it pushed?")
            #expect(!CannedAPI.requests.contains { $0.method == "POST" })
        }

        @Test func logsPrintsEachSelectedAction() async throws {
            let output = Output()
            let code = try await run("logs", ["12"], extra: [
                "GET /v1/ciBuildRuns/run-12/actions": [.json(["data": [
                    ["type": "ciBuildActions", "id": "act-1", "attributes": ["name": "Test - iOS", "completionStatus": "FAILED"]],
                    ["type": "ciBuildActions", "id": "act-2", "attributes": ["name": "Archive", "completionStatus": "SUCCEEDED"]]
                ]])],
                "GET /v1/ciBuildActions/act-1/artifacts": [.json(["data": []])]
            ], output: output)
            #expect(code == 0)
            #expect(output.out == ["## Test - iOS\nNo log bundle (the action may have been skipped)."])
            #expect(output.err.isEmpty)
        }

        @Test func buildsListsTheScopedBuilds() async throws {
            let output = Output()
            let code = try await run("builds", ["--limit", "5"], output: output)
            #expect(code == 0)
            #expect(output.out.first?.hasPrefix("#12 ") == true)
        }

        @Test func errorsExitTwo() async throws {
            let output = Output()
            let code = try await run("run", ["Nope", "--branch", "main"], output: output)
            #expect(code == 2)
            #expect(output.err.first == "run failed: No workflow matches \"Nope\". The workflows are the files in XcodeCloud/<bundle id>/.")
            #expect(output.err.first?.contains("list_workflows") == false)
        }
    }
}
