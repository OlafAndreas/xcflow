import Foundation

enum KeySelection {
    enum Choice: Equatable {
        case environment(Credentials)
        case stored(keyID: String)
    }

    /// Pure: environment variables, the repo file's key id, the stored keys.
    static func choose(environment: [String: String], pinned: String?, stored: [StoredKey]) throws -> Choice {
        if let credentials = try CredentialStore.fromEnvironment(environment) {
            return .environment(credentials)
        }
        if let pinned {
            guard stored.contains(where: { $0.keyID == pinned }) else {
                throw CredentialError.environment("This repo uses key \(pinned) (\(RepoKeyFile.displayPath)), which isn't stored on this machine. Store it with: xcflow auth --key-id \(pinned) --issuer-id <issuer> --p8 <path>.")
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

enum RepoKeyFile {
    /// How messages name the file.
    static let displayPath = "XcodeCloud/xcflow.json"

    private struct Contents: Codable {
        let keyID: String
    }

    /// `<root>/xcflow.json` for `--root`; otherwise `<repo>/XcodeCloud/xcflow.json`.
    static func url(root: URL?, environment: [String: String], gitRoot: () -> URL?, currentDirectory: URL) -> URL {
        if let root {
            return root.appending(path: "xcflow.json")
        }
        let repo = environment["XCFLOW_REPO_ROOT"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? gitRoot()
            ?? currentDirectory
        return repo.appending(path: "XcodeCloud/xcflow.json")
    }

    /// The key id in the file; nil when the file is absent.
    static func read(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let contents = try? JSONDecoder().decode(Contents.self, from: data),
              !contents.keyID.isEmpty
        else {
            throw CredentialError.environment("\(displayPath) isn't valid: expected {\"keyID\": \"…\"}.")
        }
        return contents.keyID
    }

    static func write(_ keyID: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(Contents(keyID: keyID))
        data.append(Data("\n".utf8))
        try data.write(to: url, options: .atomic)
    }

    /// The repo root from git, or nil outside a repository.
    static func gitRoot() -> URL? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["git", "rev-parse", "--show-toplevel"]
        process.currentDirectoryURL = URL.currentDirectory()
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
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(filePath: path, directoryHint: .isDirectory)
    }
}

/// The one entry point every command uses: the environment's key, else the key this repo pins, else the only stored key.
func loadKey(
    root: URL?,
    keys: any KeyStore = KeychainKeyStore(),
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> Credentials {
    if let credentials = try CredentialStore.fromEnvironment(environment) {
        return credentials
    }
    let file = RepoKeyFile.url(root: root, environment: environment, gitRoot: RepoKeyFile.gitRoot, currentDirectory: URL.currentDirectory())
    let pinned = try RepoKeyFile.read(file)
    switch try KeySelection.choose(environment: environment, pinned: pinned, stored: keys.keys()) {
    case .environment(let credentials):
        return credentials
    case .stored(let keyID):
        return try keys.load(keyID: keyID)
    }
}
