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

    @Test func aRepoConfigNextToTheProductFoldersChangesNothing() async throws {
        let snapshot = try Fixtures.standard()
        let desired = try Fixtures.makeFolder([
            "xcflow.json": ["keyID": "ABC123"],
            "com.example.app/nightly-tests.json": Fixtures.workflow(id: Fixtures.nightlyID, name: "Nightly tests"),
            "com.example.app/release.json": Fixtures.workflow(id: Fixtures.releaseID, name: "Release")
        ])
        let (plan, _) = try await plan(desired: desired, snapshot: snapshot)
        #expect(plan.errors.isEmpty)
        #expect(plan.changes.isEmpty)
        #expect(plan.unchanged == 2)
        let sync = WorkflowSync(client: AppStoreConnectClient(dryRun: try DryRunServer(snapshot: snapshot, desired: desired)), root: desired)
        _ = try await sync.export(bundleIDs: [])
        #expect(FileManager.default.fileExists(atPath: desired.appending(path: "xcflow.json").path))
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
        #expect(plan.markdown.contains("- `scheduledStartCondition.schedule.hour`: `5` → `6`"))
        #expect(!plan.markdown.contains("before: {"))

        let sync = WorkflowSync(client: AppStoreConnectClient(dryRun: server), root: desired)
        var report: [String] = []
        try await sync.apply(plan) { report.append($0) }
        let writes = await server.log.filter { !$0.hasPrefix("GET") }.map { $0.components(separatedBy: "\n")[0] }
        #expect(writes.sorted() == ["DELETE /v1/ciWorkflows/\(Fixtures.releaseID)", "PATCH /v1/ciWorkflows/\(Fixtures.nightlyID)", "POST /v1/ciWorkflows"])
        #expect(report.first == "## Xcode Cloud apply\n")
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

    private func withFileRule(_ workflow: JSON, directory: Any) -> JSON {
        var workflow = workflow
        var attributes = workflow["attributes"] as? JSON ?? [:]
        attributes["branchStartCondition"] = [
            "autoCancel": true,
            "source": ["isAllMatch": true, "patterns": [JSON]()] as JSON,
            "filesAndFoldersRule": [
                "mode": "DO_NOT_START_IF_ALL_FILES_MATCH",
                "matchers": [
                    ["directory": directory, "fileExtension": "md", "fileName": NSNull()] as JSON,
                    ["directory": "docs", "fileExtension": NSNull(), "fileName": NSNull()] as JSON
                ]
            ] as JSON
        ] as JSON
        workflow["attributes"] = attributes
        return workflow
    }

    @Test func unsetMatcherDirectoryMatchesTheAPIsEmptyString() throws {
        let live = try WorkflowDefinition(fileJSON: withFileRule(Fixtures.workflow(id: Fixtures.nightlyID, name: "Nightly tests"), directory: ""))
        let file = try WorkflowDefinition(fileJSON: withFileRule(Fixtures.workflow(id: Fixtures.nightlyID, name: "Nightly tests"), directory: NSNull()))
        #expect(WorkflowSync.changedAttributes(from: live.attributes, to: file.attributes).isEmpty)
    }

    @Test func unsetMatcherDirectoryIsSentAsEmptyString() async throws {
        let snapshot = try Fixtures.standard()
        let desired = try Fixtures.makeFolder([
            "com.example.app/nightly-tests.json": Fixtures.workflow(id: Fixtures.nightlyID, name: "Nightly tests"),
            "com.example.app/release.json": Fixtures.workflow(id: Fixtures.releaseID, name: "Release"),
            "com.example.app/docs.json": withFileRule(Fixtures.workflow(id: nil, name: "Docs"), directory: NSNull())
        ])
        let (plan, server) = try await plan(desired: desired, snapshot: snapshot)
        try await WorkflowSync(client: AppStoreConnectClient(dryRun: server), root: desired).apply(plan) { _ in }
        let post = await server.log.first { $0.hasPrefix("POST") } ?? ""
        #expect(post.contains(#""directory" : """#))
        #expect(!post.contains(#""directory" : null"#))
    }

    @Test func differencesNameTheChangedKeys() {
        let before: JSON = ["schedule": ["hour": 5, "minute": 0] as JSON, "matchers": [["directory": "a"], ["directory": "b"]]]
        let after: JSON = ["schedule": ["hour": 6, "minute": 0] as JSON, "matchers": [["directory": "a"], ["directory": "c"]]]
        #expect(WorkflowSync.differences(before, after, path: "condition") == [
            .init(path: "condition.matchers[1].directory", before: #""b""#, after: #""c""#),
            .init(path: "condition.schedule.hour", before: "5", after: "6")
        ])
        let grown = WorkflowSync.differences(["a"], ["a", "b"], path: "list")
        #expect(grown == [.init(path: "list", before: #"["a"]"#, after: #"["a","b"]"#)])
    }

    @Test func changesToLockedWorkflowsAreFlagged() async throws {
        var locked = Fixtures.workflow(id: Fixtures.releaseID, name: "Release")
        var attributes = locked["attributes"] as? JSON ?? [:]
        attributes["isLockedForEditing"] = true
        locked["attributes"] = attributes
        let snapshot = try Fixtures.makeFolder([
            "com.example.app/nightly-tests.json": Fixtures.workflow(id: Fixtures.nightlyID, name: "Nightly tests"),
            "com.example.app/release.json": locked
        ])
        var lockedEdit = locked
        attributes["description"] = "Changed"
        lockedEdit["attributes"] = attributes
        let desired = try Fixtures.makeFolder([
            "com.example.app/nightly-tests.json": Fixtures.workflow(id: Fixtures.nightlyID, name: "Nightly tests", hour: 6),
            "com.example.app/release.json": lockedEdit
        ])
        let (plan, _) = try await plan(desired: desired, snapshot: snapshot)
        let sections = plan.markdown.components(separatedBy: "### ")
        #expect(sections.first { $0.hasPrefix("Update: Release") }?.contains("Restrict Editing") == true)
        #expect(sections.first { $0.hasPrefix("Update: Nightly tests") }?.contains("Restrict Editing") == false)
    }

    @Test func slugs() {
        #expect(WorkflowSync.slug("Deploy on \"release*\"-tag") == "deploy-on-release-tag")
        #expect(WorkflowSync.slug("!!!") == "workflow")
    }

    // The dry-run server gives every product the id "<ciProducts: bundle id>", so a manifest naming that id resolves to the product.
    private func emptyRepo() throws -> URL {
        try Fixtures.makeRepo().appending(path: "XcodeCloud", directoryHint: .isDirectory)
    }

    private func exportError(_ root: URL, snapshot: URL, bundleIDs: [String] = []) async -> String {
        do {
            let server = try DryRunServer(snapshot: snapshot, desired: root)
            _ = try await WorkflowSync(client: AppStoreConnectClient(dryRun: server), root: root).export(bundleIDs: bundleIDs)
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    @Test func exportFindsTheProductsThroughTheManifest() async throws {
        let live = try Fixtures.standard()
        let repo = try emptyRepo()
        try Fixtures.writeManifest(in: repo.deletingLastPathComponent(), project: "Example.xcodeproj", productIDs: ["<ciProducts: com.example.app>"])

        let server = try DryRunServer(snapshot: live, desired: repo)
        let report = try await WorkflowSync(client: AppStoreConnectClient(dryRun: server), root: repo).export(bundleIDs: [])

        let files = try FileManager.default.contentsOfDirectory(atPath: repo.appending(path: "com.example.app").path(percentEncoded: false)).sorted()
        #expect(files == ["nightly-tests.json", "release.json"])
        #expect(report.contains("Exported 2 workflows"))
    }

    @Test func exportWithoutAManifestExplainsTheFirstTimeSetup() async throws {
        let repo = try emptyRepo()
        try Fixtures.makeProject(in: repo.deletingLastPathComponent(), project: "Example.xcodeproj")
        let message = await exportError(repo, snapshot: try Fixtures.standard())
        #expect(message.contains("No Xcode Cloud manifest"))
        #expect(message.contains("Example.xcodeproj"))
        #expect(message.contains("Create Workflow"))
    }

    @Test func exportNamesAStaleManifest() async throws {
        let repo = try emptyRepo()
        try Fixtures.writeManifest(in: repo.deletingLastPathComponent(), project: "Example.xcodeproj", productIDs: ["<ciProducts: com.gone.app>"])
        let message = await exportError(repo, snapshot: try Fixtures.standard())
        #expect(message.contains("Example.xcodeproj/xcshareddata/xcodecloud/manifest.json"))
        #expect(message.contains("<ciProducts: com.gone.app>"))
        #expect(message.contains("xcflow export com.example.app"))
    }

    @Test func exportOfAnUnknownBundleIDListsTheApps() async throws {
        let message = await exportError(try emptyRepo(), snapshot: try Fixtures.standard(), bundleIDs: ["com.other.app"])
        #expect(message.contains("No app with bundle id com.other.app"))
        #expect(message.contains("com.example.app"))
    }
}
