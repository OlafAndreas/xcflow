import Foundation
import Testing
@testable import xcflow

struct ManifestsTests {
    @Test func manifestsUnderTheRootAreFoundAndVendorFoldersSkipped() throws {
        let root = try Fixtures.makeRepo()
        try Fixtures.writeManifest(in: root, project: "App/Example.xcodeproj", productIDs: ["product-a", "product-b"])
        try Fixtures.writeManifest(in: root, project: "Pods/Vendored.xcodeproj", productIDs: ["product-pods"])
        try Fixtures.writeManifest(in: root, project: ".build/checkouts/Dep.xcodeproj", productIDs: ["product-hidden"])

        let manifests = try Manifests.find(in: root)
        #expect(manifests == [XcodeCloudManifest(project: "App/Example.xcodeproj", productIDs: ["product-a", "product-b"])])
    }

    @Test func projectsWithoutAManifestAreNamedInTheMessage() throws {
        let root = try Fixtures.makeRepo()
        try Fixtures.makeProject(in: root, project: "Example.xcodeproj")

        #expect(try Manifests.find(in: root).isEmpty)
        #expect(Manifests.projects(in: root) == ["Example.xcodeproj"])
        let message = Manifests.noManifestMessage(projects: ["Example.xcodeproj"], root: root, hint: "xcflow export com.example.app")
        #expect(message.contains("No Xcode Cloud manifest"))
        #expect(message.contains("Example.xcodeproj"))
        #expect(message.contains("Product → Xcode Cloud → Create Workflow"))
        #expect(message.contains("xcflow export com.example.app"))
    }

    @Test func aRepoWithoutProjectsGetsItsOwnMessage() throws {
        let root = try Fixtures.makeRepo()
        let message = Manifests.noManifestMessage(projects: [], root: root, hint: "xcflow export com.example.app")
        #expect(message.contains("No Xcode project found"))
        #expect(message.contains("xcflow export com.example.app"))
    }

    @Test func anAppWithoutXcodeCloudIsToldToCreateTheFirstWorkflow() {
        let message = WorkflowSync.noProductMessage(bundleID: "com.example.app", apps: [App(name: "Example", bundleID: "com.example.app")])
        #expect(message.contains("Xcode Cloud isn't set up for Example (com.example.app) yet"))
        #expect(message.contains("Product → Xcode Cloud → Create Workflow"))
        #expect(message.contains("App Store Connect"))
        #expect(message.contains("xcflow export com.example.app"))
    }

    @Test func anUnknownBundleIDListsTheTeamsApps() {
        let message = WorkflowSync.noProductMessage(bundleID: "com.other.app", apps: [App(name: "Example", bundleID: "com.example.app")])
        #expect(message.contains("No app with bundle id com.other.app"))
        #expect(message.contains("Example (com.example.app)"))
        #expect(!message.contains("Create Workflow"))
    }
}
