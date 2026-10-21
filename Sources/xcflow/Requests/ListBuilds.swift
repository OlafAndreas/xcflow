import Foundation
import SwiftMediator

/// The most recent builds, newest first: `xcflow builds` and the list_builds tool.
struct ListBuilds: Request {
    typealias Response = String

    /// The products in scope and the hint for an unknown workflow, which differ between the CLI and the MCP server.
    let builds: Builds
    let workflow: String?
    let branch: String?
    let limit: Int
}

@Handler
struct ListBuildsHandler: RequestHandler {
    let client: AppStoreConnectClient

    func handle(_ request: ListBuilds) async throws -> String {
        try await request.builds.listBuilds(client, workflow: request.workflow, branch: request.branch, limit: request.limit)
    }
}

extension Mediator {
    /// xcflow's handlers, found once per process. Each caller binds it to a resolver that holds its client.
    /// Throws only for a wiring mistake (two handlers for one request), which every test run catches.
    static let xcflow = try! Mediator(resolver: SimpleResolver())

    /// Sends `request` with `client` as the App Store Connect client its handler resolves.
    static func send<R: Request>(_ request: R, client: AppStoreConnectClient) async throws -> R.Response {
        let resolver = SimpleResolver()
        resolver.register(AppStoreConnectClient.self, instance: client)
        return try await xcflow.bound(to: resolver).send(request)
    }
}
