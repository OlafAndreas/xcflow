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

struct ListBuildsHandler: RequestHandler {
    let client: AppStoreConnectClient

    init(resolver: any Resolver) throws { client = try resolver() }

    func handle(_ request: ListBuilds) async throws -> String {
        try await request.builds.listBuilds(client, workflow: request.workflow, branch: request.branch, limit: request.limit)
    }
}

extension Mediator {
    /// xcflow's handlers. Registered explicitly: the package builds without the macros, and so without swift-syntax.
    static func registerHandlers(_ configuration: inout Configuration) {
        configuration.register(ListBuildsHandler.self)
    }

    /// One mediator per process. Each call hands in its own client.
    static let xcflow = Mediator.failFast(resolver: SimpleResolver(), discovery: false, configure: registerHandlers)

    /// Sends `request` with `client` as the App Store Connect client its handler resolves.
    static func send<R: Request>(_ request: R, client: AppStoreConnectClient) async throws -> R.Response {
        try await xcflow.send(request) { $0.register(AppStoreConnectClient.self, instance: client) }
    }
}
