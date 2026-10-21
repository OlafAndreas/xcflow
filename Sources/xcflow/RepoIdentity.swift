import Foundation

/// The repo a command or the MCP server works in, and the id that keys its settings on this machine: the key pin and the chosen apps.
struct RepoIdentity: Sendable {
    /// The origin remote without scheme, user or `.git`, else the root's path.
    let id: String
    /// The repo's root folder: git's top level, else the folder itself.
    let root: URL

    typealias Git = (_ directory: URL, _ arguments: [String]) -> String?

    /// The repo of `--root`'s parent folder, else `XCFLOW_REPO_ROOT`, else the working directory.
    static func here(
        root: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL.currentDirectory(),
        git: Git = runGit
    ) -> RepoIdentity {
        let directory = root?.deletingLastPathComponent()
            ?? environment["XCFLOW_REPO_ROOT"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? currentDirectory
        let top = git(directory, ["rev-parse", "--show-toplevel"]).map { URL(filePath: $0, directoryHint: .isDirectory) } ?? directory
        let remote = git(directory, ["remote", "get-url", "origin"]).map(normalizedRemote)
        return RepoIdentity(id: remote ?? top.standardizedFileURL.path(percentEncoded: false).replacing(/\/$/, with: ""), root: top)
    }

    /// `git@github.com:Owner/Repo.git` and `https://user@github.com/Owner/Repo` both become `github.com/owner/repo`, so every clone and worktree of a repo shares its settings.
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
