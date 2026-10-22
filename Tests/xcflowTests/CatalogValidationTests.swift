import Foundation
import Testing
@testable import xcflow

struct CatalogValidationTests {
    private let product = Product(id: "prod-1", name: "Example", bundleID: "com.example.app")

    /// A repo with Example.xcodeproj sharing "Example" and keeping "Private" in xcuserdata, and the XcodeCloud folder plan reads.
    private func repo() throws -> URL {
        let repo = try Fixtures.makeRepo()
        try scheme("Example", in: repo.appending(path: "Example.xcodeproj/xcshareddata/xcschemes"))
        try scheme("Private", in: repo.appending(path: "Example.xcodeproj/xcuserdata/olaf.xcuserdatad/xcschemes"))
        return repo
    }

    private func scheme(_ name: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("<Scheme/>".utf8).write(to: folder.appending(path: "\(name).xcscheme"))
    }

    private func file(scheme: String = "Example", container: String = "Example.xcodeproj", xcode: String = "Latest Release", macOS: String = "Latest Release") throws -> WorkflowFile {
        var json = Fixtures.workflow(id: Fixtures.nightlyID, name: "Nightly tests")
        json["xcodeVersion"] = xcode
        json["macOsVersion"] = macOS
        var attributes = json["attributes"] as! JSON
        attributes["containerFilePath"] = container
        var action = (attributes["actions"] as! [JSON])[0]
        action["scheme"] = scheme
        attributes["actions"] = [action]
        json["attributes"] = attributes
        return WorkflowFile(path: "XcodeCloud/com.example.app/nightly-tests.json", product: product, definition: try WorkflowDefinition(fileJSON: json))
    }

    private func version(_ type: String, _ name: String, runsOn macOS: [String]? = nil) -> JSON {
        var json: JSON = ["type": type, "id": "id-\(name)", "attributes": ["name": name]]
        if let macOS {
            json["relationships"] = ["macOsVersions": ["data": macOS.map { ["type": "ciMacOsVersions", "id": "id-\($0)"] }]]
        }
        return json
    }

    private func environments(withCompatibility: Bool = true) -> Environments {
        Environments(
            xcodeVersions: [
                version("ciXcodeVersions", "Latest Release", runsOn: withCompatibility ? ["Latest Release", "macOS Golden Gate 27", "macOS Tahoe 26.4"] : nil),
                version("ciXcodeVersions", "Xcode 26.6", runsOn: withCompatibility ? ["Latest Release", "macOS Tahoe 26.4"] : nil)
            ],
            macOSVersions: [version("ciMacOsVersions", "Latest Release"), version("ciMacOsVersions", "macOS Golden Gate 27"), version("ciMacOsVersions", "macOS Tahoe 26.4")],
            repositories: [["type": "scmRepositories", "id": "repo-1", "attributes": ["repositoryName": "example-app"]]]
        )
    }

    private func errors(_ file: WorkflowFile, repo: URL, withCompatibility: Bool = true) -> [String] {
        WorkflowSync.validate([file], environments(withCompatibility: withCompatibility), repo: repo)
    }

    // MARK: schemes

    @Test func aSharedSchemePasses() throws {
        #expect(errors(try file(), repo: try repo()).isEmpty)
    }

