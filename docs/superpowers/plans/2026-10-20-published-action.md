# Published Install Action Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `xcflow setup` installs xcflow in the generated workflows from the published action `OlafAndreas/xcflow-action`, pinned by commit and bumped by Dependabot, and every xcflow release publishes that action.

**Architecture:** A new `ActionPin` value renders and parses the `uses:` line; `Templates` takes a pin instead of version and checksums; `RepoSetup` resolves the pin with `git ls-remote`, keeps a newer pin Dependabot wrote, writes `.github/dependabot.yml`, and removes an untouched legacy local action recognised by `LegacyAction`. The action's own template leaves Swift for `Action/action.yml`, which the release workflow renders and pushes before the Homebrew formula.

**Tech Stack:** Swift 6 package, swift-testing (`@Test`, `#expect`), Foundation `Process` for `git`, GitHub Actions YAML and bash. No new dependencies, no YAML parser.

**Spec:** `docs/superpowers/specs/2026-10-20-published-action-design.md`

## Global Constraints

- Action repository: `OlafAndreas/xcflow-action`. Commit pin renders as `OlafAndreas/xcflow-action@<40 hex sha> # vX.Y.Z`; tag fallback renders as `OlafAndreas/xcflow-action@vX.Y.Z`.
- The action stays Linux-only. Generated workflows keep `runs-on: ubuntu-latest` and `actions/checkout@v7`.
- No local action is written any more. `.github/actions/xcflow/**` leaves every generated `paths:` list. `--checksums` goes away; `--action-sha <sha>` arrives.
- The plan job's condition becomes `if: github.event.pull_request.draft == false && github.actor != 'dependabot[bot]'`.
- `.github/dependabot.yml` content, exactly: `version: 2`, one `updates` entry with `package-ecosystem: github-actions`, `directory: /`, `schedule: interval: weekly`, unquoted.
- A workflow file that pins a newer version than `Version.current` is rendered with that pin and compares as unchanged; `--force` always writes the current pin.
- Release: action pushed as one commit `xcflow X.Y.Z` by `github-actions[bot]` with a lightweight tag `vX.Y.Z`, after the GitHub release and **before** the Homebrew formula. Token secret: `ACTION_TOKEN`.
- Don't bump `Version.swift`; releases are cut separately. No attribution trailers in commits. Work on branch `olaf/published-action` in the worktree that already holds the spec.

## Review Focus

- A workflow whose install step was replaced by something other than `xcflow-action` (a fork, a local path): the file counts as differing and follows the normal overwrite rules, it is never silently left alone as "newer". Test in Task 4.
- An annotated tag in the action repo: `git ls-remote` prints two lines and the peeled `^{}` one carries the commit. Test in Task 3.
- Versions with unequal component counts, such as `0.2.8.1` against `0.2.8` and `1.0` against `0.9.9`: compared numerically per component. Test in Task 1.
- A hand-written `dependabot.yml` with `'github-actions'` in single quotes, or `"github-actions"` in double quotes: recognised as present. Test in Task 5.
- A malformed `--action-sha`: refused before anything is written, naming the flag. Test in Task 3.

---

### Task 1: ActionPin

