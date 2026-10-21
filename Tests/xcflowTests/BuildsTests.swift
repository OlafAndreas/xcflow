import Foundation
import Testing
@testable import xcflow

@Suite(.serialized)
struct BuildsTests {
    private static let trener = Product(id: "prod-1", name: "Trener123", bundleID: "com.example.app")
    private static let other = Product(id: "prod-2", name: "Other", bundleID: "com.other.app")

    private let builds = Builds(scope: { _ in [BuildsTests.trener] })

    private static func run(_ id: String, number: Int, workflow: String = "wf-1") -> JSON {
        [
            "type": "ciBuildRuns",
            "id": id,
            "attributes": ["number": number, "completionStatus": "SUCCEEDED", "createdDate": "2026-10-20T10:00:00Z"],
            "relationships": ["workflow": ["data": ["type": "ciWorkflows", "id": workflow]]]
        ]
    }

    private static var workflowJSON: JSON { ["type": "ciWorkflows", "id": "wf-1", "attributes": ["name": "Nightly tests"]] }

    private static var table: [String: [CannedResponse]] { [
        "GET /v1/ciProducts/prod-1/buildRuns": [.json(["data": [run("run-11", number: 11), run("run-12", number: 12)], "included": [workflowJSON]])],
        "GET /v1/ciProducts/prod-2/buildRuns": [.json(["data": [run("run-7", number: 7, workflow: "wf-2")]])],
        "GET /v1/ciProducts/prod-1/workflows": [.json(["data": [workflowJSON]])],
        "GET /v1/ciProducts/prod-2/workflows": [.json(["data": [["type": "ciWorkflows", "id": "wf-2", "attributes": ["name": "Nightly tests"]]]])],
        "GET /v1/ciWorkflows/wf-1": [.json(["data": ["type": "ciWorkflows", "id": "wf-1", "attributes": ["name": "Nightly tests"], "relationships": ["repository": ["data": ["type": "scmRepositories", "id": "repo-1"]]]]])],
        "GET /v1/scmRepositories/repo-1/gitReferences": [.json(["data": [
            ["type": "scmGitReferences", "id": "ref-dev", "attributes": ["name": "develop", "kind": "BRANCH", "isDeleted": false]],
            ["type": "scmGitReferences", "id": "ref-main", "attributes": ["name": "main", "kind": "BRANCH", "isDeleted": false]]
        ]])],
        "POST /v1/ciBuildRuns": [.json(["data": ["type": "ciBuildRuns", "id": "run-12", "attributes": ["number": 12]]])]
    ] }

    @Test func listBuildsShowsTheScopedProductsNewestFirst() async throws {
        CannedAPI.reset(Self.table)
        let output = try await builds.listBuilds(try CannedAPI.client(), workflow: nil, branch: nil, limit: 10)
        let lines = output.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.first?.hasPrefix("#12 ") == true)
        #expect(lines.last?.hasPrefix("#11 ") == true)
        #expect(!CannedAPI.requests.contains { $0.path.contains("prod-2") })
    }

    @Test func buildNumbersResolveOnlyInsideTheScope() async throws {
        CannedAPI.reset(Self.table)
        do {
            _ = try await builds.getBuild(try CannedAPI.client(), build: "7")
            Issue.record("Expected build #7 to be out of scope")
        } catch ToolError.notFound(let message) {
            #expect(message == "No build number 7 found.")
        }
        #expect(!CannedAPI.requests.contains { $0.path.contains("prod-2") })
    }

    @Test func startPostsTheWorkflowAndTheGitReference() async throws {
        CannedAPI.reset(Self.table)
        let started = try await builds.start(try CannedAPI.client(), workflow: "Nightly tests", reference: "main", clean: true)
        #expect(started.runID == "run-12")

        let posts = CannedAPI.requests.filter { $0.method == "POST" && $0.path == "/v1/ciBuildRuns" }
        try #require(posts.count == 1)
        let data = try #require(posts[0].json?["data"] as? JSON)
        let relationships = data["relationships"] as? JSON
        #expect(((relationships?["workflow"] as? JSON)?["data"] as? JSON)?["id"] as? String == "wf-1")
        #expect(((relationships?["sourceBranchOrTag"] as? JSON)?["data"] as? JSON)?["id"] as? String == "ref-main")
        #expect(((relationships?["sourceBranchOrTag"] as? JSON)?["data"] as? JSON)?["type"] as? String == "scmGitReferences")
        #expect(data.attributes["clean"] as? Bool == true)
    }

    @Test func startBuildTextIsUnchanged() async throws {
        CannedAPI.reset(Self.table)
        let text = try await builds.startBuild(try CannedAPI.client(), workflow: "Nightly tests", branch: "main", clean: nil)
        #expect(text == "Started build #12 of Nightly tests (Trener123 (com.example.app)) on main. Id: run-12")
    }
}
