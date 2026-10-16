import Foundation

extension XcodeCloudTools {
    private static let maxLinesPerAction = 60
    static let repositoryRoot = "/Volumes/workspace/repository/"

    func getBuildLogs(_ client: AppStoreConnectClient, build reference: String, action actionName: String?) async throws -> String {
        let runID = try await buildRunID(client, reference)
        let run = try await client.get("/v1/ciBuildRuns/\(runID)", query: ["fields[ciBuildRuns]": "number"])
        let number = (run["data"] as? JSON)?.attributes["number"] ?? runID
        let actions = try await client.getAll("/v1/ciBuildRuns/\(runID)/actions").data

        let selected: [JSON]
        if let actionName {
            selected = actions.filter { $0.string("name")?.caseInsensitiveCompare(actionName) == .orderedSame }
            guard !selected.isEmpty else {
                let names = actions.compactMap { $0.string("name") }.joined(separator: ", ")
                throw ToolError.notFound("No action named \"\(actionName)\". Actions: \(names)")
            }
        } else {
            let failed = actions.filter { ["FAILED", "ERRORED"].contains($0.string("completionStatus")) }
            selected = failed.isEmpty ? actions : failed
        }

        let buildFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "xcflow/build-\(number)")

        var sections: [String] = []
        for action in selected {
            let name = action.string("name") ?? action.id
            let artifacts = try await client.getAll("/v1/ciBuildActions/\(action.id)/artifacts").data
            guard let logBundle = artifacts.first(where: { $0.string("fileType") == "LOG_BUNDLE" }),
                  let downloadURL = logBundle.string("downloadUrl").flatMap(URL.init(string:))
            else {
                sections.append("## \(name)\nNo log bundle (the action may have been skipped).")
                continue
            }

            let folder = buildFolder.appending(path: name.replacingOccurrences(of: "/", with: "-"))
            try await extract(client, downloadURL, into: folder)
            sections.append("## \(name)\nFull logs: \(folder.path)\n\(summary(ofLogsIn: folder))")
        }
        return sections.joined(separator: "\n\n")
    }

    private func extract(_ client: AppStoreConnectClient, _ url: URL, into folder: URL) async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: folder.path) {
            return
        }
        try fileManager.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        let archive = folder.appendingPathExtension("zip")
        try await client.download(url, to: archive)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        try? fileManager.removeItem(at: archive)
        guard ditto.terminationStatus == 0 else {
            try? fileManager.removeItem(at: folder)
            throw ToolError.refused("Could not unpack the log bundle (ditto exited with \(ditto.terminationStatus)).")
        }
    }

    private func summary(ofLogsIn folder: URL) -> String {
        let logs = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "log" }
            .sorted { $0.path < $1.path }

        var seen = Set<String>()
        var lines: [String] = []
        var finalStatus: String?
        for log in logs {
            guard let content = try? String(contentsOf: log, encoding: .utf8) else {
                continue
            }
            for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = Self.stripTimestamp(rawLine)
                if line.hasPrefix("** ") && line.hasSuffix(" **") {
                    finalStatus = "\(log.lastPathComponent): \(line)"
                }
                guard Self.isProblem(line), seen.insert(line).inserted else {
                    continue
                }
                lines.append(line)
            }
        }

        var output = lines.prefix(Self.maxLinesPerAction).map { $0 }
        if lines.count > Self.maxLinesPerAction {
            output.append("… \(lines.count - Self.maxLinesPerAction) more lines, see the full logs.")
        }
        if output.isEmpty {
            output.append("No error lines found.")
        }
        if let finalStatus {
            output.append(finalStatus)
        }
        return output.joined(separator: "\n")
    }

    private static func stripTimestamp(_ line: Substring) -> String {
        let text = line.firstIndex(of: "\t").map { line[line.index(after: $0)...] } ?? line
        return String(text).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: repositoryRoot, with: "")
    }

    private static func isProblem(_ line: String) -> Bool {
        if line.hasPrefix("|") || line.hasPrefix("`-") {
            return false
        }
        return line.contains(": error: ")
            || line.contains(": fatal error: ")
            || line.hasPrefix("error: ")
            || (line.hasPrefix("Test Case") && line.contains(" failed"))
            || line.contains(": XCTAssert")
            || line.contains("✘")
            || line.hasPrefix("Failing tests:")
    }
}
