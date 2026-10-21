import Foundation
import Testing
@testable import xcflow

struct KeysCommandTests {
    final class Output: @unchecked Sendable {
        var out: [String] = []
        var err: [String] = []
    }

    private func makeRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "xcflow-keys-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func pins(_ root: URL) -> KeyPins {
        .test(root)
    }

    private func key(_ id: String, team: Bool = true) -> Credentials {
        Credentials(keyID: id, privateKeyPEM: "pem-\(id)", issuerID: team ? "issuer-\(id)" : nil)
    }

    private func run(_ arguments: [String], keys: FakeKeys, pins: KeyPins) -> (code: Int32, output: Output) {
        let output = Output()
        let code = KeysCommand.run(arguments: arguments, keys: keys, pins: pins, out: { output.out.append($0) }, err: { output.err.append($0) })
        return (code, output)
    }

    private let noon = ISO8601DateFormatter().date(from: "2026-10-21T12:00:00Z")!

    @Test func listsTheStoredKeysAndMarksTheRepos() throws {
        let root = try makeRepo()
        try pins(root).pin("B")
        let keys = FakeKeys(key("A"), key("B", team: false))
        keys.dates = ["A": noon, "B": noon]
        let result = run([], keys: keys, pins: pins(root))
        #expect(result.code == 0)
        #expect(result.output.out == [
            "  A  team  stored 2026-10-21",
            "* B  individual  stored 2026-10-21"
        ])
    }

    @Test func listingWithoutARepoFileMarksNone() throws {
        let root = try makeRepo()
        let result = run([], keys: FakeKeys(key("A")), pins: pins(root))
        #expect(result.code == 0)
        #expect(result.output.out == ["  A  team"])
    }

    @Test func listingWithNoKeysSaysHowToStoreOne() throws {
        let root = try makeRepo()
        let result = run([], keys: FakeKeys(), pins: pins(root))
        #expect(result.code == 0)
        #expect(result.output.out.joined().contains("xcflow auth"))
    }

    @Test func listingNamesAPinnedKeyThatIsntStored() throws {
        let root = try makeRepo()
        try pins(root).pin("GONE")
        let result = run([], keys: FakeKeys(key("A")), pins: pins(root))
        #expect(result.code == 0)
        #expect(result.output.out.contains { $0.contains("GONE") && $0.contains("isn't stored") })
    }

    @Test func usePinsTheRepoOutsideIt() throws {
        let root = try makeRepo()
        let result = run(["use", "A"], keys: FakeKeys(key("A"), key("B")), pins: pins(root))
        #expect(result.code == 0)
        #expect(try pins(root).pinned() == "A")
        #expect(result.output.out == ["Pinned this repo to key A on this machine."])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)).isEmpty)
    }

    @Test func useMovesALegacyPinOutOfTheRepo() throws {
        let root = try makeRepo()
        try pins(root).writeLegacy("A")
        let result = run(["use", "B"], keys: FakeKeys(key("A"), key("B")), pins: pins(root))
        #expect(result.code == 0)
        #expect(try pins(root).pinned() == "B")
        #expect(!FileManager.default.fileExists(atPath: pins(root).legacyFile.path(percentEncoded: false)))
        #expect(result.output.out.last == "Pinned this repo to key B on this machine.")
    }

    @Test func useReplacesAnExistingPin() throws {
        let root = try makeRepo()
        try pins(root).pin("A")
        #expect(run(["use", "B"], keys: FakeKeys(key("A"), key("B")), pins: pins(root)).code == 0)
        #expect(try pins(root).pinned() == "B")
    }

    @Test func useRefusesAnUnstoredKey() throws {
        let root = try makeRepo()
        let result = run(["use", "NOPE"], keys: FakeKeys(key("A")), pins: pins(root))
        #expect(result.code == 2)
        #expect(result.output.err.joined().contains("NOPE"))
        #expect(result.output.err.joined().contains("xcflow auth --key-id NOPE"))
        #expect(try pins(root).pinned() == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "XcodeCloud").path(percentEncoded: false)))
    }

    @Test func removeDeletesOnlyThatKey() throws {
        let root = try makeRepo()
        let keys = FakeKeys(key("A"), key("B"))
        let result = run(["remove", "A"], keys: keys, pins: pins(root))
        #expect(result.code == 0)
        #expect(try keys.keys().map(\.keyID) == ["B"])
        #expect(result.output.out.first == "Removed key A from the Keychain.")
    }

    @Test func removeRefusesAnUnstoredKey() throws {
        let root = try makeRepo()
        let keys = FakeKeys(key("A"))
        let result = run(["remove", "NOPE"], keys: keys, pins: pins(root))
        #expect(result.code == 2)
        #expect(result.output.err.joined().contains("NOPE"))
        #expect(try keys.keys().map(\.keyID) == ["A"])
    }

    @Test func removingThePinnedKeyIsAllowedAndTheNextCommandSaysHowToStoreIt() throws {
        let root = try makeRepo()
        let keys = FakeKeys(key("A"), key("B"))
        #expect(run(["use", "A"], keys: keys, pins: pins(root)).code == 0)
        let removed = run(["remove", "A"], keys: keys, pins: pins(root))
        #expect(removed.code == 0)
        #expect(removed.output.out.contains { $0.contains("still pinned") && $0.contains("xcflow keys use") })
        #expect(throws: (any Error).self) { try loadKey(root: root.appending(path: "XcodeCloud"), keys: keys, environment: [:], pins: pins(root)) }
        do {
            _ = try loadKey(root: root.appending(path: "XcodeCloud"), keys: keys, environment: [:], pins: pins(root))
        } catch {
            #expect(error.localizedDescription == "This repo uses key A, which isn't stored on this machine. Store it with: xcflow auth --key-id A --issuer-id <issuer> --p8 <path>, or pick a stored key with: xcflow keys use <key id>.")
        }
    }

    @Test func badUsageExits64() throws {
        let root = try makeRepo()
        for arguments in [["use"], ["remove"], ["frob"], ["use", "A", "B"], ["list", "extra"]] {
            let result = run(arguments, keys: FakeKeys(key("A")), pins: pins(root))
            #expect(result.code == 64, "\(arguments)")
            #expect(!result.output.err.isEmpty)
        }
    }

    @Test func aMalformedRepoFileIsAnError() throws {
        let root = try makeRepo()
        try FileManager.default.createDirectory(at: root.appending(path: "XcodeCloud"), withIntermediateDirectories: true)
        try "nope".write(to: pins(root).legacyFile, atomically: true, encoding: .utf8)
        let result = run([], keys: FakeKeys(key("A")), pins: pins(root))
        #expect(result.code == 2)
        #expect(result.output.err.joined().contains("isn't valid"))
    }

    // MARK: - auth pins the repo

    @Test func authPinsARepoWithXcodeCloudAndNoPin() throws {
        let root = try makeRepo()
        try FileManager.default.createDirectory(at: root.appending(path: "XcodeCloud"), withIntermediateDirectories: true)
        #expect(try Auth.pinIfUnpinned("ABC123", pins: pins(root)) == ["Pinned this repo to key ABC123 on this machine."])
        #expect(try pins(root).pinned() == "ABC123")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "XcodeCloud").path(percentEncoded: false)).isEmpty)
    }

    @Test func authLeavesAnExistingPin() throws {
        let root = try makeRepo()
        try FileManager.default.createDirectory(at: root.appending(path: "XcodeCloud"), withIntermediateDirectories: true)
        try pins(root).pin("OTHER")
        #expect(try Auth.pinIfUnpinned("ABC123", pins: pins(root)).isEmpty)
        #expect(try pins(root).pinned() == "OTHER")
    }

    @Test func authMovesALegacyPinAndKeepsIt() throws {
        let root = try makeRepo()
        try pins(root).writeLegacy("OTHER")
        let lines = try Auth.pinIfUnpinned("ABC123", pins: pins(root))
        #expect(lines == ["Removed XcodeCloud/xcflow.json; this repo's key (OTHER) is now pinned on this machine instead of in the repo."])
        #expect(try pins(root).pinned() == "OTHER")
        #expect(!FileManager.default.fileExists(atPath: pins(root).legacyFile.path(percentEncoded: false)))
    }

    @Test func authOutsideAnXcflowRepoOnlyStores() throws {
        let root = try makeRepo()
        #expect(try Auth.pinIfUnpinned("ABC123", pins: pins(root)).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "XcodeCloud").path(percentEncoded: false)))
    }
}
