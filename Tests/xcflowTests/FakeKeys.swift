import Foundation
@testable import xcflow

/// Stands in for the Keychain: several keys side by side, one item per key id.
final class FakeKeys: KeyStore, @unchecked Sendable {
    private(set) var all: [String: Credentials] = [:]

    init(_ initial: Credentials...) {
        for credentials in initial {
            all[credentials.keyID] = credentials
        }
    }

    /// The first stored key by id, for tests that expect at most one.
    var stored: Credentials? {
        all.keys.sorted().first.flatMap { all[$0] }
    }

    func keys() throws -> [StoredKey] {
        all.values
            .map { StoredKey(keyID: $0.keyID, isTeamKey: $0.issuerID != nil, stored: nil) }
            .sorted { $0.keyID < $1.keyID }
    }

    func load(keyID: String) throws -> Credentials {
        guard let credentials = all[keyID] else { throw CredentialError.missing }
        return credentials
    }

    func save(_ credentials: Credentials) throws {
        all[credentials.keyID] = credentials
    }

    func remove(keyID: String) throws {
        all[keyID] = nil
    }
}
