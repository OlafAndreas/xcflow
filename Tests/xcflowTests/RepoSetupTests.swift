import Foundation
import Testing
@testable import xcflow

struct RepoSetupTests {
    private let sha = String(repeating: "a", count: 40)

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

    /// Stands in for `gh secret`; records what setup would have set.
    final class FakeSecrets: SecretStore, @unchecked Sendable {
        var existing: Set<String>
        var set: [String: String] = [:]

        init(existing: Set<String> = []) {
            self.existing = existing
        }

        func names(in root: URL) throws -> Set<String> { existing }

        func set(_ name: String, to value: String, in root: URL) throws {
            set[name] = value
            existing.insert(name)
        }
    }

    /// A stand-in .p8, outside the repo so the repo's file list stays meaningful.
    private func writeKey() throws -> (path: String, base64: String) {
        let pem = "-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49\n-----END PRIVATE KEY-----\n"
        let url = FileManager.default.temporaryDirectory.appending(path: "xcflow-key-\(UUID().uuidString).p8")
        try pem.write(to: url, atomically: true, encoding: .utf8)
        return (url.path(percentEncoded: false), Data(pem.utf8).base64EncodedString())
    }

    /// Runs setup with the secrets step live against `secrets`, never interactive, so no test can block on a prompt.
    @discardableResult
    private func setupSecrets(_ root: URL, _ extra: [String], secrets: FakeSecrets, keys: FakeKeys = FakeKeys()) async throws -> [String] {
        try await RepoSetup.run(
            arguments: ["--repo", root.path(percentEncoded: false), "--products", "com.example.app", "--skip-export", "--action-sha", sha] + extra,
            secrets: secrets,
            keys: keys,
            interactive: false,
            environment: [:]
        )
    }

    private func setup(_ root: URL, _ extra: [String] = []) async throws {
        try await RepoSetup.run(arguments: ["--repo", root.path(percentEncoded: false), "--products", "com.example.app", "--skip-export", "--skip-secrets", "--action-sha", sha] + extra, keys: FakeKeys(), interactive: false, environment: [:])
    }

    private func setupError(_ root: URL, _ extra: [String]) async -> String {
        do {
            try await setup(root, extra)
            return "no error"
        } catch {
            return error.localizedDescription
        }
    }

    @Test func dryRunWritesNothing() async throws {
        let root = try makeRepo()
        try await setup(root, ["--dry-run"])
        #expect(files(in: root).isEmpty)
    }

