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

/// Parent of every suite that uses CannedAPI: its state is process-global, so they must not run concurrently.
@Suite(.serialized) struct CannedAPISuites {}

struct CannedResponse: Sendable {
    let status: Int
    let body: Data

    static func json(_ object: Any) -> CannedResponse {
        CannedResponse(status: 200, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    static func status(_ code: Int) -> CannedResponse {
        CannedResponse(status: code, body: Data(#"{"errors":[{"title":"Canned \#(code)"}]}"#.utf8))
    }
}

struct RecordedRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let body: Data?

    var json: JSON? {
        body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSON }
    }
}

/// Answers App Store Connect requests from a table keyed by "METHOD /path".
/// Each key pops its responses in order and repeats the last one; unknown keys answer 404.
final class CannedAPI: URLProtocol {
    struct State {
        var table: [String: [CannedResponse]] = [:]
        var requests: [RecordedRequest] = []
    }

    #if canImport(os)
    static let state = OSAllocatedUnfairLock(initialState: State())
    #else
    static let state = Mutex(State())
    #endif

    static func reset(_ table: [String: [CannedResponse]]) {
        state.withLock { $0 = State(table: table) }
    }

    static var requests: [RecordedRequest] {
        state.withLock { $0.requests }
    }

    static func client() throws -> AppStoreConnectClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CannedAPI.self]
        let credentials = Credentials(keyID: "TEST", privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation, issuerID: "issuer")
        return AppStoreConnectClient(tokens: try TokenProvider(credentials: credentials), session: URLSession(configuration: configuration), retryDelays: [.milliseconds(1), .milliseconds(1), .milliseconds(1)])
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let path = url.path(percentEncoded: false)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
        let recorded = RecordedRequest(method: method, path: path, query: query, body: Self.body(of: request))

        let response = Self.state.withLock { state -> CannedResponse in
            state.requests.append(recorded)
            let key = "\(method) \(path)"
            guard var queue = state.table[key], let first = queue.first else {
                return .status(404)
            }
            if queue.count > 1 {
                queue.removeFirst()
                state.table[key] = queue
            }
            return first
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: response.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}
