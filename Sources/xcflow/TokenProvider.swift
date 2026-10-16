#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

actor TokenProvider {
    private let credentials: Credentials
    private let privateKey: P256.Signing.PrivateKey
    private var cached: (token: String, expiresAt: Date)?

    private static let lifetime: TimeInterval = 19 * 60
    private static let renewalMargin: TimeInterval = 60

    init(credentials: Credentials) throws {
        self.credentials = credentials
        self.privateKey = try P256.Signing.PrivateKey(pemRepresentation: credentials.privateKeyPEM)
    }

    func token() throws -> String {
        let now = Date()
        if let cached, cached.expiresAt.timeIntervalSince(now) > Self.renewalMargin {
            return cached.token
        }
        let expiresAt = now.addingTimeInterval(Self.lifetime)
        let token = try sign(issuedAt: now, expiresAt: expiresAt)
        cached = (token, expiresAt)
        return token
    }

    private func sign(issuedAt: Date, expiresAt: Date) throws -> String {
        let header: [String: String] = ["alg": "ES256", "kid": credentials.keyID, "typ": "JWT"]
        var payload: [String: Any] = [
            "aud": "appstoreconnect-v1",
            "iat": Int(issuedAt.timeIntervalSince1970),
            "exp": Int(expiresAt.timeIntervalSince1970)
        ]
        if let issuerID = credentials.issuerID {
            payload["iss"] = issuerID
        } else {
            payload["sub"] = "user"
        }
        let headerPart = try JSONSerialization.data(withJSONObject: header).base64URLEncoded()
        let payloadPart = try JSONSerialization.data(withJSONObject: payload).base64URLEncoded()
        let signingInput = "\(headerPart).\(payloadPart)"
        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(signature.rawRepresentation.base64URLEncoded())"
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
