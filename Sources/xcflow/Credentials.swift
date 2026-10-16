import Foundation
import Security

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
}

enum CredentialError: LocalizedError {
    case missing
    case keychain(OSStatus)
    case environment(String)

    var errorDescription: String? {
        switch self {
        case .missing:
            "No App Store Connect API key found. Run `xcflow auth --key-id <KEY_ID> --p8 <path/to/AuthKey.p8>`."
        case .environment(let message):
            message
        case .keychain(let status):
            "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }
}
