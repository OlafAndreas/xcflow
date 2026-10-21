import Foundation
import MCP
import Testing
@testable import xcflow

struct AppSelectionTests {
    private let products = [
        Product(id: "p-1", name: "Trener123", bundleID: "com.example.trener"),
        Product(id: "p-2", name: "UpWord", bundleID: "com.example.upword")
    ]

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "xcflow-apps-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A selection for `repo`, with the store and the repo root in `folder`. The server never connects, so asking fails.
    private func selection(_ repo: String, in folder: URL, productFolders: [String] = []) throws -> AppSelection {
        let root = folder.appending(path: repo.replacing("/", with: "_"), directoryHint: .isDirectory)
        for bundleID in productFolders {
            try FileManager.default.createDirectory(at: root.appending(path: "XcodeCloud/\(bundleID)"), withIntermediateDirectories: true)
        }
        return AppSelection(
            server: Server(name: "test", version: "0"),
            repo: RepoIdentity(id: repo, root: root),
            store: folder.appending(path: "apps.json")
        )
    }

    private func refusal(_ body: () async throws -> Set<String>) async -> String? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test func eachRepoKeepsItsOwnChoice() async throws {
        let folder = try folder()
        let team = try selection("github.com/team/app", in: folder)
        let other = try selection("github.com/other/app", in: folder)
        try await team.save(["Trener123"])
        try await other.save(["UpWord"])
        #expect(try await team.chosenApps(of: products) == ["Trener123"])
        #expect(try await other.chosenApps(of: products) == ["UpWord"])
        let text = try String(contentsOf: folder.appending(path: "apps.json"), encoding: .utf8)
        #expect(text == "{\n  \"github.com/other/app\" : [\n    \"UpWord\"\n  ],\n  \"github.com/team/app\" : [\n    \"Trener123\"\n  ]\n}\n")
    }

    @Test func withoutAChoiceTheReposFoldersPickTheApps() async throws {
        let folder = try folder()
        let selection = try selection("github.com/team/app", in: folder, productFolders: ["com.example.upword"])
        #expect(try await selection.chosenApps(of: products) == ["UpWord"])
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "apps.json").path(percentEncoded: false)))
    }

    @Test func withoutAChoiceOrFoldersTheUserIsAsked() async throws {
        let selection = try selection("github.com/team/app", in: try folder())
        let text = await refusal { try await selection.chosenApps(of: products) }
        #expect(text?.contains("call choose_apps") == true)
        #expect(text?.contains("Trener123, UpWord") == true)
    }

    @Test func theOldSingleArrayStillCountsWhenItNamesAVisibleApp() async throws {
        let folder = try folder()
        try Data(#"["UpWord"]"#.utf8).write(to: folder.appending(path: "apps.json"))
        let selection = try selection("github.com/team/app", in: folder)
        #expect(try await selection.chosenApps(of: products) == ["UpWord"])
    }

    @Test func aChoiceNamingOnlyAppsThisKeyCantSeeIsSetAside() async throws {
        let folder = try folder()
        try Data(#"["Other team's app"]"#.utf8).write(to: folder.appending(path: "apps.json"))
        let selection = try selection("github.com/team/app", in: folder, productFolders: ["com.example.trener"])
        #expect(try await selection.chosenApps(of: products) == ["Trener123"])
    }

    @Test func savingOverTheOldArrayKeepsOnlyThisReposChoice() async throws {
        let folder = try folder()
        try Data(#"["UpWord"]"#.utf8).write(to: folder.appending(path: "apps.json"))
        let selection = try selection("github.com/team/app", in: folder)
        try await selection.save(["Trener123"])
        let saved = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: folder.appending(path: "apps.json")))
        #expect(saved == ["github.com/team/app": ["Trener123"]])
    }
}
