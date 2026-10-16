import Foundation
import MCP

struct XcodeCloudTools: Sendable {
    let apps: AppSelection
    private let clients = ClientCache()

    func call(_ name: String, arguments: [String: Value]) async throws -> String {
        guard let tool = MCPTools.byName[name] else {
            throw ToolError.unknownTool(name)
        }
        let client = try await clients.client()
        return try await tool.run(self, client, Arguments(values: arguments))
    }
}

private actor ClientCache {
    private var cached: AppStoreConnectClient?

    func client() throws -> AppStoreConnectClient {
        if let cached {
            return cached
        }
        let client = AppStoreConnectClient(tokens: try TokenProvider(credentials: try CredentialStore.load()))
        cached = client
        return client
    }
}

struct Arguments {
    let values: [String: Value]

    func string(_ key: String) -> String? {
        guard case .string(let value) = values[key], !value.isEmpty else {
            return nil
        }
        return value
    }

    func required(_ key: String) throws -> String {
        guard let value = string(key) else {
            throw ToolError.missingArgument(key)
        }
        return value
    }

    func int(_ key: String) -> Int? {
        switch values[key] {
        case .int(let value): value
        case .double(let value): Int(value)
        case .string(let value): Int(value)
        default: nil
        }
    }

    func bool(_ key: String) -> Bool? {
        guard case .bool(let value) = values[key] else {
            return nil
        }
        return value
    }

    func strings(_ key: String) -> [String]? {
        guard case .array(let values) = values[key] else {
            return nil
        }
        return values.compactMap { value in
            guard case .string(let string) = value else {
                return nil
            }
            return string
        }
    }

    func object(_ key: String) -> JSON? {
        guard case .object(let object) = values[key] else {
            return nil
        }
        return object.mapValues(\.foundationValue)
    }
}

private extension Value {
    var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        case .data(_, let data): data.base64EncodedString()
        case .array(let values): values.map(\.foundationValue)
        case .object(let object): object.mapValues(\.foundationValue)
        }
    }
}
