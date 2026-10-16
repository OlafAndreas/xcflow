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
        var checksumsFile: String?

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
                case "--checksums": checksumsFile = try Self.value(argument, &rest)
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

    static func run(arguments: [String]) async throws {
        let options = try Options(arguments: arguments)
        let root = try options.repo.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? gitRoot()
        let prompt = Prompt(yes: options.yes, dryRun: options.dryRun)
        let workflows = root.appending(path: "XcodeCloud")
        let rootPath = root.standardizedFileURL.path(percentEncoded: false).replacing(/\/$/, with: "")
        print(options.dryRun ? "Dry run of xcflow setup in \(rootPath). Nothing is written or sent.\n" : "Setting up xcflow in \(rootPath).\n")

        var todo: [String] = []
        let existing = existingProducts(in: workflows)
        var products = options.products ?? existing
        if products.isEmpty {
            if !options.dryRun, prompt.ask("No products chosen. List the Xcode Cloud products your key can see in App Store Connect?") {
                products = try await chooseProducts(prompt: prompt)
            } else {
                todo.append("Choose the products to manage, e.g. `xcflow setup --products com.example.app`.")
            }
        }

        let missing = products.filter { !existing.contains($0) }
        if !missing.isEmpty {
            if options.skipExport {
                todo.append("Export the workflows of \(missing.joined(separator: ", ")) with `xcflow export \(missing.joined(separator: " "))`.")
            } else if options.dryRun {
                print("Would export the live workflows of \(missing.joined(separator: ", ")) from App Store Connect.")
            } else if prompt.ask("Export the live workflows of \(missing.joined(separator: ", ")) from App Store Connect into XcodeCloud/?") {
                let client = AppStoreConnectClient(tokens: try TokenProvider(credentials: try CredentialStore.load()))
                print(try await WorkflowSync(client: client, root: workflows).export(bundleIDs: missing))
            } else {
                todo.append("Export the workflows of \(missing.joined(separator: ", ")) with `xcflow export \(missing.joined(separator: " "))`.")
            }
        } else if !products.isEmpty {
            print("XcodeCloud/ already has \(products.joined(separator: ", ")). Leaving those files as they are.")
        }

        var checksumsText = try options.checksumsFile.map { try String(contentsOf: URL(filePath: $0), encoding: .utf8) }
        if checksumsText == nil, !options.dryRun {
            checksumsText = await releaseChecksums(version: Version.current)
        }
        let checksums = checksumsText.map(parseChecksums) ?? [:]
        let unverified = Templates.archives(version: Version.current).values.filter { checksums[$0] == nil }.sorted()
        if !unverified.isEmpty {
            todo.append("Add the release checksums to `.github/actions/xcflow/action.yml`, so CI verifies the download. Missing: \(unverified.joined(separator: ", ")).")
        }
        for file in Templates.files(version: Version.current, checksums: checksums) {
            let status = try write(file, in: root, force: options.force, dryRun: options.dryRun, prompt: prompt)
            print(describe(file.path, status, dryRun: options.dryRun))
        }
        print(describe(".mcp.json", try mergeMCPEntry(in: root, dryRun: options.dryRun), dryRun: options.dryRun))

        if options.skipSecrets {
            todo.append("Make sure the `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_CONTENT` secrets are set on the GitHub repo. Skipped with --skip-secrets.")
        } else if options.dryRun {
            print("Would check the repo's GitHub secrets, and offer to set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_CONTENT if any are missing.")
        } else {
            let decision = SecretsDecision(existing: existingSecretNames(in: root), replace: options.replaceSecrets)
            print(decision.message)
            if let question = decision.question, prompt.ask(question) {
                try setSecrets(in: root, prompt: prompt)
            } else if decision.question != nil {
                todo.append("Set the `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_CONTENT` secrets on the GitHub repo, from a team API key (base64 of the .p8 for the content).")
            }
        }

        todo.append("Check that the team key's role can edit Xcode Cloud workflows: Admin, or App Manager with Xcode Cloud access.")
        print("\nStill to do:")
        print(todo.map { "- \($0)" }.joined(separator: "\n"))
    }

    // MARK: - Files

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
        guard force || (!dryRun && prompt.ask("\(file.path) differs from xcflow's version. Overwrite it?")) else {
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

    private static func chooseProducts(prompt: Prompt) async throws -> [String] {
        let client = AppStoreConnectClient(tokens: try TokenProvider(credentials: try CredentialStore.load()))
        let products = try await client.products().sorted { $0.label < $1.label }
        for (index, product) in products.enumerated() {
            print("  \(index + 1). \(product.label)")
        }
        let answer = prompt.read("Which products should xcflow manage? Numbers, separated by commas:") ?? ""
        let picked = answer.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { products.indices.contains($0 - 1) }
            .map { products[$0 - 1].bundleID }
        guard !picked.isEmpty else {
            throw ToolError.refused("No products chosen.")
        }
        return picked
    }

    // MARK: - Outside services

    private static func releaseChecksums(version: String) async -> String? {
        guard !version.contains("-"),
              let url = URL(string: "https://github.com/OlafAndreas/xcflow/releases/download/v\(version)/checksums.txt"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func parseChecksums(_ text: String) -> [String: String] {
        var checksums: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0].count == 64 else {
                continue
            }
            checksums[String(parts[1].trimmingPrefix("*"))] = String(parts[0])
        }
        return checksums
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

    private static func existingSecretNames(in root: URL) -> Result<Set<String>, Error> {
        Result {
            let output = try run(["gh", "secret", "list", "--json", "name", "--jq", ".[].name"], in: root)
            return Set(output.split(whereSeparator: \.isNewline).map(String.init))
        }
    }

    private static func setSecrets(in root: URL, prompt: Prompt) throws {
        guard let keyID = prompt.read("Team key id:"), let issuerID = prompt.read("Issuer id:"), let path = prompt.read("Path to the team key's .p8 file:") else {
            throw ToolError.refused("The key id, issuer id and .p8 path are all needed to set the secrets.")
        }
        let pem = try Data(contentsOf: URL(filePath: (path as NSString).expandingTildeInPath))
        for (name, value) in [("ASC_KEY_ID", keyID), ("ASC_ISSUER_ID", issuerID), ("ASC_KEY_CONTENT", pem.base64EncodedString())] {
            try run(["gh", "secret", "set", name], in: root, input: value)
            print("Set the \(name) secret.")
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

struct Prompt {
    let yes: Bool
    let dryRun: Bool
    private let interactive = isatty(STDIN_FILENO) == 1

    init(yes: Bool, dryRun: Bool) {
        self.yes = yes
        self.dryRun = dryRun
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
