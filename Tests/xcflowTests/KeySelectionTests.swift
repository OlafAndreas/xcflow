import Foundation
import Testing
@testable import xcflow

@Suite struct KeySelectionTests {
    private let team = StoredKey(keyID: "TEAM1", isTeamKey: true, stored: nil)
    private let solo = StoredKey(keyID: "SOLO1", isTeamKey: false, stored: nil)
    private let pem = "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----"

    private func message(_ body: () throws -> Any) -> String? {
        do { _ = try body(); return nil } catch { return error.localizedDescription }
    }

    @Test func environmentKeyWinsOverPinAndStored() throws {
        let environment = ["ASC_KEY_ID": "ENV1", "ASC_KEY_CONTENT": pem, "ASC_ISSUER_ID": "iss"]
        let choice = try KeySelection.choose(environment: environment, pinned: "TEAM1", stored: [team, solo])
        #expect(choice == .environment(Credentials(keyID: "ENV1", privateKeyPEM: pem, issuerID: "iss")))
    }

    @Test func pinnedKeyIsUsedWhenStored() throws {
        let choice = try KeySelection.choose(environment: [:], pinned: "SOLO1", stored: [team, solo])
        #expect(choice == .stored(keyID: "SOLO1"))
    }

    @Test func pinnedKeyNotStoredSaysSo() {
        let text = message { try KeySelection.choose(environment: [:], pinned: "GONE1", stored: [team]) }
        #expect(text == "This repo uses key GONE1 (XcodeCloud/xcflow.json), which isn't stored on this machine. Store it with: xcflow auth --key-id GONE1 --issuer-id <issuer> --p8 <path>.")
    }

    @Test func onlyStoredKeyIsUsedWithoutPin() throws {
        let choice = try KeySelection.choose(environment: [:], pinned: nil, stored: [solo])
        #expect(choice == .stored(keyID: "SOLO1"))
    }

    @Test func severalStoredKeysAskForAPin() {
        let text = message { try KeySelection.choose(environment: [:], pinned: nil, stored: [team, solo]) }
        #expect(text == "Several App Store Connect keys are stored (SOLO1 individual, TEAM1 team). Pick this repo's key with: xcflow keys use <key id>.")
    }

    @Test func noKeysIsTheMissingError() {
        let text = message { try KeySelection.choose(environment: [:], pinned: nil, stored: []) }
        #expect(text == CredentialError.missing.localizedDescription)
    }

    // MARK: location

    private let cwd = URL(filePath: "/work/here", directoryHint: .isDirectory)

    @Test func rootOptionPutsTheFileInTheRoot() {
        let url = RepoKeyFile.url(root: URL(filePath: "/r/XcodeCloud", directoryHint: .isDirectory), environment: ["XCFLOW_REPO_ROOT": "/x"], gitRoot: { nil }, currentDirectory: cwd)
        #expect(url.path == "/r/XcodeCloud/xcflow.json")
    }

    @Test func repoRootEnvironmentComesBeforeGit() {
        let url = RepoKeyFile.url(root: nil, environment: ["XCFLOW_REPO_ROOT": "/x"], gitRoot: { URL(filePath: "/git") }, currentDirectory: cwd)
        #expect(url.path == "/x/XcodeCloud/xcflow.json")
    }

    @Test func gitRootComesBeforeTheWorkingDirectory() {
        let url = RepoKeyFile.url(root: nil, environment: [:], gitRoot: { URL(filePath: "/git", directoryHint: .isDirectory) }, currentDirectory: cwd)
        #expect(url.path == "/git/XcodeCloud/xcflow.json")
    }

    @Test func workingDirectoryIsTheLastResort() {
        let url = RepoKeyFile.url(root: nil, environment: [:], gitRoot: { nil }, currentDirectory: cwd)
        #expect(url.path == "/work/here/XcodeCloud/xcflow.json")
    }

    // MARK: file

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "XcodeCloud/xcflow.json")
    }

    @Test func absentFileReadsAsNil() throws {
        #expect(try RepoKeyFile.read(tempFile()) == nil)
    }

    @Test func writeCreatesFolderAndReadsBack() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        try RepoKeyFile.write("ABC123", to: url)
        #expect(try RepoKeyFile.read(url) == "ABC123")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == "{\n  \"keyID\" : \"ABC123\"\n}\n")
    }

    @Test func malformedFileSaysSo() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "nope".write(to: url, atomically: true, encoding: .utf8)
        let text = message { try RepoKeyFile.read(url) as Any }
        #expect(text == "XcodeCloud/xcflow.json isn't valid: expected {\"keyID\": \"…\"}.")
    }

    // MARK: loadKey

    @Test func loadKeyUsesThePinnedKey() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try RepoKeyFile.write("SOLO1", to: root.appending(path: "xcflow.json"))
        let keys = FakeKeys(
            Credentials(keyID: "TEAM1", privateKeyPEM: "t", issuerID: "i"),
            Credentials(keyID: "SOLO1", privateKeyPEM: "s", issuerID: nil)
        )
        let credentials = try loadKey(root: root, keys: keys, environment: [:])
        #expect(credentials.keyID == "SOLO1")
    }

    @Test func loadKeyPrefersTheEnvironment() throws {
        let credentials = try loadKey(root: nil, keys: FakeKeys(), environment: ["ASC_KEY_ID": "E", "ASC_KEY_CONTENT": pem])
        #expect(credentials.keyID == "E")
    }
}
