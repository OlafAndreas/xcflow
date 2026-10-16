import Foundation
import Testing
@testable import xcflow

struct WorkflowSyncTests {
    private func plan(desired: URL, snapshot: URL) async throws -> (SyncPlan, DryRunServer) {
        let server = try DryRunServer(snapshot: snapshot, desired: desired)
        let sync = WorkflowSync(client: AppStoreConnectClient(dryRun: server), root: desired)
        return (try await sync.plan(), server)
    }

    @Test func unchangedFilesPlanNothing() async throws {
        let snapshot = try Fixtures.standard()
        let (plan, _) = try await plan(desired: try Fixtures.standard(), snapshot: snapshot)
        #expect(plan.errors.isEmpty)
        #expect(plan.changes.isEmpty)
        #expect(plan.unchanged == 2)
    }

    @Test func displayLabelsAreIgnored() throws {
        let withLabels = try WorkflowDefinition(fileJSON: Fixtures.workflow(id: Fixtures.nightlyID, name: "Nightly tests"))
        let rendered = WorkflowSync.canonical(withLabels.attributes)
        #expect(!rendered.contains("runtimeName"))
        #expect(!rendered.contains("deviceTypeName"))
        #expect(rendered.contains("runtimeIdentifier"))
    }

    @Test func canonicalDoesNotEscapeSlashes() {
        #expect(WorkflowSync.canonical(["timezone": "Europe/Oslo"]) == #"{"timezone":"Europe/Oslo"}"#)
    }

    @Test func editCreateAndDeleteArePlannedAndSent() async throws {
        let snapshot = try Fixtures.standard()
        let desired = try Fixtures.makeFolder([
            "com.example.app/nightly-tests.json": Fixtures.workflow(id: Fixtures.nightlyID, name: "Nightly tests", hour: 6),
            "com.example.app/weekly.json": Fixtures.workflow(id: nil, name: "Weekly")
        ])
        let (plan, server) = try await plan(desired: desired, snapshot: snapshot)
        #expect(plan.errors.isEmpty)
        #expect(plan.markdown.contains("1 to create, 1 to update, 1 to delete, 0 unchanged."))
        #expect(plan.markdown.contains(#""timezone":"Europe/Oslo""#))

        let sync = WorkflowSync(client: AppStoreConnectClient(dryRun: server), root: desired)
        var report: [String] = []
        try await sync.apply(plan) { report.append($0) }
        let writes = await server.log.filter { !$0.hasPrefix("GET") }.map { $0.components(separatedBy: "\n")[0] }
        #expect(writes.sorted() == ["DELETE /v1/ciWorkflows/\(Fixtures.releaseID)", "PATCH /v1/ciWorkflows/\(Fixtures.nightlyID)", "POST /v1/ciWorkflows"])
        #expect(report.contains { $0.contains("Created **Weekly**") })
    }

    @Test func invalidFilesAreReported() async throws {
        let snapshot = try Fixtures.standard()
        var newWithoutVersions = Fixtures.workflow(id: nil, name: "Weekly")
        newWithoutVersions["xcodeVersion"] = NSNull()
        let desired = try Fixtures.makeFolder([
            "com.example.app/nightly-tests.json": Fixtures.workflow(id: Fixtures.nightlyID, name: "Nightly tests"),
            "com.example.app/duplicate.json": Fixtures.workflow(id: Fixtures.releaseID, name: "Nightly tests"),
            "com.example.app/weekly.json": newWithoutVersions
        ])
        let (plan, _) = try await plan(desired: desired, snapshot: snapshot)
        #expect(plan.errors.contains { $0.contains("Several files use the workflow name") })
        #expect(plan.errors.contains { $0.contains("a new workflow needs both xcodeVersion and macOsVersion") })
        #expect(plan.changes.isEmpty)
    }

    @Test func exportWritesDriftIntoFiles() async throws {
        let live = try Fixtures.makeFolder([
            "com.example.app/nightly-tests.json": Fixtures.workflow(id: Fixtures.nightlyID, name: "Nightly tests", hour: 3),
            "com.example.app/hotfix.json": Fixtures.workflow(id: "00000000-0000-0000-0000-000000000003", name: "Hotfix")
        ])
        let repo = try Fixtures.standard()
        let server = try DryRunServer(snapshot: live, desired: repo)
        _ = try await WorkflowSync(client: AppStoreConnectClient(dryRun: server), root: repo).export(bundleIDs: [])

        let files = try FileManager.default.contentsOfDirectory(atPath: repo.appending(path: "com.example.app").path(percentEncoded: false)).sorted()
        #expect(files == ["hotfix.json", "nightly-tests.json"])
        let nightly = try String(contentsOf: repo.appending(path: "com.example.app/nightly-tests.json"), encoding: .utf8)
        #expect(nightly.contains(#""hour" : 3"#))
        #expect(await server.log.allSatisfy { $0.hasPrefix("GET") })
    }

    @Test func slugs() {
        #expect(WorkflowSync.slug("Deploy on \"release*\"-tag") == "deploy-on-release-tag")
        #expect(WorkflowSync.slug("!!!") == "workflow")
    }
}
