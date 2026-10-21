#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#else
import Synchronization
#endif
import Testing
@testable import xcflow

final class ScriptedProtocol: URLProtocol {
    struct State {
        var statuses: [Int] = []
        var calls = 0
    }

    #if canImport(os)
    static let state = OSAllocatedUnfairLock(initialState: State())
    #else
    static let state = Mutex(State())
    #endif

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let status = Self.state.withLock { state in
            state.calls += 1
            return state.statuses.isEmpty ? 200 : state.statuses.removeFirst()
        }
        let body = status == 200 ? #"{"data":[]}"# : #"{"errors":[{"title":"An unexpected error occurred.","detail":"server side"}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct RetryTests {
    private func client() throws -> AppStoreConnectClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedProtocol.self]
        let credentials = Credentials(keyID: "TEST", privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation, issuerID: "issuer")
        return AppStoreConnectClient(tokens: try TokenProvider(credentials: credentials), session: URLSession(configuration: configuration), retryDelays: [.milliseconds(1), .milliseconds(1), .milliseconds(1)])
    }

    private func script(_ statuses: [Int]) {
        ScriptedProtocol.state.withLock { $0 = .init(statuses: statuses) }
    }

    private var calls: Int {
        ScriptedProtocol.state.withLock { $0.calls }
    }

    @Test func readsAreRetriedOnServerErrors() async throws {
        script([500, 429, 200])
        _ = try await client().get("/v1/ciProducts")
        #expect(calls == 3)
    }

    @Test func readsGiveUpAfterTheLastRetry() async throws {
        script([500, 500, 500, 500])
        await #expect(throws: AppStoreConnectError.self) { _ = try await client().get("/v1/scmRepositories") }
        #expect(calls == 4)
    }

    @Test func clientErrorsAreNotRetried() async throws {
        script([404])
        await #expect(throws: AppStoreConnectError.self) { _ = try await client().get("/v1/ciWorkflows/x") }
        #expect(calls == 1)
    }

    @Test func writesAreNeverRetried() async throws {
        script([500])
        do {
            _ = try await client().post("/v1/ciWorkflows", body: ["data": [:] as JSON])
            Issue.record("Expected the POST to fail")
        } catch {
            #expect(error.localizedDescription.hasPrefix("POST /v1/ciWorkflows: App Store Connect returned 500."))
        }
        #expect(calls == 1)
    }

    @Test func aRejectedKeyTellsHowToStoreTheIssuer() async throws {
        script([401])
        do {
            _ = try await client().get("/v1/ciProducts")
            Issue.record("Expected the request to fail")
        } catch {
            #expect(error.localizedDescription.contains("store it again with its issuer id: xcflow auth --key-id <id> --issuer-id <issuer> --p8 <path>."))
        }
    }
}
