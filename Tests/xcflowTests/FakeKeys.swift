import Foundation
@testable import xcflow

/// Stands in for the Keychain: several keys side by side, one item per key id.
final class FakeKeys: KeyStore, @unchecked Sendable {
    private(set) var all: [String: Credentials] = [:]
    /// When each key was stored, for the listing; nil unless a test sets it.
    var dates: [String: Date] = [:]

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
            .map { StoredKey(keyID: $0.keyID, isTeamKey: $0.issuerID != nil, stored: dates[$0.keyID]) }
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

extension KeyPins {
    /// A test repo's pins: a store next to the repo instead of the real one, and no git.
    static func test(_ root: URL) -> KeyPins {
        KeyPins(
            store: root.deletingLastPathComponent().appending(path: "\(root.lastPathComponent)-pins.json"),
            repo: "example.com/team/app",
            legacyFile: root.appending(path: "XcodeCloud/xcflow.json")
        )
    }

    /// Writes the `XcodeCloud/xcflow.json` that xcflow 0.2.12 kept in the repo.
    func writeLegacy(_ keyID: String) throws {
        try FileManager.default.createDirectory(at: legacyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\n  \"keyID\" : \"\(keyID)\"\n}\n".utf8).write(to: legacyFile)
    }
}
