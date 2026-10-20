import Foundation
#if canImport(Security)
import Security
#endif

struct Credentials: Sendable {
    let keyID: String
    let privateKeyPEM: String
    var issuerID: String?
}

enum CredentialStore {
    private static let service = "xcflow"

    static func load() throws -> Credentials {
        try fromEnvironment() ?? fromKeychain()
    }

    private static func fromEnvironment() throws -> Credentials? {
        let environment = ProcessInfo.processInfo.environment
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

    #if canImport(Security)
    static func save(_ credentials: Credentials) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentials.keyID,
            kSecAttrLabel as String: "xcflow (App Store Connect API key)",
            kSecValueData as String: Data(credentials.privateKeyPEM.utf8)
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialError.keychain(status)
        }
    }

    private static func fromKeychain() throws -> Credentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else {
            throw CredentialError.missing
        }
        guard status == errSecSuccess,
              let item = result as? [String: Any],
              let keyID = item[kSecAttrAccount as String] as? String,
              let data = item[kSecValueData as String] as? Data,
              let pem = String(data: data, encoding: .utf8)
        else {
            throw CredentialError.keychain(status)
        }
        return Credentials(keyID: keyID, privateKeyPEM: pem)
    }
    #else
    static func save(_ credentials: Credentials) throws {
        throw CredentialError.noKeychain
    }

    private static func fromKeychain() throws -> Credentials {
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

/// Where xcflow's own App Store Connect key lives. `setup` reads it to export and writes the key it is given; tests swap in a fake.
protocol KeyStore {
    func load() throws -> Credentials
    func save(_ credentials: Credentials) throws
}

/// The environment variables, then the Keychain, as every command reads them.
struct KeychainKeyStore: KeyStore {
    func load() throws -> Credentials { try CredentialStore.load() }

    func save(_ credentials: Credentials) throws {
        #if canImport(Security)
        try CredentialStore.save(credentials)
        #else
        throw CredentialError.noKeychain
        #endif
    }
}