**Files:**
- Create: `Sources/xcflow/ActionPin.swift`
- Test: `Tests/xcflowTests/ActionPinTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct ActionPin: Equatable {
      static let repository = "OlafAndreas/xcflow-action"
      let version: String      // "0.2.8"
      let commit: String?      // 40 hex characters, or nil for a tag reference
      var uses: String         // the value after `uses:`
      static func parse(_ workflow: String) -> ActionPin?            // from a whole workflow file
      static func isNewer(_ version: String, than other: String) -> Bool
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
struct ActionPinTests {
    let sha = String(repeating: "a", count: 40)

    @Test func usesPinsTheCommitWithTheVersionComment() {
        #expect(ActionPin(version: "0.2.8", commit: sha).uses == "OlafAndreas/xcflow-action@\(sha) # v0.2.8")
    }
    @Test func usesFallsBackToTheTag() {
        #expect(ActionPin(version: "0.2.8", commit: nil).uses == "OlafAndreas/xcflow-action@v0.2.8")
    }
    @Test func parseReadsACommitPin() {
        #expect(ActionPin.parse("steps:\n  - uses: OlafAndreas/xcflow-action@\(sha) # v0.2.9\n") == ActionPin(version: "0.2.9", commit: sha))
    }
    @Test func parseReadsATagPin() {
        #expect(ActionPin.parse("  uses: OlafAndreas/xcflow-action@v0.2.9\n") == ActionPin(version: "0.2.9", commit: nil))
    }
    @Test func parseIgnoresOtherInstallSteps() {
        #expect(ActionPin.parse("  uses: ./.github/actions/xcflow\n") == nil)
        #expect(ActionPin.parse("  uses: someone/xcflow-action@v0.2.9\n") == nil)
    }
    @Test func versionsCompareNumerically() {
        #expect(ActionPin.isNewer("0.10.0", than: "0.9.1"))
        #expect(ActionPin.isNewer("0.2.8.1", than: "0.2.8"))
        #expect(ActionPin.isNewer("1.0", than: "0.9.9"))
        #expect(!ActionPin.isNewer("0.2.8", than: "0.2.8"))
        #expect(!ActionPin.isNewer("0.2.7", than: "0.2.8"))
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter ActionPinTests`
Expected: compile error, `ActionPin` not found.

- [ ] **Step 3: Implement `ActionPin` in `Sources/xcflow/ActionPin.swift`**

`parse` searches the whole text with one regex for `OlafAndreas/xcflow-action@` followed by either `[0-9a-f]{40} # v(\d+(?:\.\d+)*)` or `v(\d+(?:\.\d+)*)`; anything else is `nil`. `isNewer` splits on `.`, maps to `Int`, pads the shorter with zeros, compares lexicographically.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter ActionPinTests`
Expected: 6 tests pass, no warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources/xcflow/ActionPin.swift Tests/xcflowTests/ActionPinTests.swift
git commit -m "Add ActionPin, the uses: line for the published install action"
```

---

### Task 2: LegacyAction recognises and removes the local action

**Files:**
- Create: `Sources/xcflow/LegacyAction.swift`
- Modify: `Sources/xcflow/Templates.swift:7-22` (move `archives(version:)` and `installAction` out; `files` builds the action file through `LegacyAction.render` for now)
- Modify: `Sources/xcflow/RepoSetup.swift:79` (`Templates.archives` becomes `LegacyAction.archives`)
- Modify: `Tests/xcflowTests/RepoSetupTests.swift:124-145` (move `installActionPicksTheArchiveForTheRunner`)
- Test: `Tests/xcflowTests/LegacyActionTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum LegacyAction {
      static let path = ".github/actions/xcflow/action.yml"
      static func archives(version: String) -> [String: String]           // moved from Templates, unchanged
      static func render(version: String, checksums: [String: String]) -> String
      static func isUntouched(_ content: String) -> Bool
      enum Removal: Equatable { case removed, kept, absent }
      static func remove(in root: URL, force: Bool, dryRun: Bool) throws -> Removal
  }
  ```
- Behaviour pinned by the spec: `isUntouched` reads the version out of `Install xcflow X.Y.Z` and the checksums out of each `NAME="…"; SUM="…"` pair, renders the frozen template with them, and compares byte for byte. `remove` deletes an untouched file, or any file with `force`, then `.github/actions/xcflow` and `.github/actions` when they are empty; in a dry run it decides but deletes nothing.

- [ ] **Step 1: Write the failing tests**

Move the assertions of `installActionPicksTheArchiveForTheRunner` into `LegacyActionTests.renderPicksTheArchiveForTheRunner`, calling `LegacyAction.render(version: "1.2.3", checksums:)` instead of filtering `Templates.files`. Add:

