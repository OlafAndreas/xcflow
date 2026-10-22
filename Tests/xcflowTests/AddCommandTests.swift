import Foundation
import Testing
@testable import xcflow

struct AddCommandTests {
    private let oslo = TimeZone(identifier: "Europe/Oslo")!

    /// An exported "Default" workflow building Example from develop, and Example.xcodeproj sharing the given schemes.
    private func repo(shared: [String] = ["Example"], platform: String = "IOS", files: [String: JSON]? = nil) throws -> URL {
        let defaultWorkflow: JSON = [
            "id": "AE86FE2E-B859-4E17-A7AE-4754195BAFFB",
            "repository": "example-app",
            "xcodeVersion": "Latest Release",
            "macOsVersion": "macOS Tahoe 26.4",
            "attributes": [
                "name": "Default",
                "containerFilePath": "Example.xcodeproj",
                "actions": [["actionType": "BUILD", "name": "Build", "platform": platform, "scheme": "Example", "destination": "ANY_IOS_DEVICE"]],
                "branchStartCondition": ["source": ["isAllMatch": false, "patterns": [["isPrefix": false, "pattern": "develop"]]]] as JSON,
            ] as JSON,
        ]
        let root = try Fixtures.makeFolder(files ?? ["com.example.app/default.json": defaultWorkflow])
        let schemes = root.deletingLastPathComponent().appending(path: "Example.xcodeproj/xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: schemes, withIntermediateDirectories: true)
        for name in shared {
            try Data("<Scheme/>".utf8).write(to: schemes.appending(path: "\(name).xcscheme"))
        }
        return root
    }

    private func written(_ root: URL, _ name: String) throws -> WorkflowDefinition {
        let data = try Data(contentsOf: root.appending(path: "com.example.app/\(name)"))
        return try WorkflowDefinition(fileJSON: try #require(JSONSerialization.jsonObject(with: data) as? JSON))
    }

    @Test func prChecksTestsTheSchemeOnEveryPullRequest() throws {
        let root = try repo()
        let lines = try AddCommand.add(.prChecks, root: root, product: nil, scheme: nil, name: nil, timeZone: oslo)
        #expect(lines.first == "Wrote XcodeCloud/com.example.app/pr-checks.json: \"PR checks\" tests Example on iOS for every pull request.")
        let definition = try written(root, "pr-checks.json")
        #expect(definition.id == nil)
        #expect(definition.repository == "example-app")
        #expect(definition.macOsVersion == "macOS Tahoe 26.4")
        #expect(definition.attributes["containerFilePath"] as? String == "Example.xcodeproj")
        #expect(definition.attributes["clean"] as? Bool == false)
        let condition = try #require(definition.attributes["pullRequestStartCondition"] as? JSON)
        #expect((condition["source"] as? JSON)?["isAllMatch"] as? Bool == true)
        let action = try #require((definition.attributes["actions"] as? [JSON])?.first)
        #expect(action["actionType"] as? String == "TEST")
        #expect(action["scheme"] as? String == "Example")
        let destination = try #require(((action["testConfiguration"] as? JSON)?["testDestinations"] as? [JSON])?.first)
        #expect(destination["deviceTypeIdentifier"] as? String == "com.apple.CoreSimulator.SimDeviceType.iPhone-17")
    }

    @Test func nightlyTestsRunFromTheBranchTheRepoBuilds() throws {
        let root = try repo()
        let lines = try AddCommand.add(.nightlyTests, root: root, product: nil, scheme: nil, name: nil, timeZone: oslo)
        #expect(lines.first?.hasSuffix("tests Example on iOS from develop every night at 03:00 Europe/Oslo.") == true)
        let condition = try #require(try written(root, "nightly-tests.json").attributes["scheduledStartCondition"] as? JSON)
        #expect((condition["schedule"] as? JSON)?["timezone"] as? String == "Europe/Oslo")
        #expect(((condition["source"] as? JSON)?["patterns"] as? [JSON])?.first?["pattern"] as? String == "develop")
    }

    @Test func testflightOnTagArchivesForTheAppStoreAndExplainsThePostAction() throws {
        let root = try repo()
        let lines = try AddCommand.add(.testflightOnTag, root: root, product: nil, scheme: nil, name: nil, timeZone: oslo)
        #expect(lines.last?.contains("TestFlight post-action") == true)
        let definition = try written(root, "testflight-on-tag.json")
        let patterns = ((definition.attributes["tagStartCondition"] as? JSON)?["source"] as? JSON)?["patterns"] as? [JSON]
        #expect(patterns?.first?["pattern"] as? String == "v")
        #expect(patterns?.first?["isPrefix"] as? Bool == true)
        let action = try #require((definition.attributes["actions"] as? [JSON])?.first)
        #expect(action["actionType"] as? String == "ARCHIVE")
        #expect(action["destination"] as? String == "ANY_IOS_DEVICE")
        #expect(action["buildDistributionAudience"] as? String == "APP_STORE_ELIGIBLE")
    }

    @Test func copiesTestDestinationsFromAnExistingTestAction() throws {
        var nightly = Fixtures.workflow(id: Fixtures.nightlyID, name: "Nightly tests")
        var attributes = nightly["attributes"] as! JSON
        var action = (attributes["actions"] as! [JSON])[0]
        action["testConfiguration"] = ["kind": "USE_SCHEME_SETTINGS", "testDestinations": [["kind": "SIMULATOR", "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Air", "runtimeIdentifier": "default"]]] as JSON
        attributes["actions"] = [action]
        nightly["attributes"] = attributes
        let root = try repo(files: ["com.example.app/nightly-tests.json": nightly])
        _ = try AddCommand.add(.prChecks, root: root, product: nil, scheme: nil, name: nil, timeZone: oslo)
        let copied = try #require((try written(root, "pr-checks.json").attributes["actions"] as? [JSON])?.first)
        let destination = ((copied["testConfiguration"] as? JSON)?["testDestinations"] as? [JSON])?.first
        #expect(destination?["deviceTypeIdentifier"] as? String == "com.apple.CoreSimulator.SimDeviceType.iPad-Air")
    }

    @Test func refusesANameAnotherWorkflowUses() throws {
        let root = try repo(files: ["com.example.app/nightly-tests.json": Fixtures.workflow(id: Fixtures.nightlyID, name: "Nightly tests")])
        #expect(throws: ToolError.self) {
            try AddCommand.add(.nightlyTests, root: root, product: nil, scheme: nil, name: nil, timeZone: oslo)
        }
        _ = try AddCommand.add(.nightlyTests, root: root, product: nil, scheme: nil, name: "Nightly UI tests", timeZone: oslo)
        #expect(try written(root, "nightly-ui-tests.json").name == "Nightly UI tests")
    }

    @Test func asksForASchemeWhenTheProjectNoLongerSharesTheOneInUse() throws {
        let root = try repo(shared: ["App", "Widgets"])
        #expect {
            try AddCommand.add(.prChecks, root: root, product: nil, scheme: nil, name: nil, timeZone: oslo)
        } throws: { error in
            error.localizedDescription.contains("Pick one with --scheme: App, Widgets.")
        }
        _ = try AddCommand.add(.prChecks, root: root, product: nil, scheme: "Widgets", name: nil, timeZone: oslo)
        #expect((try written(root, "pr-checks.json").attributes["actions"] as? [JSON])?.first?["scheme"] as? String == "Widgets")
    }

