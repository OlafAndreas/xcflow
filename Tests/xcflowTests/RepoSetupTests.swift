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

    @Test func dryRunFetchesTheReleaseChecksums() async throws {
        let root = try makeRepo()
        let published = checksums.map { "\($0.value)  \($0.key)" }.joined(separator: "\n")
        let todo = try await RepoSetup.run(
            arguments: ["--repo", root.path(percentEncoded: false), "--products", "com.example.app", "--skip-export", "--skip-secrets", "--dry-run"],
            releaseChecksums: { version in version == Version.current ? published : nil }
        )
        #expect(!todo.contains { $0.contains("Missing") })
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

    @Test func generatedActionsPinTheCurrentCheckout() {
        let generated = Templates.files(version: "1.2.3", checksums: [:]).filter { $0.path.hasPrefix(".github/") }
        let pins = generated.flatMap { $0.content.matches(of: /actions\/checkout@v\d+/).map { String($0.output) } }
        #expect(pins.count == 3)
        #expect(pins.allSatisfy { $0 == "actions/checkout@v7" })
    }

    @Test func workflowsRunOnLinux() {
        let workflows = Templates.files(version: "1.2.3", checksums: [:]).filter { $0.path.hasPrefix(".github/workflows/") }
        #expect(workflows.count == 3)
        #expect(workflows.allSatisfy { $0.content.contains("runs-on: ubuntu-latest") && !$0.content.contains("macos") })
    }

    @Test func secretsThatAreAllSetAreSkipped() {
        let decision = RepoSetup.SecretsDecision(existing: .success(["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_CONTENT", "OTHER"]), replace: false)
        #expect(decision.question == nil)
        #expect(decision.message.contains("Skipping"))
    }

    @Test func secretsCanBeReplacedOnRequest() {
        let decision = RepoSetup.SecretsDecision(existing: .success(["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_CONTENT"]), replace: true)
        #expect(decision.question == "Replace all three, from a team API key?")
    }

    @Test func missingSecretsAreNamedAndSetTogether() {
        let partial = RepoSetup.SecretsDecision(existing: .success(["ASC_KEY_ID"]), replace: false)
        #expect(partial.message.hasPrefix("ASC_ISSUER_ID, ASC_KEY_CONTENT are missing"))
        #expect(partial.question == "Set all three, from a team API key?")

        let none = RepoSetup.SecretsDecision(existing: .success(["TAP_TOKEN"]), replace: false)
        #expect(none.message.hasPrefix("None of"))
        #expect(none.question == "Set them, from a team API key?")
    }

    @Test func unreadableSecretsFallBackToAsking() {
        let decision = RepoSetup.SecretsDecision(existing: .failure(ToolError.refused("gh is not logged in")), replace: false)
        #expect(decision.message == "Couldn't read the repo's GitHub secrets: gh is not logged in")
        #expect(decision.question != nil)
    }

    @Test func checksumFilesAreParsed() {
        let sha = String(repeating: "b", count: 64)
        let parsed = RepoSetup.parseChecksums("\(sha)  xcflow-1.2.3.tar.gz\n\(sha) *xcflow-1.2.3-linux-x86_64.tar.gz\nnot a checksum line\n")
        #expect(parsed == ["xcflow-1.2.3.tar.gz": sha, "xcflow-1.2.3-linux-x86_64.tar.gz": sha])
    }

    private func setupTodo(_ root: URL, _ extra: [String], client: AppStoreConnectClient? = nil) async throws -> [String] {
        try await RepoSetup.run(arguments: ["--repo", root.path(percentEncoded: false), "--skip-secrets", "--checksums", try checksumsFile()] + extra, client: client)
    }

    @Test func setupWithoutAManifestExplainsTheFirstTimeSetupAndStillWritesTheFiles() async throws {
        let root = try makeRepo()
        try Fixtures.makeProject(in: root, project: "Example.xcodeproj")
        let todo = try await setupTodo(root, ["--skip-export"])
        #expect(files(in: root).contains(".github/workflows/xcflow-apply.yml"))
        #expect(todo.contains { $0.contains("first Xcode Cloud workflow") })
        #expect(!todo.contains { $0.contains("Choose the products") })
    }

    @Test func setupExportsTheProductsInTheManifest() async throws {
        let root = try makeRepo()
        try Fixtures.writeManifest(in: root, project: "Example.xcodeproj", productIDs: ["<ciProducts: com.example.app>"])
        let server = try DryRunServer(snapshot: try Fixtures.standard(), desired: root.appending(path: "XcodeCloud"))
        let todo = try await setupTodo(root, ["--yes"], client: AppStoreConnectClient(dryRun: server))
        #expect(files(in: root).contains("XcodeCloud/com.example.app/nightly-tests.json"))
        #expect(!todo.contains { $0.contains("xcflow export") })
    }

    @Test func setupKeepsGoingWhenTheExportFails() async throws {
        let root = try makeRepo()
        try Fixtures.makeProject(in: root, project: "Example.xcodeproj")
        let server = try DryRunServer(snapshot: try Fixtures.standard(), desired: root.appending(path: "XcodeCloud"))
        let todo = try await setupTodo(root, ["--yes", "--products", "com.other.app"], client: AppStoreConnectClient(dryRun: server))
        #expect(files(in: root).contains(".github/workflows/xcflow-apply.yml"))
        #expect(todo.contains { $0.contains("xcflow export com.other.app") })
    }
}
