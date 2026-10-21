import Foundation

/// The products a caller may see. The MCP server scopes to the apps chosen with choose_apps.
typealias ProductScope = @Sendable (AppStoreConnectClient) async throws -> [Product]

/// Build lookups and actions, shared by the MCP tools and the CLI.
struct Builds: Sendable {
    let scope: ProductScope
}

extension XcodeCloudTools {
    var builds: Builds {
        Builds { [apps] client in
            let all = try await client.products()
            let chosen = try await apps.chosenApps(from: Self.appNames(of: all))
            return all.filter { chosen.contains($0.name) }
        }
    }
}