```swift
@Test func anUntouchedActionIsRecognised() {
    let sums = ["xcflow-0.2.6-linux-x86_64.tar.gz": String(repeating: "1", count: 64), "xcflow-0.2.6-linux-aarch64.tar.gz": String(repeating: "2", count: 64)]
    #expect(LegacyAction.isUntouched(LegacyAction.render(version: "0.2.6", checksums: sums)))
    #expect(LegacyAction.isUntouched(LegacyAction.render(version: "0.2.6", checksums: [:])))
}
@Test func anEditedActionIsNot() {
    let pristine = LegacyAction.render(version: "0.2.6", checksums: [:])
    #expect(!LegacyAction.isUntouched(pristine + "# edited\n"))
    #expect(!LegacyAction.isUntouched(pristine.replacing("OlafAndreas", with: "someone")))
    #expect(!LegacyAction.isUntouched("name: Install xcflow\n"))
}
@Test func removeDeletesAnUntouchedActionAndItsEmptyFolders() throws   // write pristine at root/LegacyAction.path; remove(force: false, dryRun: false) == .removed; `.github/actions` no longer exists; `.github` still does
@Test func removeKeepsAnEditedActionUnlessForced() throws              // edited → .kept and the file is still there; force: true → .removed
@Test func removeInADryRunTouchesNothing() throws                        // pristine, dryRun: true → .removed, file still exists
@Test func removeReportsAnAbsentAction() throws                          // empty repo → .absent
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter LegacyActionTests`
Expected: compile error, `LegacyAction` not found.

- [ ] **Step 3: Create `LegacyAction` and point `Templates` at it**

Move `Templates.installAction` verbatim into `LegacyAction` as `private static let template`, move `archives(version:)`, and make `render` the loop that `Templates.files` runs today (lines 15-20). `Templates.files` keeps its signature for now and builds the action `File` with `LegacyAction.render`; the checksum to-do in `RepoSetup.run` reads `LegacyAction.archives`. `isUntouched` uses the regexes `Install xcflow (\d+\.\d+\.\d+)` and `NAME="([^"]+)"; SUM="([0-9a-f]*)"`.

- [ ] **Step 4: Run the whole suite**

Run: `swift test`
Expected: all pass, `RepoSetupTests` no longer has `installActionPicksTheArchiveForTheRunner`, no warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources/xcflow/LegacyAction.swift Sources/xcflow/Templates.swift Sources/xcflow/RepoSetup.swift Tests/xcflowTests
git commit -m "Move the local install action into LegacyAction, which can recognise and remove it"
```

---

### Task 3: Workflows install from the published action

**Files:**
- Modify: `Sources/xcflow/Templates.swift` (`files` signature; the three `uses: ./.github/actions/xcflow` lines at 93, 167, 214; `paths:` at 71; plan `if:` at 83; rule `paths:` at 355; README template paragraph at the end of "Changes made in App Store Connect")
- Modify: `Sources/xcflow/RepoSetup.swift:7-51` (options), `:62-100` (run), and `releaseChecksums` plus `parseChecksums` under `// MARK: - Outside services` (removed)
- Modify: `Sources/xcflow/ActionPin.swift` (add the ls-remote parser)
- Modify: `Sources/xcflow/Usage.swift:6-7`
- Test: `Tests/xcflowTests/RepoSetupTests.swift`, `Tests/xcflowTests/ActionPinTests.swift`

**Interfaces:**
- Consumes: `ActionPin` (Task 1), `LegacyAction.render` (Task 2, no longer called from `Templates` after this task).
- Produces:
  ```swift
  // Templates
  static func files(action: ActionPin) -> [File]          // replaces files(version:checksums:); no action.yml in the result
  // ActionPin
  static func commit(fromLsRemote output: String) -> String?   // the peeled ^{} line's sha if present, else the first line's, else nil
  // RepoSetup
  static func run(arguments: [String], client: AppStoreConnectClient? = nil,
                  resolveActionCommit: @Sendable (String) -> String? = resolveActionCommit,
                  secrets: any SecretStore = GitHubSecrets(), interactive: Bool = isatty(STDIN_FILENO) == 1) async throws -> [String]
  static func resolveActionCommit(_ version: String) -> String?    // git ls-remote --tags https://github.com/OlafAndreas/xcflow-action.git vX.Y.Z, with GIT_TERMINAL_PROMPT=0
  struct Options { var actionSHA: String? }                          // --action-sha; checksumsFile is gone
  ```
