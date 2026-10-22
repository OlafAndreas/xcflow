import Foundation
import SwiftMediator
import SwiftMediatorTesting
import Testing
@testable import xcflow

extension CannedAPISuites {
    @Suite(.resolver) struct ListBuildsRequestTests {
        private static let products: [String: [CannedResponse]] = [
            "GET /v1/ciProducts": [.json([
                "data": [["type": "ciProducts", "id": "prod-1", "attributes": ["name": "Trener123"], "relationships": ["app": ["data": ["type": "apps", "id": "app-1"]]]]],
                "included": [["type": "apps", "id": "app-1", "attributes": ["bundleId": "com.example.app"]]]
            ])],
            "GET /v1/ciProducts/prod-1/buildRuns": [.json(["data": [["type": "ciBuildRuns", "id": "run-12", "attributes": ["number": 12]]]])]
        ]

        private let everything = Builds { client in try await client.products() }

        @Test func theHandlerIsRegistered() throws {
            let mediator = try Mediator(discovery: false, configure: Mediator.registerHandlers)
            #expect(mediator.handlerType(for: ListBuilds.self) == ListBuildsHandler.self)
        }

        @Test func theHandlerUsesTheResolvedClient() async throws {
            CannedAPI.reset(Self.products)
            SimpleResolver.shared.register(AppStoreConnectClient.self, instance: try CannedAPI.client())
            let text = try await Mediator(discovery: false, configure: Mediator.registerHandlers).send(ListBuilds(builds: everything, workflow: nil, branch: nil, limit: 5))
            #expect(text.hasPrefix("#12 "))
        }

        @Test func sendWithAClientNeedsNoRegistration() async throws {
            CannedAPI.reset(Self.products)
            let text = try await Mediator.send(ListBuilds(builds: everything, workflow: nil, branch: nil, limit: 5), client: try CannedAPI.client())
            #expect(text.hasPrefix("#12 "))
        }

        @Test func withoutAClientTheResolverSaysWhatIsMissing() async throws {
            await #expect(throws: ResolverError.self) {
                try await Mediator(discovery: false, configure: Mediator.registerHandlers).send(ListBuilds(builds: everything, workflow: nil, branch: nil, limit: 5))
            }
        }

        @Test func aStubAnswersWithoutTheAPI() async throws {
            let mediator = try Mediator { $0.stub(ListBuilds.self) { request in "stubbed \(request.limit)" } }
            #expect(try await mediator.send(ListBuilds(builds: everything, workflow: nil, branch: nil, limit: 3)) == "stubbed 3")
        }
    }
}
