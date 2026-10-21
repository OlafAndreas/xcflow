import Foundation
#if canImport(Security)
import Security
#endif

struct Credentials: Sendable, Equatable {
    let keyID: String
    let privateKeyPEM: String
    var issuerID: String?
}

enum CredentialStore {
    private static let service = "xcflow"

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Credentials? {
        guard let keyID = environment["ASC_KEY_ID"], let content = environment["ASC_KEY_CONTENT"] else {
            return nil
        }
        let pem = content.contains("BEGIN PRIVATE KEY")
            ? content
            : Data(base64Encoded: content, options: .ignoreUnknownCharacters).map { String(decoding: $0, as: UTF8.self) }
        guard let pem else {
            throw CredentialError.environment("ASC_KEY_CONTENT is neither a PEM key nor base64 of one.")
        }
        return Credentials(keyID: keyID, privateKeyPEM: pem, issuerID: environment["ASC_ISSUER_ID"])
    }

    private struct IssuerAttribute: Codable {
        let issuerID: String
    }

    /// The Keychain item's generic attribute: JSON holding the issuer id of a team key. Nil for an individual key.
    static func genericAttribute(issuerID: String?) -> Data? {
        guard let issuerID, !issuerID.isEmpty else { return nil }
        return try? JSONEncoder().encode(IssuerAttribute(issuerID: issuerID))
    }

    /// The issuer id in a generic attribute. Missing, empty or undecodable data reads as no issuer.
    static func issuerID(fromGeneric data: Data?) -> String? {
        guard let data, let attribute = try? JSONDecoder().decode(IssuerAttribute.self, from: data), !attribute.issuerID.isEmpty else {
            return nil
        }
        return attribute.issuerID
    }

    #if canImport(Security)
    private static func match(_ keyID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyID
        ]
    }

    /// Stores the key, replacing the item with the same key id and leaving every other key alone.
    static func save(_ credentials: Credentials) throws {
        SecItemDelete(match(credentials.keyID) as CFDictionary)

        var addQuery = match(credentials.keyID)
        addQuery[kSecAttrLabel as String] = "xcflow (App Store Connect API key)"
        addQuery[kSecValueData as String] = Data(credentials.privateKeyPEM.utf8)
        if let generic = genericAttribute(issuerID: credentials.issuerID) {
            addQuery[kSecAttrGeneric as String] = generic
        }
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialError.keychain(status)
        }
    }

    static func storedKeys() throws -> [StoredKey] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw CredentialError.keychain(status)
        }
        return items.compactMap { item in
            guard let keyID = item[kSecAttrAccount as String] as? String else { return nil }
            return StoredKey(
                keyID: keyID,
                isTeamKey: issuerID(fromGeneric: item[kSecAttrGeneric as String] as? Data) != nil,
                stored: item[kSecAttrModificationDate as String] as? Date
            )
        }
        .sorted { $0.keyID < $1.keyID }
    }

    static func load(keyID: String) throws -> Credentials {
        var query = match(keyID)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else {
            throw CredentialError.missing
        }
        guard status == errSecSuccess,
              let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let pem = String(data: data, encoding: .utf8)
        else {
            throw CredentialError.keychain(status)
        }
        return Credentials(keyID: keyID, privateKeyPEM: pem, issuerID: issuerID(fromGeneric: item[kSecAttrGeneric as String] as? Data))
    }

    static func remove(keyID: String) throws {
        let status = SecItemDelete(match(keyID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.keychain(status)
        }
    }

    #else
    static func save(_ credentials: Credentials) throws {
        throw CredentialError.noKeychain
    }

    static func storedKeys() throws -> [StoredKey] { [] }

    static func load(keyID: String) throws -> Credentials {
        throw CredentialError.noKeychain
    }

    static func remove(keyID: String) throws {
        throw CredentialError.noKeychain
    }
    #endif
}

enum CredentialError: LocalizedError {
    case missing
    case keychain(Int32)
    case noKeychain
    case environment(String)

    var errorDescription: String? {
        switch self {
        case .missing:
            "No App Store Connect API key found. Run `xcflow auth --key-id <KEY_ID> --p8 <path/to/AuthKey.p8>`."
        case .environment(let message):
            message
        case .noKeychain:
            "There is no Keychain on this platform. Set the ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_CONTENT environment variables instead."
        case .keychain(let status):
            "Keychain error \(status): \(Self.message(for: status))"
        }
    }
}

private extension CredentialError {
    static func message(for status: Int32) -> String {
        #if canImport(Security)
        SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        #else
        "unknown"
        #endif
    }
}

/// A key in the Keychain, without its secret. `stored` is when the item last changed, when known.
struct StoredKey: Equatable {
    let keyID: String
    let isTeamKey: Bool
    let stored: Date?
}

/// Where xcflow's own App Store Connect keys live, one item per key id. `setup` reads them to export and writes the key it is given; tests swap in a fake.
protocol KeyStore {
    /// Every stored key, sorted by key id.
    func keys() throws -> [StoredKey]
    /// Throws `CredentialError.missing` when the key isn't stored.
    func load(keyID: String) throws -> Credentials
    /// Replaces the key with the same id and leaves the others.
    func save(_ credentials: Credentials) throws
    func remove(keyID: String) throws
}

/// The Keychain items with service "xcflow".
struct KeychainKeyStore: KeyStore {
    func keys() throws -> [StoredKey] { try CredentialStore.storedKeys() }
    func load(keyID: String) throws -> Credentials { try CredentialStore.load(keyID: keyID) }
    func save(_ credentials: Credentials) throws { try CredentialStore.save(credentials) }
    func remove(keyID: String) throws { try CredentialStore.remove(keyID: keyID) }
}
