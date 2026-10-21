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

    private func repoFile(_ root: URL) -> URL {
        root.appending(path: "XcodeCloud/xcflow.json")
    }

    private func key(_ id: String, team: Bool = true) -> Credentials {
        Credentials(keyID: id, privateKeyPEM: "pem-\(id)", issuerID: team ? "issuer-\(id)" : nil)
    }

    private func run(_ arguments: [String], keys: FakeKeys, file: URL) -> (code: Int32, output: Output) {
        let output = Output()
        let code = KeysCommand.run(arguments: arguments, keys: keys, repoFile: file, out: { output.out.append($0) }, err: { output.err.append($0) })
        return (code, output)
    }

    private let noon = ISO8601DateFormatter().date(from: "2026-10-21T12:00:00Z")!

    @Test func listsTheStoredKeysAndMarksTheRepos() throws {
        let root = try makeRepo()
        try RepoKeyFile.write("B", to: repoFile(root))
        let keys = FakeKeys(key("A"), key("B", team: false))
        keys.dates = ["A": noon, "B": noon]
        let result = run([], keys: keys, file: repoFile(root))
        #expect(result.code == 0)
        #expect(result.output.out == [
            "  A  team  stored 2026-10-21",
            "* B  individual  stored 2026-10-21"
        ])
    }

    @Test func listingWithoutARepoFileMarksNone() throws {
        let root = try makeRepo()
        let result = run([], keys: FakeKeys(key("A")), file: repoFile(root))
        #expect(result.code == 0)
        #expect(result.output.out == ["  A  team"])
    }

    @Test func listingWithNoKeysSaysHowToStoreOne() throws {
        let root = try makeRepo()
        let result = run([], keys: FakeKeys(), file: repoFile(root))
        #expect(result.code == 0)
        #expect(result.output.out.joined().contains("xcflow auth"))
    }

    @Test func listingNamesAPinnedKeyThatIsntStored() throws {
        let root = try makeRepo()
        try RepoKeyFile.write("GONE", to: repoFile(root))
        let result = run([], keys: FakeKeys(key("A")), file: repoFile(root))
        #expect(result.code == 0)
        #expect(result.output.out.contains { $0.contains("GONE") && $0.contains("isn't stored") })
    }

    @Test func useWritesTheRepoFileCreatingXcodeCloud() throws {
        let root = try makeRepo()
        let result = run(["use", "A"], keys: FakeKeys(key("A"), key("B")), file: repoFile(root))
        #expect(result.code == 0)
        #expect(try RepoKeyFile.read(repoFile(root)) == "A")
        #expect(result.output.out == ["Pinned this repo to key A in XcodeCloud/xcflow.json."])
    }

    @Test func useReplacesAnExistingPin() throws {
        let root = try makeRepo()
        try RepoKeyFile.write("A", to: repoFile(root))
        #expect(run(["use", "B"], keys: FakeKeys(key("A"), key("B")), file: repoFile(root)).code == 0)
        #expect(try RepoKeyFile.read(repoFile(root)) == "B")
    }

    @Test func useRefusesAnUnstoredKey() throws {
        let root = try makeRepo()
        let result = run(["use", "NOPE"], keys: FakeKeys(key("A")), file: repoFile(root))
        #expect(result.code == 2)
        #expect(result.output.err.joined().contains("NOPE"))
        #expect(result.output.err.joined().contains("xcflow auth --key-id NOPE"))
        #expect(try RepoKeyFile.read(repoFile(root)) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "XcodeCloud").path(percentEncoded: false)))
    }

    @Test func removeDeletesOnlyThatKey() throws {
        let root = try makeRepo()
        let keys = FakeKeys(key("A"), key("B"))
        let result = run(["remove", "A"], keys: keys, file: repoFile(root))
        #expect(result.code == 0)
        #expect(try keys.keys().map(\.keyID) == ["B"])
        #expect(result.output.out.first == "Removed key A from the Keychain.")
    }

    @Test func removeRefusesAnUnstoredKey() throws {
        let root = try makeRepo()
        let keys = FakeKeys(key("A"))
        let result = run(["remove", "NOPE"], keys: keys, file: repoFile(root))
        #expect(result.code == 2)
        #expect(result.output.err.joined().contains("NOPE"))
        #expect(try keys.keys().map(\.keyID) == ["A"])
    }

    @Test func removingThePinnedKeyIsAllowedAndTheNextCommandSaysHowToStoreIt() throws {
        let root = try makeRepo()
        let keys = FakeKeys(key("A"), key("B"))
        #expect(run(["use", "A"], keys: keys, file: repoFile(root)).code == 0)
        let removed = run(["remove", "A"], keys: keys, file: repoFile(root))
        #expect(removed.code == 0)
        #expect(removed.output.out.contains { $0.contains("xcflow.json") && $0.contains("xcflow keys use") })
        #expect(throws: (any Error).self) { try loadKey(root: root.appending(path: "XcodeCloud"), keys: keys, environment: [:]) }
        do {
            _ = try loadKey(root: root.appending(path: "XcodeCloud"), keys: keys, environment: [:])
        } catch {
            #expect(error.localizedDescription == "This repo uses key A (XcodeCloud/xcflow.json), which isn't stored on this machine. Store it with: xcflow auth --key-id A --issuer-id <issuer> --p8 <path>.")
        }
    }

    @Test func badUsageExits64() throws {
        let root = try makeRepo()
        for arguments in [["use"], ["remove"], ["frob"], ["use", "A", "B"], ["list", "extra"]] {
            let result = run(arguments, keys: FakeKeys(key("A")), file: repoFile(root))
            #expect(result.code == 64, "\(arguments)")
            #expect(!result.output.err.isEmpty)
        }
    }

    @Test func aMalformedRepoFileIsAnError() throws {
        let root = try makeRepo()
        try FileManager.default.createDirectory(at: root.appending(path: "XcodeCloud"), withIntermediateDirectories: true)
        try "nope".write(to: repoFile(root), atomically: true, encoding: .utf8)
        let result = run([], keys: FakeKeys(key("A")), file: repoFile(root))
        #expect(result.code == 2)
        #expect(result.output.err.joined().contains("isn't valid"))
    }

    // MARK: - auth pins the repo

    @Test func authPinsARepoWithXcodeCloudAndNoFile() throws {
        let root = try makeRepo()
        try FileManager.default.createDirectory(at: root.appending(path: "XcodeCloud"), withIntermediateDirectories: true)
        #expect(try Auth.pinIfUnpinned("ABC123", file: repoFile(root)) == "Pinned this repo to key ABC123 in XcodeCloud/xcflow.json.")
        #expect(try RepoKeyFile.read(repoFile(root)) == "ABC123")
    }

    @Test func authLeavesAnExistingPin() throws {
        let root = try makeRepo()
        try RepoKeyFile.write("OTHER", to: repoFile(root))
        #expect(try Auth.pinIfUnpinned("ABC123", file: repoFile(root)) == nil)
        #expect(try RepoKeyFile.read(repoFile(root)) == "OTHER")
    }

    @Test func authOutsideAnXcflowRepoOnlyStores() throws {
        let root = try makeRepo()
        #expect(try Auth.pinIfUnpinned("ABC123", file: repoFile(root)) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "XcodeCloud").path(percentEncoded: false)))
    }
}
