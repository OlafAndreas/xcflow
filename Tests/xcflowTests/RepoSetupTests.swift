import Foundation
import Testing
@testable import xcflow

struct RepoSetupTests {
    private let checksum = String(repeating: "a", count: 64)

    private var checksums: [String: String] {
        Dictionary(uniqueKeysWithValues: Templates.archives(version: Version.current).values.map { ($0, checksum) })
    }

    private func checksumsFile() throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "xcflow-checksums-\(UUID().uuidString).txt")
        try checksums.map { "\($0.value)  \($0.key)" }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path(percentEncoded: false)
    }

    private func makeRepo(mcp: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "xcflow-setup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let mcp {
            try mcp.write(to: root.appending(path: ".mcp.json"), atomically: true, encoding: .utf8)
        }
        return root
    }

    private func files(in root: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        let base = root.standardizedFileURL.path(percentEncoded: false)
        return (enumerator?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { String($0.standardizedFileURL.path(percentEncoded: false).dropFirst(base.count)).replacing(/^\//, with: "") }
            .sorted()
    }

    private func setup(_ root: URL, _ extra: [String] = []) async throws {
        try await RepoSetup.run(arguments: ["--repo", root.path(percentEncoded: false), "--products", "com.example.app", "--skip-export", "--skip-secrets", "--checksums", try checksumsFile()] + extra)
    }

    @Test func dryRunWritesNothing() async throws {
        let root = try makeRepo()
        try await setup(root, ["--dry-run"])
        #expect(files(in: root).isEmpty)
    }

    @Test func setupWritesEveryFileAndIsIdempotent() async throws {
        let root = try makeRepo(mcp: #"{"mcpServers":{"other":{"type":"stdio","command":"other"}}}"#)
        try await setup(root)
        #expect(files(in: root) == [
            ".claude/rules/xcode-cloud.md",
            ".claude/skills/edit-xcode-cloud-workflow/SKILL.md",
            ".github/actions/xcflow/action.yml",
            ".github/workflows/xcflow-apply.yml",
            ".github/workflows/xcflow-plan.yml",
            ".github/workflows/xcflow-sync.yml",
            ".mcp.json",
            "XcodeCloud/README.md"
        ])
        let mcp = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: ".mcp.json"))) as? JSON
        let servers = mcp?["mcpServers"] as? JSON
        #expect(servers?.keys.sorted() == ["other", "xcflow"])

        let prompt = Prompt(yes: false, dryRun: false)
        for file in Templates.files(version: Version.current, checksums: checksums) {
            #expect(try RepoSetup.write(file, in: root, force: false, dryRun: false, prompt: prompt) == .unchanged)
        }
        #expect(try RepoSetup.mergeMCPEntry(in: root, dryRun: false) == .unchanged)
    }

    @Test func changedFilesAreKeptUnlessForced() async throws {
        let root = try makeRepo()
        try await setup(root)
        let rule = root.appending(path: ".claude/rules/xcode-cloud.md")
        try "custom".write(to: rule, atomically: true, encoding: .utf8)

        try await setup(root)
        #expect(try String(contentsOf: rule, encoding: .utf8) == "custom")

        try await setup(root, ["--force"])
        #expect(try String(contentsOf: rule, encoding: .utf8) != "custom")
    }

    @Test func installActionPicksTheArchiveForTheRunner() {
        let pinned = Templates.files(version: "1.2.3", checksums: [
            "xcflow-1.2.3-linux-x86_64.tar.gz": "2" + String(repeating: "0", count: 63),
            "xcflow-1.2.3-linux-aarch64.tar.gz": "3" + String(repeating: "0", count: 63)
        ]).first { $0.path == ".github/actions/xcflow/action.yml" }?.content ?? ""
        #expect(pinned.contains("releases/download/v1.2.3/$NAME"))
        #expect(pinned.contains(#"Linux-X64) NAME="xcflow-1.2.3-linux-x86_64.tar.gz"; SUM="2"#))
        #expect(pinned.contains(#"Linux-ARM64) NAME="xcflow-1.2.3-linux-aarch64.tar.gz"; SUM="3"#))
        #expect(!pinned.contains("macOS-"))
        #expect(!pinned.contains("xcflow-1.2.3.tar.gz"))
        #expect(pinned.contains("Linux runners only"))
        #expect(!pinned.contains("{{"))

        let unpinned = Templates.files(version: "1.2.3", checksums: [:]).first { $0.path == ".github/actions/xcflow/action.yml" }?.content ?? ""
        #expect(unpinned.contains(#"SUM="" ;;"#))
        #expect(!unpinned.contains("{{"))
    }

    @Test func workflowsRunOnLinux() {
        let workflows = Templates.files(version: "1.2.3", checksums: [:]).filter { $0.path.hasPrefix(".github/workflows/") }
        #expect(workflows.count == 3)
        #expect(workflows.allSatisfy { $0.content.contains("runs-on: ubuntu-latest") && !$0.content.contains("macos") })
    }

    @Test func checksumFilesAreParsed() {
        let sha = String(repeating: "b", count: 64)
        let parsed = RepoSetup.parseChecksums("\(sha)  xcflow-1.2.3.tar.gz\n\(sha) *xcflow-1.2.3-linux-x86_64.tar.gz\nnot a checksum line\n")
        #expect(parsed == ["xcflow-1.2.3.tar.gz": sha, "xcflow-1.2.3-linux-x86_64.tar.gz": sha])
    }
}