- To-do when the commit can't be resolved, exact text: ``Pin `OlafAndreas/xcflow-action` to its commit for vX.Y.Z in the three workflows once the tag exists; the lookup failed (offline, or not released yet).``
- Refusal for a bad `--action-sha`, exact text: `--action-sha must be the 40-character commit sha of OlafAndreas/xcflow-action.`

- [ ] **Step 1: Rewrite the test helpers and write the failing tests**

In `RepoSetupTests`: delete `checksum`, `checksums`, `checksumsFile()`, `checksumFilesAreParsed`, `dryRunFetchesTheReleaseChecksums`. Add `let sha = String(repeating: "a", count: 40)` and pass `"--action-sha", sha` where the helpers passed `--checksums`. Make `setup` and `setupTodo` call `RepoSetup.run` with `interactive: false`, as `setupSecrets` already does, so a differing file is kept without a prompt even when the suite runs in a terminal. Change `Templates.files(version: "1.2.3", checksums: [:])` in `generatedActionsPinTheCurrentCheckout` and `workflowsRunOnLinux`, and `Templates.files(version: Version.current, checksums: checksums)` in `setupWritesEveryFileAndIsIdempotent`, to `Templates.files(action: ActionPin(version: Version.current, commit: sha))`. Drop `.github/actions/xcflow/action.yml` from that test's expected list. Add a `setupError(_ root:, _ extra:) async -> String` helper shaped like `setupSecretsError` but through `setup`. Add:

```swift
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
        resolveActionCommit: { version in version == Version.current ? sha : nil })
    #expect(!todo.contains { $0.contains("Pin `OlafAndreas/xcflow-action`") })
    #expect(files(in: root).isEmpty)
}
@Test func withoutAResolvableCommitTheWorkflowsUseTheTag() async throws {
    let root = try makeRepo()
    let todo = try await RepoSetup.run(
        arguments: ["--repo", root.path(percentEncoded: false), "--products", "com.example.app", "--skip-export", "--skip-secrets"],
        resolveActionCommit: { _ in nil })
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
@Test func generatedFilesNoLongerMentionTheLocalAction() {
    #expect(Templates.files(action: ActionPin(version: "1.2.3", commit: nil)).allSatisfy { !$0.content.contains(".github/actions/xcflow") })
}
```

In `ActionPinTests`:

```swift
@Test func lsRemotePrefersThePeeledTag() {
    let tag = String(repeating: "b", count: 40), commit = String(repeating: "c", count: 40)
    #expect(ActionPin.commit(fromLsRemote: "\(tag)\trefs/tags/v0.2.8\n\(commit)\trefs/tags/v0.2.8^{}\n") == commit)
    #expect(ActionPin.commit(fromLsRemote: "\(commit)\trefs/tags/v0.2.8\n") == commit)
    #expect(ActionPin.commit(fromLsRemote: "") == nil)
}
```

- [ ] **Step 2: Run the suite to see the new tests fail**

Run: `swift test`
Expected: compile errors on `files(action:)`, `resolveActionCommit:`, `commit(fromLsRemote:)`.

- [ ] **Step 3: Implement**

