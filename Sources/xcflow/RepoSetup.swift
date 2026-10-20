import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum RepoSetup {
    struct Options {
        var dryRun = false
        var yes = false
        var force = false
        var products: [String]?
        var skipExport = false
        var skipSecrets = false
        var replaceSecrets = false
        var repo: String?
        var actionSHA: String?
        var keyID: String?
        var issuerID: String?
        var p8: String?

        /// All three key flags were given, so the secrets can be set without asking.
        var hasWholeKey: Bool { keyID != nil && issuerID != nil && p8 != nil }

        init(arguments: [String]) throws {
            var rest = arguments[...]
            while let argument = rest.popFirst() {
                switch argument {
                case "--dry-run": dryRun = true
                case "--yes", "-y": yes = true
                case "--force": force = true
                case "--skip-export": skipExport = true
                case "--skip-secrets": skipSecrets = true
                case "--replace-secrets": replaceSecrets = true
                case "--products": products = try Self.value(argument, &rest).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                case "--repo": repo = try Self.value(argument, &rest)
                case "--action-sha":
                    let sha = try Self.value(argument, &rest)
                    guard sha.wholeMatch(of: /[0-9a-f]{40}/) != nil else {
                        throw ToolError.refused("--action-sha must be the 40-character commit sha of \(ActionPin.repository).")
                    }
                    actionSHA = sha
                case "--key-id": keyID = try Self.value(argument, &rest)
                case "--issuer-id": issuerID = try Self.value(argument, &rest)
                case "--p8": p8 = try Self.value(argument, &rest)
                default: throw ToolError.refused("Unknown option \(argument). Run `xcflow help` for the options.")
                }
            }
        }

        private static func value(_ flag: String, _ rest: inout ArraySlice<String>) throws -> String {
            guard let value = rest.popFirst() else {
                throw ToolError.missingArgument(flag)
            }
            return value
        }
    }

    enum FileStatus: Equatable {
        case created
        case unchanged
        case overwritten
        case keptDifferent
    }

    @discardableResult
    static func run(
        arguments: [String],
        client: AppStoreConnectClient? = nil,
        resolveActionCommit: @Sendable (String) -> String? = resolveActionCommit,
        secrets: any SecretStore = GitHubSecrets(),
        interactive: Bool = isatty(STDIN_FILENO) == 1
    ) async throws -> [String] {
        let options = try Options(arguments: arguments)
        let root = try options.repo.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? gitRoot()
        let prompt = Prompt(yes: options.yes, dryRun: options.dryRun, interactive: interactive)
        let pem = try options.p8.map(readTeamKey)
        let workflows = root.appending(path: "XcodeCloud")
        let rootPath = root.standardizedFileURL.path(percentEncoded: false).replacing(/\/$/, with: "")
        print(options.dryRun ? "Dry run of xcflow setup in \(rootPath). Nothing is written or sent.\n" : "Setting up xcflow in \(rootPath).\n")

        var todo: [String] = []
        try await exportProducts(options, root: root, workflows: workflows, prompt: prompt, client: client, todo: &todo)

        let pin = ActionPin(version: Version.current, commit: options.actionSHA ?? resolveActionCommit(Version.current))
        var keptTagPins: [String] = []
        var rewritten: Set<String> = []
        for generated in Templates.files(action: pin) {
            let file = keepingNewerPin(generated, in: root, current: pin, force: options.force)
            let status = try write(file, in: root, force: options.force, dryRun: options.dryRun, prompt: prompt)
            print(describe(file.path, status, dryRun: options.dryRun))
            if status == .created || status == .overwritten {
                rewritten.insert(file.path)
            } else if status == .keptDifferent, pin.commit != nil,
                      let text = try? String(contentsOf: root.appending(path: file.path), encoding: .utf8),
                      let existing = ActionPin.parse(text), existing.commit == nil {
                keptTagPins.append(file.path)
            }
        }
        if pin.commit == nil {
            todo.append("Pin `\(ActionPin.repository)` to its commit for v\(Version.current) in the three workflows once the tag exists; the lookup failed (offline, or not released yet).")
        } else if !keptTagPins.isEmpty {
            todo.append("Pin `\(ActionPin.repository)` to its commit for v\(Version.current) in \(keptTagPins.joined(separator: ", ")), which still reference the tag: run `xcflow setup --yes`.")
        }
        // A workflow that still installs xcflow from the local action would break without it, so the action stays unless --force.
        let hasLegacyAction = FileManager.default.fileExists(atPath: root.appending(path: LegacyAction.path).path(percentEncoded: false))
        let stillUsing = hasLegacyAction ? workflowsUsingLegacyAction(in: root).subtracting(rewritten).sorted() : []
        if !stillUsing.isEmpty, !options.force {
            print("Kept \(LegacyAction.path); still used by \(stillUsing.joined(separator: ", "))")
        } else {
            switch try LegacyAction.remove(in: root, force: options.force, dryRun: options.dryRun) {
            case .removed:
                print("\(options.dryRun ? "Would remove" : "Removed") \(LegacyAction.path), replaced by \(ActionPin.repository)")
            case .kept:
                print("Kept \(LegacyAction.path), which differs from xcflow's version")
                todo.append("Remove `.github/actions/xcflow/`; the workflows now install xcflow from `\(ActionPin.repository)`.")
            case .absent:
                break
            }
        }
        if !stillUsing.isEmpty {
            todo.append("Install xcflow from `\(ActionPin.repository)` in \(stillUsing.joined(separator: ", ")) (run `xcflow setup --yes` for the generated workflows), then remove `.github/actions/xcflow/`.")
        }
        print(describe(".mcp.json", try mergeMCPEntry(in: root, dryRun: options.dryRun), dryRun: options.dryRun))
        let dependabotPath = dependabotConfigPath(in: root)
        let dependabot = try mergeDependabot(in: root, dryRun: options.dryRun)
        print(describe(dependabotPath, dependabot, dryRun: options.dryRun))
        if dependabot == .keptDifferent {
            todo.append("Add an entry to `\(dependabotPath)` with `package-ecosystem: github-actions`, `directory: /` and a weekly schedule, so Dependabot bumps the xcflow-action pin.")
        }

        if options.skipSecrets {
            todo.append("Make sure the `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_CONTENT` secrets are set on the GitHub repo. Skipped with --skip-secrets.")
        } else if options.dryRun {
            print(options.hasWholeKey
                ? "Would check the repo's GitHub secrets, and set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_CONTENT from the given key if any are missing."
                : "Would check the repo's GitHub secrets, and offer to set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_CONTENT if any are missing.")
        } else {
            let decision = SecretsDecision(existing: Result { try secrets.names(in: root) }, replace: options.replaceSecrets)
            print(decision.message)
            if let question = decision.question, options.hasWholeKey || prompt.ask(question) {
                try setSecrets(in: root, options: options, pem: pem, prompt: prompt, store: secrets)
            } else if decision.question != nil {
                todo.append("Set the `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_CONTENT` secrets on the GitHub repo, from a team API key: `xcflow setup --key-id <id> --issuer-id <id> --p8 <path>`.")
            }
        }

        todo.append("Check that the team key's role can edit Xcode Cloud workflows: Admin, or App Manager with Xcode Cloud access.")
        print("\nStill to do:")
        print(todo.map { "- \($0)" }.joined(separator: "\n"))
        return todo
    }

    // MARK: - Files

    /// The workflow as it should be written: with the current pin, unless the file already pins a newer version and --force wasn't given.
    static func keepingNewerPin(_ file: Templates.File, in root: URL, current: ActionPin, force: Bool) -> Templates.File {
        guard !force, file.path.hasPrefix(".github/workflows/"),
              let text = try? String(contentsOf: root.appending(path: file.path), encoding: .utf8),
              let existing = ActionPin.parse(text),
              ActionPin.isNewer(existing.version, than: current.version),
              let kept = Templates.files(action: existing).first(where: { $0.path == file.path })
        else {
            return file
        }
        return kept
    }

    /// The workflows under .github/workflows/, as repo-relative paths, whose text still installs xcflow from the local action.
    static func workflowsUsingLegacyAction(in root: URL) -> Set<String> {
        let folder = ".github/workflows"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: folder).path(percentEncoded: false))) ?? []
        return Set(names
            .filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
            .map { "\(folder)/\($0)" }
            .filter { (try? String(contentsOf: root.appending(path: $0), encoding: .utf8))?.contains("./.github/actions/xcflow") == true })
    }

    static func write(_ file: Templates.File, in root: URL, force: Bool, dryRun: Bool, prompt: Prompt) throws -> FileStatus {
        let url = root.appending(path: file.path)
        guard let current = try? String(contentsOf: url, encoding: .utf8) else {
            if !dryRun {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.content.write(to: url, atomically: true, encoding: .utf8)
            }
            return .created
        }
        guard current != file.content else {
            return .unchanged
        }
        guard force || prompt.ask("\(file.path) differs from xcflow's version. Overwrite it?") else {
            return .keptDifferent
        }
        if !dryRun {
            try file.content.write(to: url, atomically: true, encoding: .utf8)
        }
        return .overwritten
    }

    static func mergeMCPEntry(in root: URL, dryRun: Bool) throws -> FileStatus {
        let url = root.appending(path: ".mcp.json")
        let data = try? Data(contentsOf: url)
        var json = try data.flatMap { try JSONSerialization.jsonObject(with: $0) as? JSON } ?? [:]
        var servers = json["mcpServers"] as? JSON ?? [:]
        if let current = servers["xcflow"] {
            return WorkflowSync.canonical(current) == WorkflowSync.canonical(Templates.mcpServer) ? .unchanged : .keptDifferent
        }
        servers["xcflow"] = Templates.mcpServer
        json["mcpServers"] = servers
        if !dryRun {
            try (JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)).write(to: url)
        }
        return data == nil ? .created : .overwritten
    }

    /// The repo's Dependabot config: `.github/dependabot.yaml` when that is the one that exists, else `.github/dependabot.yml`.
    static func dependabotConfigPath(in root: URL) -> String {
        let yaml = ".github/dependabot.yaml"
        let yml = ".github/dependabot.yml"
        let exists = { (path: String) in FileManager.default.fileExists(atPath: root.appending(path: path).path(percentEncoded: false)) }
        return !exists(yml) && exists(yaml) ? yaml : yml
    }

    /// Writes .github/dependabot.yml when neither it nor .github/dependabot.yaml exists. An existing file is never edited (there is no YAML parser here); it is kept, and reported when it has no github-actions entry.
    static func mergeDependabot(in root: URL, dryRun: Bool) throws -> FileStatus {
        let url = root.appending(path: dependabotConfigPath(in: root))
        if FileManager.default.fileExists(atPath: url.path) {
            guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return .keptDifferent }
            return existing.contains(/package-ecosystem:\s*["']?github-actions["']?/) ? .unchanged : .keptDifferent
        }
        if !dryRun {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Templates.dependabot.write(to: url, atomically: true, encoding: .utf8)
        }
        return .created
    }

    private static func describe(_ path: String, _ status: FileStatus, dryRun: Bool) -> String {
        switch status {
        case .created: dryRun ? "Would create \(path)" : "Created \(path)"
        case .unchanged: "Unchanged \(path)"
        case .overwritten: dryRun ? "Would update \(path)" : "Updated \(path)"
        case .keptDifferent: "Kept \(path), which differs from xcflow's version"
        }
    }

    // MARK: - Products

    private static func existingProducts(in workflows: URL) -> [String] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: workflows, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// Exports the products' workflows into XcodeCloud/, or says what stands in the way. Setup carries on either way, so the repo is ready the moment the product exists.
    private static func exportProducts(_ options: Options, root: URL, workflows: URL, prompt: Prompt, client: AppStoreConnectClient?, todo: inout [String]) async throws {
        let existing = existingProducts(in: workflows)
        let products = options.products ?? existing
        let bundleIDs: [String]
        let described: String
        if !products.isEmpty {
            let missing = products.filter { !existing.contains($0) }
            guard !missing.isEmpty else {
                print("XcodeCloud/ already has \(products.joined(separator: ", ")). Leaving those files as they are.")
                return
            }
            bundleIDs = missing
            described = missing.joined(separator: ", ")
        } else {
            let manifests = try Manifests.find(in: root)
            guard !manifests.isEmpty else {
                print(Manifests.noManifestMessage(projects: Manifests.projects(in: root), root: root, hint: "xcflow setup --products com.example.app"), terminator: "\n\n")
                todo.append("Create the app's first Xcode Cloud workflow in Xcode or App Store Connect, then run `xcflow export`.")
                return
            }
            // export reads the manifests itself when it gets no bundle ids.
            bundleIDs = []
            described = "the products in " + manifests.map(\.path).joined(separator: ", ")
        }

        let command = (["xcflow", "export"] + bundleIDs).joined(separator: " ")
        if options.skipExport {
            todo.append("Export the workflows of \(described) with `\(command)`.")
        } else if options.dryRun {
            print("Would export the live workflows of \(described) from App Store Connect.")
        } else if prompt.ask("Export the live workflows of \(described) from App Store Connect into XcodeCloud/?") {
            do {
                let client = try client ?? AppStoreConnectClient(tokens: TokenProvider(credentials: CredentialStore.load()))
                print(try await WorkflowSync(client: client, root: workflows).export(bundleIDs: bundleIDs))
            } catch {
                print("Export failed: \(error.localizedDescription)", terminator: "\n\n")
                todo.append("Fix the above, then run `\(command)`.")
            }
        } else {
            todo.append("Export the workflows of \(described) with `\(command)`.")
        }
    }

    // MARK: - Outside services

    /// The commit the action's tag for `version` points to, or nil when it can't be looked up.
    @Sendable static func resolveActionCommit(_ version: String) -> String? {
        let command = ["GIT_TERMINAL_PROMPT=0", "git", "ls-remote", "--tags", "https://github.com/\(ActionPin.repository).git", "v\(version)"]
        return (try? run(command, in: URL.currentDirectory())).flatMap(ActionPin.commit(fromLsRemote:))
    }

    static let secretNames = ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_CONTENT"]

    struct SecretsDecision: Equatable {
        let message: String
        let question: String?

        init(existing: Result<Set<String>, Error>, replace: Bool) {
            let all = RepoSetup.secretNames.joined(separator: ", ")
            switch existing {
            case .failure(let error):
                message = "Couldn't read the repo's GitHub secrets: \(error.localizedDescription)"
                question = "Set \(all) on this repo's GitHub repository, from a team API key?"
            case .success(let names):
                let missing = RepoSetup.secretNames.filter { !names.contains($0) }
                if missing.isEmpty, replace {
                    message = "\(all) are already set on the GitHub repo."
                    question = "Replace all three, from a team API key?"
                } else if missing.isEmpty {
                    message = "\(all) are already set on the GitHub repo. Skipping. Pass --replace-secrets to set them again."
                    question = nil
                } else if missing.count == RepoSetup.secretNames.count {
                    message = "None of \(all) are set on the GitHub repo."
                    question = "Set them, from a team API key?"
                } else {
                    message = "\(missing.joined(separator: ", ")) \(missing.count == 1 ? "is" : "are") missing on the GitHub repo. All three have to come from the same key."
                    question = "Set all three, from a team API key?"
                }
            }
        }
    }

    /// The repo's GitHub Actions secrets, through `gh`.
    struct GitHubSecrets: SecretStore {
        func names(in root: URL) throws -> Set<String> {
            let output = try RepoSetup.run(["gh", "secret", "list", "--json", "name", "--jq", ".[].name"], in: root)
            return Set(output.split(whereSeparator: \.isNewline).map(String.init))
        }

        func set(_ name: String, to value: String, in root: URL) throws {
            try RepoSetup.run(["gh", "secret", "set", name], in: root, input: value)
        }
    }

    private static func setSecrets(in root: URL, options: Options, pem: Data?, prompt: Prompt, store: any SecretStore) throws {
        guard let keyID = options.keyID ?? prompt.read("Team key id:"),
              let issuerID = options.issuerID ?? prompt.read("Issuer id:"),
              let pem = try pem ?? prompt.read("Path to the team key's .p8 file:").map(readTeamKey)
        else {
            throw ToolError.refused("The key id, issuer id and .p8 path are all needed to set the secrets. Pass --key-id, --issuer-id and --p8, or run setup in a terminal to be asked for them.")
        }
        for (name, value) in [("ASC_KEY_ID", keyID), ("ASC_ISSUER_ID", issuerID), ("ASC_KEY_CONTENT", pem.base64EncodedString())] {
            try store.set(name, to: value, in: root)
            print("Set the \(name) secret.")
        }
    }

    private static func readTeamKey(at path: String) throws -> Data {
        do {
            return try Data(contentsOf: URL(filePath: (path as NSString).expandingTildeInPath))
        } catch {
            throw ToolError.refused("Couldn't read the team key at \(path): \(error.localizedDescription)")
        }
    }

    private static func gitRoot() throws -> URL {
        let path = try run(["git", "rev-parse", "--show-toplevel"], in: URL.currentDirectory()).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    @discardableResult
    private static func run(_ command: [String], in directory: URL, input: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = command
        process.currentDirectoryURL = directory
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        try process.run()
        if let input {
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
        }
        try inputPipe.fileHandleForWriting.close()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ToolError.refused("`\(command.joined(separator: " "))` failed: \(errorText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result
    }
}

/// Where the repo's GitHub secrets live. Tests swap in a fake; the tool uses `gh`.
protocol SecretStore {
    func names(in root: URL) throws -> Set<String>
    func set(_ name: String, to value: String, in root: URL) throws
}

struct Prompt {
    let yes: Bool
    let dryRun: Bool
    let interactive: Bool

    init(yes: Bool, dryRun: Bool, interactive: Bool = isatty(STDIN_FILENO) == 1) {
        self.yes = yes
        self.dryRun = dryRun
        self.interactive = interactive
    }

    func ask(_ question: String) -> Bool {
        if yes {
            return true
        }
        guard interactive, !dryRun else {
            return false
        }
        print("\(question) [y/N] ", terminator: "")
        return readLine()?.lowercased().hasPrefix("y") == true
    }

    func read(_ question: String) -> String? {
        guard interactive else {
            return nil
        }
        print("\(question) ", terminator: "")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        return answer.isEmpty ? nil : answer
    }
}
