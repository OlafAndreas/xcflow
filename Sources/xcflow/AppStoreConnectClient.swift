import Foundation

typealias JSON = [String: Any]

struct Page {
    var data: [JSON] = []
    var included: [JSON] = []
}

struct AppStoreConnectClient: Sendable {
    private static let baseURL = URL(string: "https://api.appstoreconnect.apple.com")!
    static let defaultRetryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(10)]

    private let tokens: TokenProvider?
    private let session: URLSession
    private let dryRun: DryRunServer?
    private let retryDelays: [Duration]

    init(tokens: TokenProvider, session: URLSession = .shared, retryDelays: [Duration] = defaultRetryDelays) {
        self.tokens = tokens
        self.session = session
        self.dryRun = nil
        self.retryDelays = retryDelays
    }

    init(dryRun: DryRunServer) {
        self.tokens = nil
        self.session = .shared
        self.dryRun = dryRun
        self.retryDelays = []
    }

    func get(_ path: String, query: [String: String] = [:]) async throws -> JSON {
        try await send("GET", url(path, query: query), body: nil)
    }

    func getAll(_ path: String, query: [String: String] = [:], limit: Int = .max, until stop: (JSON) -> Bool = { _ in false }) async throws -> Page {
        var page = Page()
        var next: URL? = url(path, query: query)
        while let current = next, page.data.count < limit {
            let response = try await send("GET", current, body: nil)
            let data = response["data"] as? [JSON] ?? []
            page.data += data
            page.included += response["included"] as? [JSON] ?? []
            if data.contains(where: stop) {
                break
            }
            next = ((response["links"] as? JSON)?["next"] as? String).flatMap(URL.init(string:))
        }
        page.data = Array(page.data.prefix(limit))
        return page
    }

    func post(_ path: String, body: JSON) async throws -> JSON {
        try await send("POST", url(path, query: [:]), body: body)
    }

    func patch(_ path: String, body: JSON) async throws -> JSON {
        try await send("PATCH", url(path, query: [:]), body: body)
    }

    func delete(_ path: String) async throws {
        _ = try await send("DELETE", url(path, query: [:]), body: nil)
    }

    func download(_ url: URL, to destination: URL) async throws {
        let (location, response) = try await session.download(from: url)
        try Self.validate(response, data: nil, request: "GET \(url.host() ?? "download")")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: location, to: destination)
    }

    private func url(_ path: String, query: [String: String]) -> URL {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    private func send(_ method: String, _ url: URL, body: JSON?) async throws -> JSON {
        let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let data: Data
        if let dryRun {
            data = try await dryRun.respond(method, url, body: bodyData)
        } else {
            guard let tokens else {
                throw AppStoreConnectError(status: 0, details: ["No credentials"])
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(try await tokens.token())", forHTTPHeaderField: "Authorization")
            if let bodyData {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = bodyData
            }
            data = try await perform(request, label: "\(method) \(url.path(percentEncoded: false))")
        }
        guard !data.isEmpty else {
            return [:]
        }
        return try JSONSerialization.jsonObject(with: data) as? JSON ?? [:]
    }

    // App Store Connect answers reads with an occasional 500. Only reads are retried, since a repeated POST could create a workflow twice.
    private func perform(_ request: URLRequest, label: String) async throws -> Data {
        var attempt = 0
        while true {
            let (data, response) = try await session.data(for: request)
            do {
                try Self.validate(response, data: data, request: label)
                return data
            } catch let error as AppStoreConnectError where request.httpMethod == "GET" && error.isTransient && attempt < retryDelays.count {
                FileHandle.standardError.write(Data("\(error.localizedDescription) Retrying.\n".utf8))
                try await Task.sleep(for: retryDelays[attempt])
                attempt += 1
            }
        }
    }

    private static func validate(_ response: URLResponse, data: Data?, request: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AppStoreConnectError(status: 0, details: ["No HTTP response"], request: request)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppStoreConnectError(status: http.statusCode, details: errorDetails(from: data), request: request)
        }
    }

    private static func errorDetails(from data: Data?) -> [String] {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? JSON,
              let errors = json["errors"] as? [JSON]
        else {
            return []
        }
        return errors.map { error in
            [error["title"], error["detail"]].compactMap { $0 as? String }.joined(separator: ": ")
        }
    }
}

struct AppStoreConnectError: LocalizedError {
    let status: Int
    let details: [String]
    var request: String?

    var isTransient: Bool {
        status == 429 || (500..<600).contains(status)
    }

    var errorDescription: String? {
        let hint = switch status {
        case 401: " The key was rejected. Check the key id, or re-run setup."
        case 403: " The key's role is not allowed to do this."
        default: ""
        }
        let prefix = request.map { "\($0): " } ?? ""
        return "\(prefix)App Store Connect returned \(status).\(hint) \(details.joined(separator: " | "))"
    }
}

extension Dictionary where Key == String, Value == Any {
    var id: String {
        self["id"] as? String ?? ""
    }

    var attributes: JSON {
        self["attributes"] as? JSON ?? [:]
    }

    func string(_ key: String) -> String? {
        attributes[key] as? String
    }

    func relationshipID(_ name: String) -> String? {
        ((self["relationships"] as? JSON)?[name] as? JSON)
            .flatMap { $0["data"] as? JSON }?["id"] as? String
    }
}
