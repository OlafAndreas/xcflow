import Foundation

struct Product {
    let id: String
    let name: String
    let bundleID: String

    var label: String {
        "\(name) (\(bundleID))"
    }
}

extension AppStoreConnectClient {
    func products() async throws -> [Product] {
        let page = try await getAll("/v1/ciProducts", query: [
            "fields[ciProducts]": "name,app",
            "include": "app",
            "fields[apps]": "bundleId"
        ])
        let bundleIDs = Dictionary(page.included.map { ($0.id, $0.string("bundleId") ?? "") }) { first, _ in first }
        return page.data.map { product in
            Product(
                id: product.id,
                name: product.string("name") ?? product.id,
                bundleID: product.relationshipID("app").flatMap { bundleIDs[$0] } ?? "?"
            )
        }
    }
}

struct App {
    let name: String
    let bundleID: String

    var label: String {
        "\(name) (\(bundleID))"
    }
}

extension AppStoreConnectClient {
    func apps() async throws -> [App] {
        let page = try await getAll("/v1/apps", query: ["fields[apps]": "name,bundleId", "limit": "200"])
        return page.data.map { App(name: $0.string("name") ?? $0.id, bundleID: $0.string("bundleId") ?? "?") }
    }
}