    @Test func asksForAProductWhenThereAreSeveral() throws {
        let workflow = Fixtures.workflow(id: Fixtures.nightlyID, name: "Nightly tests")
        let root = try repo(files: ["com.example.app/nightly-tests.json": workflow, "com.example.widget/nightly-tests.json": workflow])
        #expect {
            try AddCommand.add(.prChecks, root: root, product: nil, scheme: nil, name: nil, timeZone: oslo)
        } throws: { error in
            error.localizedDescription.contains("Pick one with --product: com.example.app, com.example.widget.")
        }
        _ = try AddCommand.add(.prChecks, root: root, product: "com.example.app", scheme: nil, name: nil, timeZone: oslo)
    }

    @Test func refusesTestPresetsWithoutDestinationsOutsideIOS() throws {
        let root = try repo(platform: "MACOS")
        #expect(throws: ToolError.self) {
            try AddCommand.add(.prChecks, root: root, product: nil, scheme: nil, name: nil, timeZone: oslo)
        }
        _ = try AddCommand.add(.testflightOnTag, root: root, product: nil, scheme: nil, name: nil, timeZone: oslo)
        #expect((try written(root, "testflight-on-tag.json").attributes["actions"] as? [JSON])?.first?["destination"] as? String == "ANY_MAC")
    }

    @Test func theAddedFilePassesValidation() throws {
        let root = try repo()
        _ = try AddCommand.add(.prChecks, root: root, product: nil, scheme: nil, name: nil, timeZone: oslo)
        let file = WorkflowFile(path: "XcodeCloud/com.example.app/pr-checks.json", product: Product(id: "prod-1", name: "Example", bundleID: "com.example.app"), definition: try written(root, "pr-checks.json"))
        let environments = Environments(
            xcodeVersions: [["type": "ciXcodeVersions", "id": "x", "attributes": ["name": "Latest Release"]]],
            macOSVersions: [["type": "ciMacOsVersions", "id": "m", "attributes": ["name": "macOS Tahoe 26.4"]]],
            repositories: [["type": "scmRepositories", "id": "r", "attributes": ["repositoryName": "example-app"]]]
        )
        #expect(WorkflowSync.validate([file], environments, repo: root.deletingLastPathComponent()).isEmpty)
    }

    @Test func rejectsAnUnknownPreset() {
        var errors: [String] = []
        #expect(AddCommand.run(arguments: ["release-train"], err: { errors.append($0) }) == 64)
        #expect(errors == [AddCommand.usage])
    }
}
