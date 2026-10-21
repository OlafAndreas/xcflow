import Foundation

enum Auth {
    static func run(arguments: [String]) async throws {
        guard let keyID = value(for: "--key-id", in: arguments),
              let p8Path = value(for: "--p8", in: arguments)
        else {
            print("Usage: xcflow auth --key-id <KEY_ID> --p8 <path/to/AuthKey_KEYID.p8> [--issuer-id <ISSUER_ID>]")
            exit(64)
        }

        let pem = try String(contentsOf: URL(fileURLWithPath: (p8Path as NSString).expandingTildeInPath), encoding: .utf8)
        let issuerID = value(for: "--issuer-id", in: arguments)
        let credentials = Credentials(keyID: keyID, privateKeyPEM: pem, issuerID: issuerID)

        let client = AppStoreConnectClient(tokens: try TokenProvider(credentials: credentials))
        let response = try await client.get("/v1/ciProducts", query: ["fields[ciProducts]": "name,productType"])

        try CredentialStore.save(credentials)

        let names = (response["data"] as? [[String: Any]] ?? []).compactMap { product in
            (product["attributes"] as? [String: Any])?["name"] as? String
        }
        print("\(issuerID == nil ? "Individual" : "Team") key \(keyID) verified and stored in the Keychain.")
        print(names.isEmpty ? "The key works, but sees no Xcode Cloud products." : "Xcode Cloud products: \(names.joined(separator: ", "))")
    }

    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
