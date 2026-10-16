import Foundation
import Testing
@testable import xcflow

struct RepoSetupTests {
    private let checksum = String(repeating: "a", count: 64)

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
        try await RepoSetup.run(arguments: ["--repo", root.path(percentEncoded: false), "--products", "com.example.app", "--skip-export", "--skip-secrets", "--checksum", checksum] + extra)
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
        for file in Templates.files(version: Version.current, checksum: checksum) {
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

    @Test func installActionPinsVersionAndChecksum() {
        let action = Templates.files(version: "1.2.3", checksum: checksum).first { $0.path == ".github/actions/xcflow/action.yml" }?.content ?? ""
        #expect(action.contains("releases/download/v1.2.3/xcflow-1.2.3.tar.gz"))
        #expect(action.contains("echo \"\(checksum)  $ARCHIVE\" | shasum -a 256 -c -"))
        let unpinned = Templates.files(version: "1.2.3", checksum: nil).first { $0.path == ".github/actions/xcflow/action.yml" }?.content ?? ""
        #expect(!unpinned.contains("shasum"))
        #expect(!unpinned.contains("{{"))
    }
}