- `Templates`: `files(action:)` replaces the three `uses: ./.github/actions/xcflow` with `uses: {{action}}` in the templates and substitutes `action.uses`; remove the action `File`, `archives`, and the `.github/actions/xcflow/**` lines in the plan `paths:` and the rule `paths:`; extend the plan `if:`; in the workflows README, after the sentence about the sync PR, add: `It doesn't run on Dependabot's pull requests either, which bump the pinned xcflow version: those run without the repo's secrets, and the release the bump points to was verified on xcflow's side before it was published.`
- `RepoSetup.Options`: `--action-sha` sets `actionSHA`; `Options.init` refuses a value that isn't 40 hex characters with the exact text above. Remove `--checksums`.
- `RepoSetup.run`: after `exportProducts`, `let pin = ActionPin(version: Version.current, commit: options.actionSHA ?? resolveActionCommit(Version.current))`; append the to-do when `pin.commit == nil`; iterate `Templates.files(action: pin)`. Delete the checksum block, `releaseChecksums`, `parseChecksums`.
- `RepoSetup.resolveActionCommit` runs `["GIT_TERMINAL_PROMPT=0", "git", "ls-remote", "--tags", "https://github.com/OlafAndreas/xcflow-action.git", "v\(version)"]` through the existing `run(_:in:)` helper from `URL.currentDirectory()`, returns `nil` on any error, else `ActionPin.commit(fromLsRemote:)`.
- `Usage`: `[--checksums <file>]` becomes `[--action-sha <sha>]`.
- `main.swift` needs no change.

- [ ] **Step 4: Run the suite**