    /// Rewrites the `uses:` line of all three workflows.
    private func repin(_ root: URL, to uses: String) throws {
        for name in ["plan", "apply", "sync"] {
            let url = root.appending(path: ".github/workflows/xcflow-\(name).yml")
            let text = try String(contentsOf: url, encoding: .utf8)
            try text.replacing(/uses: OlafAndreas\/xcflow-action@.*/, with: "uses: \(uses)").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func plan(_ root: URL) throws -> String {
        try String(contentsOf: root.appending(path: ".github/workflows/xcflow-plan.yml"), encoding: .utf8)
    }

    @Test func aNewerPinIsKeptEvenWithYes() async throws {
        let root = try makeRepo()
        try await setup(root)
        let newer = "OlafAndreas/xcflow-action@\(String(repeating: "b", count: 40)) # v99.0.0"
        try repin(root, to: newer)
        try await setup(root, ["--yes"])
        for name in ["plan", "apply", "sync"] {
            #expect(try String(contentsOf: root.appending(path: ".github/workflows/xcflow-\(name).yml"), encoding: .utf8).contains("uses: \(newer)\n"))
        }
    }

    @Test func anOlderPinIsUpdated() async throws {
        let root = try makeRepo()
        try await setup(root)
        try repin(root, to: "OlafAndreas/xcflow-action@\(String(repeating: "b", count: 40)) # v0.0.1")
        try await setup(root, ["--yes"])
        #expect(try plan(root).contains("@\(sha) # v\(Version.current)"))
    }

    @Test func forceWritesTheCurrentPinOverANewerOne() async throws {
        let root = try makeRepo()
        try await setup(root)
        try repin(root, to: "OlafAndreas/xcflow-action@\(String(repeating: "b", count: 40)) # v99.0.0")
        try await setup(root, ["--force"])
        #expect(try plan(root).contains("@\(sha) # v\(Version.current)"))
    }

    @Test func aForeignInstallStepIsADifference() async throws {
        let root = try makeRepo()
        try await setup(root)
        try repin(root, to: "someone/other-action@v1")
        try await setup(root)
        #expect(try plan(root).contains("uses: someone/other-action@v1\n"))
        try await setup(root, ["--yes"])
        #expect(try plan(root).contains("@\(sha) # v\(Version.current)"))
    }

    @Test func workflowsInstallFromThePinnedAction() async throws {
        let root = try makeRepo()
        try await setup(root)
        for name in ["plan", "apply", "sync"] {
            let text = try String(contentsOf: root.appending(path: ".github/workflows/xcflow-\(name).yml"), encoding: .utf8)
            #expect(text.contains("uses: OlafAndreas/xcflow-action@\(sha) # v\(Version.current)"))
            #expect(!text.contains(".github/actions/xcflow"))
        }
    }

    @Test func dryRunResolvesTheActionCommit() async throws {
        let root = try makeRepo()
        let todo = try await RepoSetup.run(
            arguments: ["--repo", root.path(percentEncoded: false), "--products", "com.example.app", "--skip-export", "--skip-secrets", "--dry-run"],
            resolveActionCommit: { version in version == Version.current ? sha : nil }, keys: FakeKeys(), interactive: false, environment: [:])
        #expect(!todo.contains { $0.contains("Pin `OlafAndreas/xcflow-action`") })
        #expect(files(in: root).isEmpty)
    }

    @Test func withoutAResolvableCommitTheWorkflowsUseTheTag() async throws {
        let root = try makeRepo()
        let todo = try await RepoSetup.run(
            arguments: ["--repo", root.path(percentEncoded: false), "--products", "com.example.app", "--skip-export", "--skip-secrets"],
            resolveActionCommit: { _ in nil }, keys: FakeKeys(), interactive: false, environment: [:])
        let text = try String(contentsOf: root.appending(path: ".github/workflows/xcflow-plan.yml"), encoding: .utf8)
        #expect(text.contains("uses: OlafAndreas/xcflow-action@v\(Version.current)\n"))
        #expect(todo.contains { $0.hasPrefix("Pin `OlafAndreas/xcflow-action` to its commit for v\(Version.current)") })
    }

    @Test func aMalformedActionShaIsRefusedBeforeWriting() async throws {
        let root = try makeRepo()
        let message = await setupError(root, ["--action-sha", "v0.2.8"])
        #expect(message.contains("--action-sha"))
        #expect(files(in: root).isEmpty)
    }

    @Test func thePlanJobSkipsDependabotPullRequests() {
        let plan = Templates.files(action: ActionPin(version: "1.2.3", commit: nil)).first { $0.path == ".github/workflows/xcflow-plan.yml" }?.content ?? ""
        #expect(plan.contains("if: github.event.pull_request.draft == false && github.actor != 'dependabot[bot]'"))
    }

    @Test func thePlanWorkflowTriggersOnBothPaths() {
        let plan = Templates.files(action: ActionPin(version: "1.2.3", commit: nil)).first { $0.path == ".github/workflows/xcflow-plan.yml" }?.content ?? ""
        #expect(plan.contains("    paths:\n      - 'XcodeCloud/**'\n      - '.github/workflows/xcflow-*.yml'\n"))
    }

    @Test func generatedFilesNoLongerMentionTheLocalAction() {
        #expect(Templates.files(action: ActionPin(version: "1.2.3", commit: nil)).allSatisfy { !$0.content.contains(".github/actions/xcflow") })
    }

    @Test func setupWritesEveryFileAndIsIdempotent() async throws {
        let root = try makeRepo(mcp: #"{"mcpServers":{"other":{"type":"stdio","command":"other"}}}"#)
        try await setup(root, ["--claude"])
        #expect(files(in: root) == [
            ".claude/rules/xcode-cloud.md",
            ".claude/skills/edit-xcode-cloud-workflow/SKILL.md",
            ".github/dependabot.yml",
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
        for file in Templates.files(action: ActionPin(version: Version.current, commit: sha)) {
            #expect(try RepoSetup.write(file, in: root, force: false, dryRun: false, prompt: prompt) == .unchanged)
        }
        #expect(try RepoSetup.mergeMCPEntry(in: root, dryRun: false) == .unchanged)
        #expect(try RepoSetup.mergeDependabot(in: root, dryRun: false) == .unchanged)
    }

    @Test func dependabotConfigIsCreated() async throws {
        let root = try makeRepo()
        let todo = try await setupTodo(root, ["--products", "com.example.app", "--skip-export"])
        #expect(try String(contentsOf: root.appending(path: ".github/dependabot.yml"), encoding: .utf8) == Templates.dependabot)
        #expect(!todo.contains { $0.contains("dependabot.yml") })
    }

    @Test func anExistingGithubActionsEntryIsLeftAlone() async throws {
        for quoted in ["github-actions", "\"github-actions\"", "'github-actions'"] {
            let root = try makeRepo()
            let existing = "version: 2\nupdates:\n  - package-ecosystem: \(quoted)\n    directory: \"/\"\n    schedule:\n      interval: daily\n"
            try FileManager.default.createDirectory(at: root.appending(path: ".github"), withIntermediateDirectories: true)
            try existing.write(to: root.appending(path: ".github/dependabot.yml"), atomically: true, encoding: .utf8)
            let todo = try await setupTodo(root, ["--products", "com.example.app", "--skip-export"])
            #expect(try String(contentsOf: root.appending(path: ".github/dependabot.yml"), encoding: .utf8) == existing)
            #expect(!todo.contains { $0.contains("dependabot.yml") })
        }
    }

    @Test func anUnreadableDependabotConfigIsKeptAndGetsATodo() async throws {
        let root = try makeRepo()
        let existing = Data([0xFF, 0xFE, 0x00])
        try FileManager.default.createDirectory(at: root.appending(path: ".github"), withIntermediateDirectories: true)
        try existing.write(to: root.appending(path: ".github/dependabot.yml"))
        let todo = try await setupTodo(root, ["--products", "com.example.app", "--skip-export"])
        #expect(try Data(contentsOf: root.appending(path: ".github/dependabot.yml")) == existing)
        #expect(todo.contains { $0.hasPrefix("Add an entry to `.github/dependabot.yml`") })
    }

    @Test func aDependabotConfigWithoutGithubActionsGetsATodo() async throws {
        let root = try makeRepo()
        let existing = "version: 2\nupdates:\n  - package-ecosystem: npm\n    directory: /\n    schedule:\n      interval: weekly\n"
        try FileManager.default.createDirectory(at: root.appending(path: ".github"), withIntermediateDirectories: true)
        try existing.write(to: root.appending(path: ".github/dependabot.yml"), atomically: true, encoding: .utf8)
        let todo = try await setupTodo(root, ["--products", "com.example.app", "--skip-export"])
        #expect(try String(contentsOf: root.appending(path: ".github/dependabot.yml"), encoding: .utf8) == existing)
        #expect(todo.contains { $0.hasPrefix("Add an entry to `.github/dependabot.yml`") })
    }

    @Test func changedFilesAreKeptUnlessForced() async throws {
        let root = try makeRepo()
        try await setup(root, ["--claude"])
        let rule = root.appending(path: ".claude/rules/xcode-cloud.md")
        try "custom".write(to: rule, atomically: true, encoding: .utf8)

        try await setup(root, ["--claude"])
        #expect(try String(contentsOf: rule, encoding: .utf8) == "custom")

        try await setup(root, ["--claude", "--force"])
        #expect(try String(contentsOf: rule, encoding: .utf8) != "custom")
    }

    @Test func generatedActionsPinTheCurrentCheckout() {
        let generated = Templates.files(action: ActionPin(version: "1.2.3", commit: sha)).filter { $0.path.hasPrefix(".github/") }
        let pins = generated.flatMap { $0.content.matches(of: /actions\/checkout@v\d+/).map { String($0.output) } }
        #expect(pins.count == 3)
        #expect(pins.allSatisfy { $0 == "actions/checkout@v7" })
    }

    @Test func workflowsRunOnLinux() {
        let workflows = Templates.files(action: ActionPin(version: "1.2.3", commit: sha)).filter { $0.path.hasPrefix(".github/workflows/") }
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

    private func setupTodo(_ root: URL, _ extra: [String], client: AppStoreConnectClient? = nil, keys: FakeKeys = FakeKeys()) async throws -> [String] {
        try await RepoSetup.run(arguments: ["--repo", root.path(percentEncoded: false), "--skip-secrets", "--action-sha", sha] + extra, client: client, keys: keys, interactive: false, environment: [:])
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

    @Test func setupSetsTheSecretsFromTheKeyFlags() async throws {
        let root = try makeRepo()
        let key = try writeKey()
        let secrets = FakeSecrets()
        let todo = try await setupSecrets(root, ["--key-id", "ABC123", "--issuer-id", "11111111-2222-3333-4444-555555555555", "--p8", key.path], secrets: secrets)
        #expect(secrets.set == ["ASC_KEY_ID": "ABC123", "ASC_ISSUER_ID": "11111111-2222-3333-4444-555555555555", "ASC_KEY_CONTENT": key.base64])
        #expect(!todo.contains { $0.contains("secrets") })
    }

    @Test func setupLeavesExistingSecretsAloneUnlessReplacing() async throws {
        let root = try makeRepo()
        let key = try writeKey()
        let flags = ["--key-id", "ABC123", "--issuer-id", "issuer", "--p8", key.path]

        let kept = FakeSecrets(existing: Set(RepoSetup.secretNames))
        try await setupSecrets(root, flags, secrets: kept)
        #expect(kept.set.isEmpty)

        let replaced = FakeSecrets(existing: Set(RepoSetup.secretNames))
        try await setupSecrets(root, flags + ["--replace-secrets"], secrets: replaced)
        #expect(replaced.set.keys.sorted() == RepoSetup.secretNames.sorted())
    }

    @Test func setupWithoutATerminalNeedsAllThreeKeyFlags() async throws {
        let root = try makeRepo()
        let secrets = FakeSecrets()
        let message = await setupSecretsError(root, ["--yes", "--key-id", "ABC123"], secrets: secrets)
        #expect(message.contains("--issuer-id"))
        #expect(message.contains("--p8"))
        #expect(secrets.set.isEmpty)
    }

    @Test func setupWithoutAKeyLeavesASecretsTodoNamingTheFlags() async throws {
        let root = try makeRepo()
        let secrets = FakeSecrets()
        let todo = try await setupSecrets(root, [], secrets: secrets)
        #expect(todo.contains { $0.contains("--key-id") && $0.contains("--issuer-id") && $0.contains("--p8") })
        #expect(secrets.set.isEmpty)
    }

    @Test func setupRefusesAnUnreadableKeyFileBeforeWritingAnything() async throws {
        let root = try makeRepo()
        let secrets = FakeSecrets()
        let message = await setupSecretsError(root, ["--key-id", "ABC123", "--issuer-id", "issuer", "--p8", root.appending(path: "missing.p8").path(percentEncoded: false)], secrets: secrets)
        #expect(message.contains("missing.p8"))
        #expect(files(in: root).isEmpty)
        #expect(secrets.set.isEmpty)
    }

    @Test func dryRunSetsNoSecretsEvenWithTheKeyFlags() async throws {
        let root = try makeRepo()
        let key = try writeKey()
        let secrets = FakeSecrets()
        let keys = FakeKeys()
        try await setupSecrets(root, ["--dry-run", "--key-id", "ABC123", "--issuer-id", "issuer", "--p8", key.path], secrets: secrets, keys: keys)
        #expect(secrets.set.isEmpty)
        #expect(keys.stored == nil)
        #expect(files(in: root).isEmpty)
    }

    private func setupSecretsError(_ root: URL, _ extra: [String], secrets: FakeSecrets, keys: FakeKeys = FakeKeys()) async -> String {
        do {
            try await setupSecrets(root, extra, secrets: secrets, keys: keys)
            return "no error"
        } catch {
            return error.localizedDescription
        }
    }

    private func writeLegacyAction(in root: URL, edited: Bool = false) throws {
        let url = root.appending(path: LegacyAction.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = LegacyAction.render(version: "0.2.6", checksums: ["xcflow-0.2.6-linux-x86_64.tar.gz": String(repeating: "1", count: 64), "xcflow-0.2.6-linux-aarch64.tar.gz": String(repeating: "2", count: 64)])
        try (edited ? content + "# edited\n" : content).write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func setupRemovesAnUntouchedLegacyAction() async throws {
        let root = try makeRepo()
        try writeLegacyAction(in: root)
        let todo = try await setupTodo(root, ["--products", "com.example.app", "--skip-export"])
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".github/actions").path(percentEncoded: false)))
        #expect(!todo.contains { $0.contains(".github/actions/xcflow") })
    }

    @Test func setupKeepsAnEditedLegacyActionWithATodo() async throws {
        let root = try makeRepo()
        try writeLegacyAction(in: root, edited: true)
        let todo = try await setupTodo(root, ["--products", "com.example.app", "--skip-export"])
        #expect(FileManager.default.fileExists(atPath: root.appending(path: LegacyAction.path).path(percentEncoded: false)))
        #expect(todo.contains { $0.hasPrefix("Remove `.github/actions/xcflow/`") })
    }

    @Test func forceRemovesAnEditedLegacyAction() async throws {
        let root = try makeRepo()
        try writeLegacyAction(in: root, edited: true)
        _ = try await setupTodo(root, ["--products", "com.example.app", "--skip-export", "--force"])
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: LegacyAction.path).path(percentEncoded: false)))
    }

    @Test func dryRunLeavesTheLegacyAction() async throws {
        let root = try makeRepo()
        try writeLegacyAction(in: root)
        _ = try await setupTodo(root, ["--products", "com.example.app", "--skip-export", "--dry-run"])
        #expect(FileManager.default.fileExists(atPath: root.appending(path: LegacyAction.path).path(percentEncoded: false)))
    }

    /// A workflow as an older xcflow wrote it: installing xcflow from the local action.
    private func writeLocalActionWorkflow(in root: URL, at path: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = "name: Old\non: push\njobs:\n  run:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: ./.github/actions/xcflow\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeOldRepo(in root: URL) throws {
        try writeLegacyAction(in: root)
        for name in ["plan", "apply", "sync"] {
            try writeLocalActionWorkflow(in: root, at: ".github/workflows/xcflow-\(name).yml")
        }
    }

    private func legacyActionExists(in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: LegacyAction.path).path(percentEncoded: false))
    }

    @Test func theLegacyActionIsKeptWhileKeptWorkflowsStillUseIt() async throws {
        let root = try makeRepo()
        try writeOldRepo(in: root)
        let todo = try await setupTodo(root, ["--products", "com.example.app", "--skip-export"])
        #expect(legacyActionExists(in: root))
        #expect(todo.contains { $0.contains("then remove `.github/actions/xcflow/`") && $0.contains(".github/workflows/xcflow-plan.yml") })
    }

    @Test func theLegacyActionIsRemovedOnceTheWorkflowsAreRewritten() async throws {
        let root = try makeRepo()
        try writeOldRepo(in: root)
        let todo = try await setupTodo(root, ["--products", "com.example.app", "--skip-export", "--yes"])
        #expect(!legacyActionExists(in: root))
        for name in ["plan", "apply", "sync"] {
            #expect(try String(contentsOf: root.appending(path: ".github/workflows/xcflow-\(name).yml"), encoding: .utf8).contains("uses: OlafAndreas/xcflow-action@"))
        }
        #expect(!todo.contains { $0.contains("then remove `.github/actions/xcflow/`") })
    }

    @Test func aDryRunWithYesReportsTheLegacyActionAsRemoved() async throws {
        let root = try makeRepo()
        try writeOldRepo(in: root)
        let todo = try await setupTodo(root, ["--products", "com.example.app", "--skip-export", "--dry-run", "--yes"])
        #expect(legacyActionExists(in: root))
        #expect(!todo.contains { $0.contains("then remove `.github/actions/xcflow/`") })
    }

    @Test func anotherWorkflowUsingTheLegacyActionKeepsItUnlessForced() async throws {
        let root = try makeRepo()
        try await setup(root)
        try writeLegacyAction(in: root)
        try writeLocalActionWorkflow(in: root, at: ".github/workflows/other.yml")
        let kept = try await setupTodo(root, ["--products", "com.example.app", "--skip-export"])
        #expect(legacyActionExists(in: root))
        #expect(kept.contains { $0.contains("then remove `.github/actions/xcflow/`") && $0.contains(".github/workflows/other.yml") && !$0.contains("xcflow-plan.yml") })

        let forced = try await setupTodo(root, ["--products", "com.example.app", "--skip-export", "--force"])
        #expect(!legacyActionExists(in: root))
        #expect(forced.contains { $0.contains("then remove `.github/actions/xcflow/`") && $0.contains(".github/workflows/other.yml") })
    }

    @Test func aTagPinKeepsItsTodoOnceTheTagResolves() async throws {
        let root = try makeRepo()
        try await RepoSetup.run(
            arguments: ["--repo", root.path(percentEncoded: false), "--products", "com.example.app", "--skip-export", "--skip-secrets"],
            resolveActionCommit: { _ in nil }, keys: FakeKeys(), interactive: false, environment: [:])
        let todo = try await setupTodo(root, ["--products", "com.example.app", "--skip-export"])
        #expect(try plan(root).contains("uses: OlafAndreas/xcflow-action@v\(Version.current)\n"))
        #expect(todo.contains { $0.hasPrefix("Pin `OlafAndreas/xcflow-action`") && $0.contains(".github/workflows/xcflow-plan.yml") && $0.contains("still reference the tag") })
        #expect(!todo.contains { $0.contains("the lookup failed") })
    }

    @Test func anExistingDependabotYamlIsUsedInsteadOfCreatingYml() async throws {
        for (existing, todoExpected) in [
            ("version: 2\nupdates:\n  - package-ecosystem: github-actions\n    directory: /\n    schedule:\n      interval: weekly\n", false),
            ("version: 2\nupdates:\n  - package-ecosystem: npm\n    directory: /\n    schedule:\n      interval: weekly\n", true)
        ] {
            let root = try makeRepo()
            try FileManager.default.createDirectory(at: root.appending(path: ".github"), withIntermediateDirectories: true)
            try existing.write(to: root.appending(path: ".github/dependabot.yaml"), atomically: true, encoding: .utf8)
            let todo = try await setupTodo(root, ["--products", "com.example.app", "--skip-export"])
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".github/dependabot.yml").path(percentEncoded: false)))
            #expect(try String(contentsOf: root.appending(path: ".github/dependabot.yaml"), encoding: .utf8) == existing)
            #expect(todo.contains { $0.hasPrefix("Add an entry to `.github/dependabot.yaml`") } == todoExpected)
        }
    }

    // MARK: - One key for everything

    private let teamPEM = "-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49\n-----END PRIVATE KEY-----\n"

    @Test func setupStoresTheKeyFromTheFlagsAndUsesItForTheExportAndTheSecrets() async throws {
        let root = try makeRepo()
        try Fixtures.writeManifest(in: root, project: "Example.xcodeproj", productIDs: ["<ciProducts: com.example.app>"])
        let server = try DryRunServer(snapshot: try Fixtures.standard(), desired: root.appending(path: "XcodeCloud"))
        let key = try writeKey()
        let keys = FakeKeys()
        let secrets = FakeSecrets()
        let todo = try await RepoSetup.run(
            arguments: ["--repo", root.path(percentEncoded: false), "--yes", "--action-sha", sha, "--key-id", "ABC123", "--issuer-id", "issuer-1", "--p8", key.path],
            client: AppStoreConnectClient(dryRun: server), secrets: secrets, keys: keys, interactive: false, environment: [:])
        #expect(keys.stored?.keyID == "ABC123")
        #expect(keys.stored?.issuerID == "issuer-1")
        #expect(secrets.set["ASC_KEY_ID"] == "ABC123")
        #expect(secrets.set["ASC_KEY_CONTENT"] == key.base64)
        #expect(files(in: root).contains("XcodeCloud/com.example.app/nightly-tests.json"))
        #expect(todo.last?.contains("commit") == true)
    }

    @Test func setupWithoutAnyKeySkipsTheExportAndSaysWhatToPass() async throws {
        let root = try makeRepo()
        try Fixtures.writeManifest(in: root, project: "Example.xcodeproj", productIDs: ["<ciProducts: com.example.app>"])
        let todo = try await setupTodo(root, [])
        #expect(files(in: root).contains(".github/workflows/xcflow-plan.yml"))
        #expect(!files(in: root).contains { $0.hasPrefix("XcodeCloud/com.example.app/") })
        #expect(todo.contains { $0.contains("--key-id") && $0.contains("xcflow export") })
    }

    @Test func setupUsesAStoredTeamKeyForTheSecretsWhenAsked() async throws {
        let root = try makeRepo()
        let keys = FakeKeys(Credentials(keyID: "TEAM1", privateKeyPEM: teamPEM, issuerID: "issuer-1"))
        let secrets = FakeSecrets()
        try await setupSecrets(root, ["--yes"], secrets: secrets, keys: keys)
        #expect(secrets.set == ["ASC_KEY_ID": "TEAM1", "ASC_ISSUER_ID": "issuer-1", "ASC_KEY_CONTENT": Data(teamPEM.utf8).base64EncodedString()])
    }

    @Test func setupWithAStoredPersonalKeyStillNeedsATeamKeyForTheSecrets() async throws {
        let root = try makeRepo()
        let keys = FakeKeys(Credentials(keyID: "ME", privateKeyPEM: teamPEM))
        let secrets = FakeSecrets()
        let message = await setupSecretsError(root, ["--yes"], secrets: secrets, keys: keys)
        #expect(message.contains("--issuer-id"))
        #expect(secrets.set.isEmpty)
    }

    @Test func setupEndsWithTheCommitStepExceptInADryRun() async throws {
        let root = try makeRepo()
        let real = try await setupTodo(root, ["--products", "com.example.app", "--skip-export"])
        #expect(real.last?.contains("commit") == true && real.last?.contains("pull request") == true)
        let dry = try await setupTodo(root, ["--products", "com.example.app", "--skip-export", "--dry-run"])
        #expect(!dry.contains { $0.contains("commit") })
    }

    @Test func theClaudeFilesAndTheMCPEntryAreOptIn() async throws {
        let plain = try makeRepo()
        try await setup(plain)
        #expect(!files(in: plain).contains { $0.hasPrefix(".claude/") || $0 == ".mcp.json" })

        let existing = #"{"mcpServers":{"other":{"type":"stdio","command":"other"}}}"#
        let withOther = try makeRepo(mcp: existing)
        try await setup(withOther)
        #expect(try String(contentsOf: withOther.appending(path: ".mcp.json"), encoding: .utf8) == existing)

        try await setup(withOther, ["--claude"])
        #expect(files(in: withOther).contains(".claude/skills/edit-xcode-cloud-workflow/SKILL.md"))
        #expect(files(in: withOther).contains(".claude/rules/xcode-cloud.md"))
        let servers = (try JSONSerialization.jsonObject(with: Data(contentsOf: withOther.appending(path: ".mcp.json"))) as? JSON)?["mcpServers"] as? JSON
        #expect(servers?.keys.sorted() == ["other", "xcflow"])
    }

    // MARK: - The repo's key pin

    private let otherPEM = "-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM50\n-----END PRIVATE KEY-----\n"

    /// Records which key setup connected to App Store Connect with, and hands back the dry-run server.
    final class Connections: @unchecked Sendable {
        var used: [String] = []
    }

    /// Setup with a manifest to export from, the export going through `connect` so the key it used is recorded.
    private func setupPinning(
        _ root: URL,
        _ extra: [String],
        keys: FakeKeys,
        environment: [String: String] = [:],
        interactive: Bool = false,
        answers: [String] = [],
        secrets: FakeSecrets? = nil
    ) async throws -> (todo: [String], connected: [String]) {
        if !FileManager.default.fileExists(atPath: root.appending(path: "Example.xcodeproj").path(percentEncoded: false)) {
            try Fixtures.writeManifest(in: root, project: "Example.xcodeproj", productIDs: ["<ciProducts: com.example.app>"])
        }
        let server = try DryRunServer(snapshot: try Fixtures.standard(), desired: root.appending(path: "XcodeCloud"))
        let connections = Connections()
        var remaining = answers[...]
        let todo = try await RepoSetup.run(
            arguments: ["--repo", root.path(percentEncoded: false), "--yes", "--action-sha", sha] + (secrets == nil ? ["--skip-secrets"] : []) + extra,
            secrets: secrets ?? FakeSecrets(),
            keys: keys,
            interactive: interactive,
            environment: environment,
            connect: { credentials in
                connections.used.append(credentials.keyID)
                return AppStoreConnectClient(dryRun: server)
            },
            input: { remaining.popFirst() }
        )
        return (todo, connections.used)
    }

    private func pin(in root: URL) throws -> String? {
        try RepoKeyFile.read(root.appending(path: "XcodeCloud/xcflow.json"))
    }

    @Test func anEnvironmentKeyIsUsedForTheExportAndNotPinned() async throws {
        let root = try makeRepo()
        let keys = FakeKeys()
        let environment = ["ASC_KEY_ID": "ENV1", "ASC_KEY_CONTENT": teamPEM, "ASC_ISSUER_ID": "issuer-env"]
        let result = try await setupPinning(root, [], keys: keys, environment: environment)
        #expect(result.connected == ["ENV1"])
        #expect(files(in: root).contains("XcodeCloud/com.example.app/nightly-tests.json"))
        #expect(!files(in: root).contains("XcodeCloud/xcflow.json"))
        #expect(keys.stored == nil)
        #expect(!result.todo.contains { $0.contains("xcflow.json") })
    }

    @Test func theEnvironmentKeyWinsOverASingleStoredKey() async throws {
        let root = try makeRepo()
        let keys = FakeKeys(Credentials(keyID: "TEAM1", privateKeyPEM: teamPEM, issuerID: "issuer-1"))
        let result = try await setupPinning(root, [], keys: keys, environment: ["ASC_KEY_ID": "ENV1", "ASC_KEY_CONTENT": teamPEM])
        #expect(result.connected == ["ENV1"])
        #expect(try pin(in: root) == nil)
    }

    @Test func theOnlyStoredKeyIsUsedAndPinnedAndASecondRunLeavesThePin() async throws {
        let root = try makeRepo()
        let keys = FakeKeys(Credentials(keyID: "TEAM1", privateKeyPEM: teamPEM, issuerID: "issuer-1"))
        let first = try await setupPinning(root, [], keys: keys)
        #expect(first.connected == ["TEAM1"])
        #expect(try String(contentsOf: root.appending(path: "XcodeCloud/xcflow.json"), encoding: .utf8) == "{\n  \"keyID\" : \"TEAM1\"\n}\n")
        let second = try await setupPinning(root, [], keys: keys)
        #expect(try pin(in: root) == "TEAM1")
        #expect(!second.todo.contains { $0.contains("xcflow.json") })
    }

    @Test func anIndividualKeyIsPinnedToo() async throws {
        let root = try makeRepo()
        let keys = FakeKeys(Credentials(keyID: "ME", privateKeyPEM: teamPEM))
        _ = try await setupPinning(root, [], keys: keys)
        #expect(try pin(in: root) == "ME")
    }

    @Test func theKeyFromTheFlagsIsStoredAndPinned() async throws {
        let root = try makeRepo()
        let key = try writeKey()
        let keys = FakeKeys(Credentials(keyID: "OLD", privateKeyPEM: otherPEM, issuerID: "issuer-old"))
        let result = try await setupPinning(root, ["--key-id", "NEW1", "--issuer-id", "issuer-1", "--p8", key.path], keys: keys)
        #expect(result.connected == ["NEW1"])
        #expect(try keys.keys().map(\.keyID) == ["NEW1", "OLD"])
        #expect(try pin(in: root) == "NEW1")
    }

    @Test func aDryRunPinsNothing() async throws {
        let root = try makeRepo()
        let keys = FakeKeys(Credentials(keyID: "TEAM1", privateKeyPEM: teamPEM, issuerID: "issuer-1"))
        _ = try await setupPinning(root, ["--dry-run"], keys: keys)
        #expect(files(in: root).allSatisfy { $0 != "XcodeCloud/xcflow.json" })
    }

    @Test func aDifferentPinIsKeptWithATodoUnlessForced() async throws {
        let root = try makeRepo()
        try RepoKeyFile.write("OTHER", to: root.appending(path: "XcodeCloud/xcflow.json"))
        let key = try writeKey()
        let flags = ["--key-id", "NEW1", "--issuer-id", "issuer-1", "--p8", key.path]
        let kept = try await setupPinning(root, flags, keys: FakeKeys())
        #expect(try pin(in: root) == "OTHER")
        #expect(kept.todo.contains { $0.contains("XcodeCloud/xcflow.json") && $0.contains("OTHER") && $0.contains("NEW1") && $0.contains("--force") })

        let forced = try await setupPinning(root, flags + ["--force"], keys: FakeKeys())
        #expect(try pin(in: root) == "NEW1")
        #expect(!forced.todo.contains { $0.contains("xcflow.json") })
    }

    @Test func thePinPicksAmongSeveralStoredKeys() async throws {
        let root = try makeRepo()
        try RepoKeyFile.write("B", to: root.appending(path: "XcodeCloud/xcflow.json"))
        let keys = FakeKeys(Credentials(keyID: "A", privateKeyPEM: teamPEM, issuerID: "i"), Credentials(keyID: "B", privateKeyPEM: otherPEM, issuerID: "j"))
        let result = try await setupPinning(root, [], keys: keys)
        #expect(result.connected == ["B"])
        #expect(try pin(in: root) == "B")
    }

    @Test func severalKeysWithoutATerminalLeaveTheExportAndSecretsAsTodos() async throws {
        let root = try makeRepo()
        let keys = FakeKeys(Credentials(keyID: "A", privateKeyPEM: teamPEM, issuerID: "i"), Credentials(keyID: "B", privateKeyPEM: otherPEM))
        let secrets = FakeSecrets()
        let result = try await setupPinning(root, [], keys: keys, secrets: secrets)
        #expect(result.connected.isEmpty)
        #expect(try pin(in: root) == nil)
        #expect(secrets.set.isEmpty)
        #expect(result.todo.contains { $0.contains("xcflow keys use <key id>") && $0.contains("xcflow export") })
        #expect(result.todo.contains { $0.contains("xcflow keys use <key id>") && $0.contains("ASC_KEY_ID") })
    }

    @Test func severalKeysWithoutATerminalUseTheKeyIdFlagWhenItNamesOne() async throws {
        let root = try makeRepo()
        let keys = FakeKeys(Credentials(keyID: "A", privateKeyPEM: teamPEM, issuerID: "i"), Credentials(keyID: "B", privateKeyPEM: otherPEM, issuerID: "j"))
        let secrets = FakeSecrets()
        let result = try await setupPinning(root, ["--key-id", "B"], keys: keys, secrets: secrets)
        #expect(result.connected == ["B"])
        #expect(try pin(in: root) == "B")
        #expect(secrets.set["ASC_KEY_ID"] == "B")
        #expect(!result.todo.contains { $0.contains("xcflow keys use") })
    }

    @Test func severalKeysInATerminalAskWhichOne() async throws {
        let root = try makeRepo()
        let keys = FakeKeys(Credentials(keyID: "A", privateKeyPEM: teamPEM, issuerID: "i"), Credentials(keyID: "B", privateKeyPEM: otherPEM))
        let result = try await setupPinning(root, [], keys: keys, interactive: true, answers: ["2"])
        #expect(result.connected == ["B"])
        #expect(try pin(in: root) == "B")
    }

    @Test func severalKeysInATerminalCanTakeANewOne() async throws {
        let root = try makeRepo()
        let key = try writeKey()
        let keys = FakeKeys(Credentials(keyID: "A", privateKeyPEM: teamPEM, issuerID: "i"), Credentials(keyID: "B", privateKeyPEM: otherPEM))
        let result = try await setupPinning(root, [], keys: keys, interactive: true, answers: ["3", "NEW1", "issuer-1", key.path])
        #expect(result.connected == ["NEW1"])
        #expect(try keys.keys().map(\.keyID) == ["A", "B", "NEW1"])
        #expect(try pin(in: root) == "NEW1")
    }

    @Test func aPinNamingAnUnstoredKeySaysHowToStoreIt() async throws {
        let root = try makeRepo()
        try RepoKeyFile.write("GONE", to: root.appending(path: "XcodeCloud/xcflow.json"))
        let keys = FakeKeys(Credentials(keyID: "A", privateKeyPEM: teamPEM, issuerID: "i"))
        let result = try await setupPinning(root, [], keys: keys)
        #expect(result.connected.isEmpty)
        #expect(result.todo.contains { $0.contains("xcflow auth --key-id GONE") })
        #expect(try pin(in: root) == "GONE")
    }

    @Test func pinningReportsCreatedUnchangedAndKept() throws {
        let root = try makeRepo()
        let url = root.appending(path: "XcodeCloud/xcflow.json")
        #expect(try RepoSetup.pinKey("A", at: url, force: false, dryRun: true) == .created)
        #expect(try RepoKeyFile.read(url) == nil)
        #expect(try RepoSetup.pinKey("A", at: url, force: false, dryRun: false) == .created)
        #expect(try RepoSetup.pinKey("A", at: url, force: false, dryRun: false) == .unchanged)
        #expect(try RepoSetup.pinKey("B", at: url, force: false, dryRun: false) == .keptDifferent)
        #expect(try RepoKeyFile.read(url) == "A")
        #expect(try RepoSetup.pinKey("B", at: url, force: true, dryRun: false) == .overwritten)
        #expect(try RepoKeyFile.read(url) == "B")
    }
}
