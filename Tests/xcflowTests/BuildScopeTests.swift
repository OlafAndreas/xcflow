import Foundation
import Testing
@testable import xcflow

extension CannedAPISuites {
    @Suite struct BuildScopeTests {
        private static func productJSON(_ id: String, _ name: String, app: String) -> JSON {
            ["type": "ciProducts", "id": id, "attributes": ["name": name], "relationships": ["app": ["data": ["type": "apps", "id": app]]]]
        }

        private static func appJSON(_ id: String, _ bundleID: String) -> JSON {
            ["type": "apps", "id": id, "attributes": ["bundleId": bundleID]]
        }

        private static var table: [String: [CannedResponse]] { [
            "GET /v1/ciProducts": [.json([
                "data": [productJSON("prod-1", "Trener123", app: "app-1"), productJSON("prod-2", "Other", app: "app-2")],
                "included": [appJSON("app-1", "com.example.app"), appJSON("app-2", "com.other.app")]
            ])]
        ] }

        private static func root(folders: [String], files: [String] = []) throws -> URL {
            let root = FileManager.default.temporaryDirectory.appending(path: "xcflow-scope-\(UUID().uuidString)/XcodeCloud")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for folder in folders {
                try FileManager.default.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
            }
            for file in files {
                try Data().write(to: root.appending(path: file))
            }
            return root
        }

        @Test func foldersSelectTheProducts() async throws {
            CannedAPI.reset(Self.table)
            let root = try Self.root(folders: ["com.example.app"])
            let products = try await BuildScope.resolve(root: root, product: nil, all: false)(try CannedAPI.client())
            #expect(products.map(\.id) == ["prod-1"])
        }

        @Test func onlyDirectoriesCount() throws {
            let root = try Self.root(folders: ["com.other.app", "com.example.app"], files: ["README.md", ".DS_Store"])
            #expect(BuildScope.folders(in: root) == ["com.example.app", "com.other.app"])
        }

        @Test func noFolderIsAnError() async throws {
            CannedAPI.reset(Self.table)
            let root = try Self.root(folders: [], files: ["README.md"])
            do {
                _ = try await BuildScope.resolve(root: root, product: nil, all: false)(try CannedAPI.client())
                Issue.record("Expected an error")
            } catch ToolError.refused(let message) {
                #expect(message == "No products in XcodeCloud/. Run from the repo root, or pass --product <bundle id> or --all.")
            }
        }

        @Test func aFolderWithoutAProductIsAnError() async throws {
            CannedAPI.reset(Self.table)
            let root = try Self.root(folders: ["com.example.app", "com.missing.app"])
            do {
                _ = try await BuildScope.resolve(root: root, product: nil, all: false)(try CannedAPI.client())
                Issue.record("Expected an error")
            } catch ToolError.refused(let message) {
                #expect(message == "XcodeCloud/com.missing.app matches no product this key can see. Check the bundle id and the key's team, or pass --product or --all.")
            }
        }

        @Test func productMatchesByBundleIDNameOrID() async throws {
            let root = try Self.root(folders: [])
            for filter in ["com.example.app", "trener123", "prod-1"] {
                CannedAPI.reset(Self.table)
                let products = try await BuildScope.resolve(root: root, product: filter, all: false)(try CannedAPI.client())
                #expect(products.map(\.id) == ["prod-1"])
            }
            CannedAPI.reset(Self.table)
            do {
                _ = try await BuildScope.resolve(root: root, product: "nope", all: false)(try CannedAPI.client())
                Issue.record("Expected an error")
            } catch ToolError.notFound(let message) {
                #expect(message.hasPrefix("No product matches \"nope\". Products: "))
            }
        }

        @Test func allTakesEverything() async throws {
            CannedAPI.reset(Self.table)
            let root = try Self.root(folders: [])
            let products = try await BuildScope.resolve(root: root, product: nil, all: true)(try CannedAPI.client())
            #expect(products.map(\.id) == ["prod-1", "prod-2"])
        }
    }
}