    @Test func anUnknownSchemeListsTheSharedOnes() throws {
        #expect(errors(try file(scheme: "Nope"), repo: try repo()) == [
            "XcodeCloud/com.example.app/nightly-tests.json: action \"Test - iOS\" uses the scheme \"Nope\", which Example.xcodeproj doesn't share. Shared schemes: Example."
        ])
    }

    @Test func aSchemeOnlyInXcuserdataSaysToShareIt() throws {
        #expect(errors(try file(scheme: "Private"), repo: try repo()) == [
            "XcodeCloud/com.example.app/nightly-tests.json: action \"Test - iOS\" uses the scheme \"Private\", which isn't shared in Example.xcodeproj, so Xcode Cloud can't see it. Tick Shared for it in Xcode (Product → Scheme → Manage Schemes…) and commit its .xcscheme file."
        ])
    }

    @Test func aWorkspaceSeesItsOwnAndItsProjectsSharedSchemes() throws {
        let repo = try repo()
        let workspace = repo.appending(path: "App.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version = "1.0">
           <FileRef location = "group:Example.xcodeproj"></FileRef>
           <FileRef location = "group:Pods/Pods.xcodeproj"></FileRef>
        </Workspace>
        """.utf8).write(to: workspace.appending(path: "contents.xcworkspacedata"))
        try scheme("Everything", in: workspace.appending(path: "xcshareddata/xcschemes"))
        #expect(errors(try file(scheme: "Example", container: "App.xcworkspace"), repo: repo).isEmpty)
        #expect(errors(try file(scheme: "Everything", container: "App.xcworkspace"), repo: repo).isEmpty)
        #expect(errors(try file(scheme: "Nope", container: "App.xcworkspace"), repo: repo).first?.hasSuffix("which App.xcworkspace doesn't share. Shared schemes: Everything, Example.") == true)
    }

    @Test func aContainerThatIsntCheckedInIsSkipped() throws {
        #expect(errors(try file(scheme: "Nope", container: "Generated.xcodeproj"), repo: try repo()).isEmpty)
    }

    @Test func aPackageIsSkipped() throws {
        let repo = try repo()
        try Data("// swift-tools-version: 6.0".utf8).write(to: repo.appending(path: "Package.swift"))
        #expect(errors(try file(scheme: "Nope", container: "Package.swift"), repo: repo).isEmpty)
    }

    // MARK: versions

    @Test func anXcodeThatDoesntRunOnTheMacOSVersionIsRejected() throws {
        #expect(errors(try file(xcode: "Xcode 26.6", macOS: "macOS Golden Gate 27"), repo: try repo()) == [
            "XcodeCloud/com.example.app/nightly-tests.json: Xcode 26.6 doesn't run on macOS Golden Gate 27. With Xcode 26.6, use: Latest Release, macOS Tahoe 26.4."
        ])
    }

    @Test func aMatchingPairPasses() throws {
        #expect(errors(try file(xcode: "Xcode 26.6", macOS: "macOS Tahoe 26.4"), repo: try repo()).isEmpty)
    }

    @Test func withoutCompatibilityInTheCatalogThePairIsntChecked() throws {
        #expect(errors(try file(xcode: "Xcode 26.6", macOS: "macOS Golden Gate 27"), repo: try repo(), withCompatibility: false).isEmpty)
    }

    @Test func anUnknownXcodeVersionPointsAtLatestRelease() throws {
        #expect(errors(try file(xcode: "Xcode 25"), repo: try repo()) == [
            "XcodeCloud/com.example.app/nightly-tests.json: unknown Xcode version \"Xcode 25\". Available: Latest Release, Xcode 26.6. \"Latest Release\" follows Apple's newest release, so the file never goes stale."
        ])
    }

    @Test func aNewWorkflowNeedsADescription() throws {
        let existing = try file()
        var attributes = existing.definition.attributes
        attributes["description"] = ""
        let new = WorkflowFile(path: existing.path, product: product, definition: WorkflowDefinition(id: nil, repository: "example-app", xcodeVersion: "Latest Release", macOsVersion: "Latest Release", attributes: attributes))
        #expect(WorkflowSync.validate([new], environments(), repo: try repo()) == ["XcodeCloud/com.example.app/nightly-tests.json: a new workflow needs a description; App Store Connect refuses to create one without."])
        let kept = WorkflowFile(path: existing.path, product: product, definition: WorkflowDefinition(id: Fixtures.nightlyID, repository: "example-app", xcodeVersion: "Latest Release", macOsVersion: "Latest Release", attributes: attributes))
        #expect(WorkflowSync.validate([kept], environments(), repo: try repo()).isEmpty)
    }

    private func catalog() -> Environments {
        let iPhone: JSON = [
            "kind": "SIMULATOR", "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17", "deviceTypeName": "iPhone 17",
            "availableRuntimes": [
                ["runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "runtimeName": "iOS 27.0"],
                ["runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1", "runtimeName": "iOS 27.1"],
                ["runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-17-5", "runtimeName": "iOS 17.5"],
            ],
        ]
        var xcode = version("ciXcodeVersions", "Latest Release")
        xcode["attributes"] = ["name": "Latest Release", "testDestinations": [iPhone]] as JSON
        return Environments(xcodeVersions: [xcode], macOSVersions: [version("ciMacOsVersions", "Latest Release")], repositories: [["type": "scmRepositories", "id": "repo-1", "attributes": ["repositoryName": "example-app"]]])
    }

    @Test func fillsInTheDeviceAndRuntimeNamesAppStoreConnectRequires() throws {
        let attributes = try file().definition.attributes
        let labeled = catalog().withDisplayLabels(attributes, xcode: "Latest Release")
        let destination = try #require((((labeled["actions"] as? [JSON])?.first?["testConfiguration"] as? JSON)?["testDestinations"] as? [JSON])?.first)
        #expect(destination["deviceTypeName"] as? String == "iPhone 17")
        #expect(destination["runtimeName"] as? String == "Latest from Selected Xcode (iOS 27.1)")
    }

    @Test func aTestDeviceTheXcodeVersionDoesntOfferIsRejected() throws {
        let known = try file()
        #expect(WorkflowSync.validate([known], catalog(), repo: try repo()).isEmpty)
        var attributes = known.definition.attributes
        var action = (attributes["actions"] as! [JSON])[0]
        action["testConfiguration"] = ["kind": "USE_SCHEME_SETTINGS", "testDestinations": [["kind": "SIMULATOR", "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-6", "runtimeIdentifier": "default"]]] as JSON
        attributes["actions"] = [action]
        let unknown = WorkflowFile(path: known.path, product: product, definition: WorkflowDefinition(id: Fixtures.nightlyID, repository: "example-app", xcodeVersion: "Latest Release", macOsVersion: "Latest Release", attributes: attributes))
        #expect(WorkflowSync.validate([unknown], catalog(), repo: try repo()) == ["XcodeCloud/com.example.app/nightly-tests.json: Latest Release has no test device com.apple.CoreSimulator.SimDeviceType.iPhone-6."])
    }
}