Run: `swift test`
Expected: all pass, no warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "Install xcflow in the generated workflows from OlafAndreas/xcflow-action, pinned by commit"
```

---

### Task 4: A newer pin is kept

**Files:**
- Modify: `Sources/xcflow/RepoSetup.swift` (the files loop in `run`; new helper)
- Test: `Tests/xcflowTests/RepoSetupTests.swift`

**Interfaces:**
- Consumes: `ActionPin.parse`, `ActionPin.isNewer`, `Templates.files(action:)`.
- Produces:
  ```swift
  /// The workflow as it should be written: with the current pin, unless the file already pins a newer version and --force wasn't given.
  static func keepingNewerPin(_ file: Templates.File, in root: URL, current: ActionPin, force: Bool) -> Templates.File
  ```
  Applies only to paths under `.github/workflows/`. A file whose install step `ActionPin.parse` can't read keeps the current pin, so it compares as differing.

- [ ] **Step 1: Write the failing tests**

```swift
private func repin(_ root: URL, to uses: String) throws {   // rewrites the uses: line of all three workflows
    for name in ["plan", "apply", "sync"] {
        let url = root.appending(path: ".github/workflows/xcflow-\(name).yml")
        let text = try String(contentsOf: url, encoding: .utf8)
        try text.replacing(/uses: OlafAndreas\/xcflow-action@.*/, with: "uses: \(uses)").write(to: url, atomically: true, encoding: .utf8)
    }
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
    #expect(try String(contentsOf: root.appending(path: ".github/workflows/xcflow-plan.yml"), encoding: .utf8).contains("@\(sha) # v\(Version.current)"))
}
@Test func forceWritesTheCurrentPinOverANewerOne() async throws       // repin to v99.0.0, setup(root, ["--force"]), expect the current pin
@Test func aForeignInstallStepIsADifference() async throws {
    let root = try makeRepo()
    try await setup(root)
    try repin(root, to: "someone/other-action@v1")
    try await setup(root)                                               // no --yes, not interactive: a differing file is kept
    let text = try String(contentsOf: root.appending(path: ".github/workflows/xcflow-plan.yml"), encoding: .utf8)
    #expect(text.contains("uses: someone/other-action@v1\n"))
    try await setup(root, ["--yes"])
    #expect(try String(contentsOf: root.appending(path: ".github/workflows/xcflow-plan.yml"), encoding: .utf8).contains("@\(sha) # v\(Version.current)"))
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter RepoSetupTests`
Expected: `aNewerPinIsKeptEvenWithYes` fails (the pin was overwritten); the other three pass already and stay as guards.

- [ ] **Step 3: Implement `keepingNewerPin` and call it in the files loop**

Read the existing file; if its path starts with `.github/workflows/`, `ActionPin.parse` succeeds, `isNewer(existing.version, than: current.version)` and `!force`, return the file from `Templates.files(action: existing)` with the same path. Otherwise return the file as is.

- [ ] **Step 4: Run the suite**

Run: `swift test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/xcflow/RepoSetup.swift Tests/xcflowTests/RepoSetupTests.swift
git commit -m "Keep a newer xcflow-action pin when setup runs again"
```

---

### Task 5: Dependabot config

**Files:**
- Modify: `Sources/xcflow/Templates.swift` (new constant), `Sources/xcflow/RepoSetup.swift` (new merge function, call after `.mcp.json`)
- Test: `Tests/xcflowTests/RepoSetupTests.swift`

**Interfaces:**
- Produces:
  ```swift
  // Templates
  static let dependabot = "version: 2\nupdates:\n  - package-ecosystem: github-actions\n    directory: /\n    schedule:\n      interval: weekly\n"
  // RepoSetup
  static func mergeDependabot(in root: URL, dryRun: Bool) throws -> FileStatus   // .created | .unchanged | .keptDifferent
  ```
- Recognition regex for an existing entry: `package-ecosystem:\s*["']?github-actions["']?`.
- To-do when kept, exact text: ``Add an entry to `.github/dependabot.yml` with `package-ecosystem: github-actions`, `directory: /` and a weekly schedule, so Dependabot bumps the xcflow-action pin.``

- [ ] **Step 1: Write the failing tests**

Add `.github/dependabot.yml` to the expected list in `setupWritesEveryFileAndIsIdempotent` and `#expect(try RepoSetup.mergeDependabot(in: root, dryRun: false) == .unchanged)` next to the `.mcp.json` check. Add:

```swift
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
@Test func aDependabotConfigWithoutGithubActionsGetsATodo() async throws {
    let root = try makeRepo()
    let existing = "version: 2\nupdates:\n  - package-ecosystem: npm\n    directory: /\n    schedule:\n      interval: weekly\n"
    try FileManager.default.createDirectory(at: root.appending(path: ".github"), withIntermediateDirectories: true)
    try existing.write(to: root.appending(path: ".github/dependabot.yml"), atomically: true, encoding: .utf8)
    let todo = try await setupTodo(root, ["--products", "com.example.app", "--skip-export"])
    #expect(try String(contentsOf: root.appending(path: ".github/dependabot.yml"), encoding: .utf8) == existing)
    #expect(todo.contains { $0.hasPrefix("Add an entry to `.github/dependabot.yml`") })
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter RepoSetupTests`
Expected: compile error on `Templates.dependabot` / `mergeDependabot`.

- [ ] **Step 3: Implement**

`mergeDependabot` mirrors `mergeMCPEntry`: missing file → create the folder and write `Templates.dependabot` unless `dryRun`, return `.created`; present and matching the regex → `.unchanged`; present otherwise → `.keptDifferent`. In `run`, print `describe(".github/dependabot.yml", …)` right after the `.mcp.json` line and append the to-do on `.keptDifferent`.

- [ ] **Step 4: Run the suite**

Run: `swift test`
Expected: all pass; `dryRunWritesNothing` still passes, which covers the dry run.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "Write a Dependabot config so the xcflow-action pin is bumped by pull request"
```

---

### Task 6: Setup removes the legacy local action

**Files:**
- Modify: `Sources/xcflow/RepoSetup.swift` (call `LegacyAction.remove` after the files loop)
- Test: `Tests/xcflowTests/RepoSetupTests.swift`

**Interfaces:**
- Consumes: `LegacyAction.remove(in:force:dryRun:)`, `LegacyAction.render`, `LegacyAction.path` (Task 2).
- Output lines, exact: `Removed .github/actions/xcflow/action.yml, replaced by OlafAndreas/xcflow-action` / `Would remove .github/actions/xcflow/action.yml, replaced by OlafAndreas/xcflow-action` / `Kept .github/actions/xcflow/action.yml, which differs from xcflow's version`.
- To-do when kept, exact: ``Remove `.github/actions/xcflow/`; the workflows now install xcflow from `OlafAndreas/xcflow-action`.``

- [ ] **Step 1: Write the failing tests**

```swift
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
@Test func forceRemovesAnEditedLegacyAction() async throws            // edited, ["--products", "com.example.app", "--skip-export", "--force"] → gone
@Test func dryRunLeavesTheLegacyAction() async throws                   // untouched, ["--products", "com.example.app", "--skip-export", "--dry-run"] → still exists
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter RepoSetupTests`
Expected: `setupRemovesAnUntouchedLegacyAction` and `forceRemovesAnEditedLegacyAction` fail (file still there); the other two pass.

- [ ] **Step 3: Wire `LegacyAction.remove` into `run`**

After the files loop and before `.mcp.json`: switch on the result, print the matching line, append the to-do on `.kept`, nothing on `.absent`.

- [ ] **Step 4: Run the suite**

Run: `swift test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/xcflow/RepoSetup.swift Tests/xcflowTests/RepoSetupTests.swift
git commit -m "Remove the untouched local install action when setup runs on an older repo"
```

---

### Task 7: The action's source, the release workflow and the README

**Files:**
- Create: `Action/action.yml`, `Action/README.md`
- Modify: `.github/workflows/release.yml:80-138` (publish job), `:140-184` (verify job)
- Modify: `README.md:48-54`
- Modify: `Sources/xcflow/LegacyAction.swift` (doc comment pointing at `Action/action.yml` as the live source)

**Interfaces:**
- Consumes: the placeholders `{{version}}`, `{{archive-linux-x86_64}}`, `{{checksum-linux-x86_64}}`, `{{archive-linux-aarch64}}`, `{{checksum-linux-aarch64}}` as in the legacy template.
- `Action/action.yml` is the legacy template's text verbatim, placeholders included. `Action/README.md`, four sentences: what the action installs and verifies; that `xcflow setup` pins it by commit in the workflows it writes and Dependabot bumps the pin; that each xcflow release publishes a matching `vX.Y.Z` tag here; that the files are generated by xcflow's release workflow from `Action/` in the xcflow repo and not edited by hand. Linux-only, say so.

- [ ] **Step 1: Write `Action/action.yml` and `Action/README.md`**

Check: `diff <(sed -n '/private static let template = #"""/,/"""#/p' Sources/xcflow/LegacyAction.swift | sed '1d;$d' | sed 's/^    //') Action/action.yml` prints nothing.

- [ ] **Step 2: Change the publish job**

Add `actions/checkout@v7` as its first step. After `Publish the GitHub release` and before `Update the Homebrew formula`, add:

```yaml
      - name: Publish the install action
        env:
          ACTION_TOKEN: ${{ secrets.ACTION_TOKEN }}
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          X86=$(grep "xcflow-$VERSION-linux-x86_64.tar.gz" dist/checksums.txt | cut -d ' ' -f 1)
          ARM=$(grep "xcflow-$VERSION-linux-aarch64.tar.gz" dist/checksums.txt | cut -d ' ' -f 1)
          test -n "$X86" -a -n "$ARM" || { echo "::error::Linux checksums missing from checksums.txt."; exit 1; }
          git clone "https://x-access-token:${ACTION_TOKEN}@github.com/OlafAndreas/xcflow-action.git" action
          sed -e "s/{{version}}/$VERSION/g" \
              -e "s/{{archive-linux-x86_64}}/xcflow-$VERSION-linux-x86_64.tar.gz/g" -e "s/{{checksum-linux-x86_64}}/$X86/g" \
              -e "s/{{archive-linux-aarch64}}/xcflow-$VERSION-linux-aarch64.tar.gz/g" -e "s/{{checksum-linux-aarch64}}/$ARM/g" \
              Action/action.yml > action/action.yml
          if grep -q "{{" action/action.yml; then echo "::error::A placeholder in action.yml wasn't filled."; exit 1; fi
          cp Action/README.md LICENSE action/
          cd action
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add action.yml README.md LICENSE
          git commit -m "xcflow $VERSION"
          git tag "v$VERSION"
          git push origin HEAD:main "v$VERSION"
```

- [ ] **Step 3: Change the verify job**

Replace `Install xcflow with the generated action` with a checkout of the action repo at this tag and an install through it:

```yaml
      - name: Checkout the install action at this tag
        uses: actions/checkout@v7
        with:
          repository: OlafAndreas/xcflow-action
          ref: refs/tags/${{ github.ref_name }}
          path: action

      - name: Install xcflow with the published action
        if: runner.os == 'Linux'
        uses: ./action
```

Move `Set up a repo with the released xcflow` after that checkout, since it needs `action/`. In it, drop the `Add the release checksums` grep and append:

```bash
          SHA=$(git -C action rev-parse HEAD)
          for WF in plan apply sync; do
            grep -q "uses: OlafAndreas/xcflow-action@$SHA # v$VERSION" "smoke/.github/workflows/xcflow-$WF.yml" || { echo "::error::xcflow-$WF.yml doesn't pin the published action at $SHA."; exit 1; }
          done
          test -f smoke/.github/dependabot.yml || { echo "::error::setup didn't write .github/dependabot.yml."; exit 1; }
          test ! -e smoke/.github/actions || { echo "::error::setup still wrote .github/actions/."; exit 1; }
```

In `Use the macOS archive`, delete the `grep -q "macOS" smoke/.github/actions/xcflow/action.yml` line; keep the PATH line.

- [ ] **Step 4: Update `README.md`**

In the "Set up a repo" list: the workflows bullet says the three workflows run on `ubuntu-latest` and install xcflow from `OlafAndreas/xcflow-action`, pinned to a commit; a new bullet says `.github/dependabot.yml` is added so Dependabot opens a pull request when a new xcflow is out, that the plan check doesn't run on those pull requests because they can't read the repo's secrets, and that the apply on the default branch is the first run of the new version in that repo. The closing sentence becomes: `Run it again at any time; files that already match are left alone, and a newer pin that Dependabot made is kept.` Add, after the list, one sentence: a repo set up by an earlier xcflow loses its `.github/actions/xcflow/` on the next `setup` if the file is untouched, or gets a to-do if it was edited.

- [ ] **Step 5: Check the YAML parses and the suite is green**

Run: `ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml"); YAML.load_file("Action/action.yml")' && swift test`
Expected: no Ruby output; all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Action .github/workflows/release.yml README.md Sources/xcflow/LegacyAction.swift
git commit -m "Publish the install action from each release, and document the Dependabot flow"
```

---

### Task 8: End-to-end check against a real repo, then the pull request

**Files:** none changed.

- [ ] **Step 1: Build and dry-run against the Sylvia repo, which is set up with 0.2.6's local action**

Run, from the worktree, with `SYLVIA=/Users/olafandreasovrum/Documents/ExternalProjects/Sylvia/ios-sylvia`:

```bash
swift build -c release && BIN=$(swift build -c release --show-bin-path)/xcflow
"$BIN" setup --repo "$SYLVIA" --dry-run --skip-secrets --action-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
"$BIN" setup --repo "$SYLVIA" --dry-run --skip-secrets
git -C "$SYLVIA" status --short | wc -l
```

Expected, first run: `Would update` for the three workflows, `Would create .github/dependabot.yml`, `Would remove .github/actions/xcflow/action.yml, replaced by OlafAndreas/xcflow-action`, no checksum to-do. Second run: the same, plus the `Pin OlafAndreas/xcflow-action` to-do, because no tag exists yet for the unreleased version. Last line: `0`, Sylvia untouched.

- [ ] **Step 2: Push and open the pull request**

```bash
git push -u origin olaf/published-action
gh pr create --title "Install xcflow from a published action, pinned by commit and bumped by Dependabot" --body-file <body>
```

The body: the spec's Why and Goals in a paragraph, the dry-run output from Step 1, and the two rollout steps that follow the merge. No attribution footer.

Expected: CI green on macOS and both Linux runners.

**After the merge, outside this plan:** cut the release (the owner says "bump release"), which publishes `xcflow-action` for the first time and verifies `setup` pins to it; then run `xcflow setup --yes` in Sylvia and open its PR.
