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
        #expect(text == "This repo uses key GONE1, which isn't stored on this machine. Store it with: xcflow auth --key-id GONE1 --issuer-id <issuer> --p8 <path>, or pick a stored key with: xcflow keys use <key id>.")
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

    // MARK: the repo

    private let cwd = URL(filePath: "/work/here", directoryHint: .isDirectory)

    /// git answering from a table of (directory, first argument) → output, and recording where it ran.
    private func git(_ answers: [String: String]) -> KeyPins.Git {
        { directory, arguments in answers["\(directory.path(percentEncoded: false))|\(arguments[0])"] }
    }

    @Test func theOriginRemoteNamesTheRepo() {
        let pins = KeyPins.here(root: nil, environment: [:], currentDirectory: cwd, git: git([
            "/work/here/|rev-parse": "/work",
            "/work/here/|remote": "git@github.com:Team/App.git"
        ]))
        #expect(pins.repo == "github.com/team/app")
        #expect(pins.legacyFile.path == "/work/XcodeCloud/xcflow.json")
    }

    @Test func withoutARemoteTheGitRootNamesTheRepo() {
        let pins = KeyPins.here(root: nil, environment: [:], currentDirectory: cwd, git: git(["/work/here/|rev-parse": "/work"]))
        #expect(pins.repo == "/work")
    }

    @Test func outsideGitTheFolderNamesTheRepo() {
        let pins = KeyPins.here(root: nil, environment: [:], currentDirectory: cwd, git: git([:]))
        #expect(pins.repo == "/work/here")
        #expect(pins.legacyFile.path == "/work/here/XcodeCloud/xcflow.json")
    }

    @Test func repoRootEnvironmentComesBeforeTheWorkingDirectory() {
        let pins = KeyPins.here(root: nil, environment: ["XCFLOW_REPO_ROOT": "/x"], currentDirectory: cwd, git: git(["/x/|remote": "https://github.com/team/x"]))
        #expect(pins.repo == "github.com/team/x")
        #expect(pins.legacyFile.path == "/x/XcodeCloud/xcflow.json")
    }

    @Test func theRootOptionAsksGitInItsParent() {
        let root = URL(filePath: "/r/XcodeCloud", directoryHint: .isDirectory)
        let pins = KeyPins.here(root: root, environment: ["XCFLOW_REPO_ROOT": "/x"], currentDirectory: cwd, git: git(["/r/|remote": "ssh://git@host.example:22/team/r.git"]))
        #expect(pins.repo == "host.example:22/team/r")
        #expect(pins.legacyFile.path == "/r/XcodeCloud/xcflow.json")
    }

    @Test func remotesOfOneRepoAgree() {
        let remotes = [
            "git@github.com:Team/App.git",
            "https://github.com/team/app.git",
            "https://user:token@github.com/Team/App/",
            "ssh://git@github.com/team/app"
        ]
        #expect(Set(remotes.map(KeyPins.normalizedRemote)) == ["github.com/team/app"])
    }

    // MARK: the store

    private func tempPins(repo: String = "github.com/team/app") -> KeyPins {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        return KeyPins(store: folder.appending(path: "repos.json"), repo: repo, legacyFile: folder.appending(path: "repo/XcodeCloud/xcflow.json"))
    }

    @Test func noStoreReadsAsNoPin() throws {
        #expect(try tempPins().pinned() == nil)
    }

    @Test func pinsAreKeptPerRepo() throws {
        let app = tempPins()
        let other = KeyPins(store: app.store, repo: "github.com/team/other", legacyFile: app.legacyFile)
        try app.pin("ABC123")
        try other.pin("XYZ789")
        try app.pin("DEF456")
        #expect(try app.pinned() == "DEF456")
        #expect(try other.pinned() == "XYZ789")
        let text = try String(contentsOf: app.store, encoding: .utf8)
        #expect(text == "{\n  \"github.com/team/app\" : \"DEF456\",\n  \"github.com/team/other\" : \"XYZ789\"\n}\n")
    }

    @Test func aMalformedStoreSaysSo() throws {
        let pins = tempPins()
        try FileManager.default.createDirectory(at: pins.store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "nope".write(to: pins.store, atomically: true, encoding: .utf8)
        let text = message { try pins.pinned() as Any }
        #expect(text == "\(pins.store.path(percentEncoded: false)) isn't valid: expected {\"<repo>\": \"<key id>\"}.")
    }

    // MARK: the legacy file

    @Test func aLegacyFileIsReadWhenTheStoreHasNoPin() throws {
        let pins = tempPins()
        try pins.writeLegacy("OLD1")
        #expect(try pins.pinned() == "OLD1")
        try pins.pin("NEW1")
        #expect(try pins.pinned() == "NEW1")
    }

    @Test func aMalformedLegacyFileSaysSo() throws {
        let pins = tempPins()
        try pins.writeLegacy("x")
        try "nope".write(to: pins.legacyFile, atomically: true, encoding: .utf8)
        let text = message { try pins.pinned() as Any }
        #expect(text == "XcodeCloud/xcflow.json isn't valid: expected {\"keyID\": \"…\"}.")
    }

    @Test func movingALegacyPinStoresItAndDeletesTheFile() throws {
        let pins = tempPins()
        #expect(try pins.moveLegacyPin() == nil)
        try pins.writeLegacy("OLD1")
        #expect(try pins.moveLegacyPin(dryRun: true) != nil)
        #expect(FileManager.default.fileExists(atPath: pins.legacyFile.path(percentEncoded: false)))
        #expect(try pins.moveLegacyPin() == "Removed XcodeCloud/xcflow.json; this repo's key (OLD1) is now pinned on this machine instead of in the repo.")
        #expect(!FileManager.default.fileExists(atPath: pins.legacyFile.path(percentEncoded: false)))
        #expect(try pins.pinned() == "OLD1")
    }

    @Test func movingALegacyPinKeepsTheStoresPin() throws {
        let pins = tempPins()
        try pins.pin("NEW1")
        try pins.writeLegacy("OLD1")
        _ = try pins.moveLegacyPin()
        #expect(try pins.pinned() == "NEW1")
    }

    // MARK: loadKey

    @Test func loadKeyUsesThePinnedKey() throws {
        let pins = tempPins()
        try pins.pin("SOLO1")
        let keys = FakeKeys(
            Credentials(keyID: "TEAM1", privateKeyPEM: "t", issuerID: "i"),
            Credentials(keyID: "SOLO1", privateKeyPEM: "s", issuerID: nil)
        )
        let credentials = try loadKey(root: nil, keys: keys, environment: [:], pins: pins)
        #expect(credentials.keyID == "SOLO1")
    }

    @Test func loadKeyPrefersTheEnvironment() throws {
        let credentials = try loadKey(root: nil, keys: FakeKeys(), environment: ["ASC_KEY_ID": "E", "ASC_KEY_CONTENT": pem], pins: tempPins())
        #expect(credentials.keyID == "E")
    }
}
