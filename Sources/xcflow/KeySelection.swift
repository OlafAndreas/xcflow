import Foundation

enum KeySelection {
    enum Choice: Equatable {
        case environment(Credentials)
        case stored(keyID: String)
    }

    /// Pure: environment variables, the repo's pinned key id, the stored keys.
    static func choose(environment: [String: String], pinned: String?, stored: [StoredKey]) throws -> Choice {
        if let credentials = try CredentialStore.fromEnvironment(environment) {
            return .environment(credentials)
        }
        if let pinned {
            guard stored.contains(where: { $0.keyID == pinned }) else {
                throw CredentialError.environment("This repo uses key \(pinned), which isn't stored on this machine. Store it with: xcflow auth --key-id \(pinned) --issuer-id <issuer> --p8 <path>, or pick a stored key with: xcflow keys use <key id>.")
            }
            return .stored(keyID: pinned)
        }
        switch stored.count {
        case 0:
            throw CredentialError.missing
        case 1:
            return .stored(keyID: stored[0].keyID)
        default:
            let list = stored.sorted { $0.keyID < $1.keyID }
                .map { "\($0.keyID) \($0.isTeamKey ? "team" : "individual")" }
                .joined(separator: ", ")
            throw CredentialError.environment("Several App Store Connect keys are stored (\(list)). Pick this repo's key with: xcflow keys use <key id>.")
        }
    }
}

/// Which stored key each repo uses on this machine. The pins live outside the repos, in xcflow's own settings: the keys are in this machine's Keychain, and another developer's holds other ones.
struct KeyPins {
    /// The JSON object mapping each repo to its key id.
    let store: URL
    /// The repo: its origin remote without scheme, user or `.git`, else its root's path.
    let repo: String
    /// `XcodeCloud/xcflow.json`, where xcflow 0.2.12 kept the pin inside the repo. Read when the store has none.
    let legacyFile: URL

    typealias Git = (_ directory: URL, _ arguments: [String]) -> String?

    static let defaultStore = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "xcflow/repos.json")

    /// The repo of `--root`'s parent folder, else `XCFLOW_REPO_ROOT`, else the working directory.
    static func here(
        root: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL.currentDirectory(),
        git: Git = runGit,
        store: URL = defaultStore
    ) -> KeyPins {
        let directory = root?.deletingLastPathComponent()
            ?? environment["XCFLOW_REPO_ROOT"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? currentDirectory
        let top = git(directory, ["rev-parse", "--show-toplevel"]).map { URL(filePath: $0, directoryHint: .isDirectory) } ?? directory
        let remote = git(directory, ["remote", "get-url", "origin"]).map(normalizedRemote)
        return KeyPins(
            store: store,
            repo: remote ?? top.standardizedFileURL.path(percentEncoded: false).replacing(/\/$/, with: ""),
            legacyFile: root?.appending(path: "xcflow.json") ?? top.appending(path: "XcodeCloud/xcflow.json")
        )
    }

    /// `git@github.com:Owner/Repo.git` and `https://user@github.com/Owner/Repo` both become `github.com/owner/repo`, so every clone and worktree of a repo shares its pin.
    static func normalizedRemote(_ remote: String) -> String {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasScheme = text.contains("://")
        text = text.replacing(/^[A-Za-z][A-Za-z0-9+.-]*:\/\//, with: "")
        text = text.replacing(/^[^@\/]+@/, with: "")
        if !hasScheme {
            text = text.replacing(/^([^\/:]+):/, with: { "\($0.1)/" })
        }
        text = text.replacing(/\/+$/, with: "").replacing(/\.git$/, with: "")
        return text.lowercased()
    }

    /// The pinned key id: the store's, else the repo's legacy file's.
    func pinned() throws -> String? {
        try read()[repo] ?? legacyKeyID()
    }

    func pin(_ keyID: String) throws {
        var pins = try read()
        pins[repo] = keyID
        try write(pins)
    }

    /// Moves a legacy `XcodeCloud/xcflow.json` into the store, unless the store pins this repo already, and deletes the file. The line to print, or nil when there was no file.
    func moveLegacyPin(dryRun: Bool = false) throws -> String? {
        guard let keyID = try legacyKeyID() else { return nil }
        if dryRun {
            return "Would move the key pin out of the repo: XcodeCloud/xcflow.json is replaced by this machine's xcflow settings."
        }
        if try read()[repo] == nil {
            try pin(keyID)
        }
        try FileManager.default.removeItem(at: legacyFile)
        return "Removed XcodeCloud/xcflow.json; this repo's key (\(try pinned() ?? keyID)) is now pinned on this machine instead of in the repo."
    }

    private func read() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: store.path(percentEncoded: false)) else { return [:] }
        guard let pins = try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: store)) else {
            throw CredentialError.environment("\(store.path(percentEncoded: false)) isn't valid: expected {\"<repo>\": \"<key id>\"}.")
        }
        return pins
    }

    private func write(_ pins: [String: String]) throws {
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(pins)
        data.append(Data("\n".utf8))
        try data.write(to: store, options: .atomic)
    }

    private struct LegacyContents: Codable {
        let keyID: String
    }

    private func legacyKeyID() throws -> String? {
        guard FileManager.default.fileExists(atPath: legacyFile.path(percentEncoded: false)) else { return nil }
        guard let contents = try? JSONDecoder().decode(LegacyContents.self, from: Data(contentsOf: legacyFile)), !contents.keyID.isEmpty else {
            throw CredentialError.environment("XcodeCloud/xcflow.json isn't valid: expected {\"keyID\": \"…\"}.")
        }
        return contents.keyID
    }

    /// git's trimmed output in `directory`, or nil when it fails or prints nothing.
    static func runGit(in directory: URL, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// The one entry point every command uses: the environment's key, else the key this repo pins, else the only stored key.
func loadKey(
    root: URL?,
    keys: any KeyStore = KeychainKeyStore(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    pins: KeyPins? = nil
) throws -> Credentials {
    if let credentials = try CredentialStore.fromEnvironment(environment) {
        return credentials
    }
    let pinned = try (pins ?? KeyPins.here(root: root, environment: environment)).pinned()
    switch try KeySelection.choose(environment: environment, pinned: pinned, stored: keys.keys()) {
    case .environment(let credentials):
        return credentials
    case .stored(let keyID):
        return try keys.load(keyID: keyID)
    }
}
