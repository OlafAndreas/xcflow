import Foundation

/// `xcflow docs`: rewrites the docs xcflow manages so they match this version. The nightly sync runs it, so the sync PR carries their updates.
enum DocsCommand {
    static let usage = "Usage: xcflow docs [--check]"

    /// 0 up to date or updated, 1 out of date with --check, 2 error, 64 usage.
    static func run(
        arguments: [String],
        root: URL = URL.currentDirectory(),
        out: (String) -> Void = { print($0) },
        err: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) -> Int32 {
        guard arguments.isEmpty || arguments == ["--check"] else {
            err(usage)
            return 64
        }
        let check = arguments == ["--check"]
        do {
            let stale = try refresh(in: root, write: !check)
            if stale.isEmpty {
                out("xcflow's docs in this repo match xcflow \(Version.current).")
                return 0
            }
            out(stale.map { "\(check ? "Out of date" : "Updated") \($0)" }.joined(separator: "\n"))
            return check ? 1 : 0
        } catch {
            err(error.localizedDescription)
            return 2
        }
    }

    /// The managed docs that differ from this version's, written when `write` is set. `XcodeCloud/README.md` is kept in a repo with `XcodeCloud/`; the Claude Code skill and rule only in a repo that has either of them.
    static func refresh(in root: URL, write: Bool) throws -> [String] {
        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appending(path: path).path(percentEncoded: false))
        }
        let claude = Templates.docs.contains { $0.path.hasPrefix(".claude/") && exists($0.path) }
        var stale: [String] = []
        for file in Templates.docs where file.path.hasPrefix(".claude/") ? claude : exists("XcodeCloud") {
            let url = root.appending(path: file.path)
            guard (try? String(contentsOf: url, encoding: .utf8)) != file.content else {
                continue
            }
            if write {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.content.write(to: url, atomically: true, encoding: .utf8)
            }
            stale.append(file.path)
        }
        return stale
    }
}
