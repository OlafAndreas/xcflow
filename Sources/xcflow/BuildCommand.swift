import Foundation

/// `xcflow builds`, `build`, `logs` and `run`: the build tools on the command line, scoped by the repo's XcodeCloud folders.
enum BuildCommand {
    static let usage = [
        "builds": "xcflow builds [<workflow>] [--branch <name>] [--limit <n>] [--product <bundle id> | --all] [--root <folder>]",
        "build": "xcflow build <number or id> [--wait] [--timeout <minutes>] [--product <bundle id> | --all] [--root <folder>]",
        "logs": "xcflow logs <number or id> [--action <name>] [--product <bundle id> | --all] [--root <folder>]",
        "run": "xcflow run <workflow> (--branch <name> | --tag <name>) [--clean] [--wait] [--timeout <minutes>] [--product <bundle id> | --all] [--root <folder>]"
    ]

    private static let valueFlags: [String: Set<String>] = [
        "builds": ["--branch", "--limit"],
        "build": ["--timeout"],
        "logs": ["--action"],
        "run": ["--branch", "--tag", "--timeout"]
    ]

    private static let switches: [String: Set<String>] = [
        "builds": [],
        "build": ["--wait"],
        "logs": [],
        "run": ["--clean", "--wait"]
    ]

    private struct UsageError: Error {
        let reason: String
    }

    private struct Options {
        var positionals: [String] = []
        var values: [String: String] = [:]
        var switches: Set<String> = []
    }

    static func run(
        _ command: String, arguments: [String],
        client: AppStoreConnectClient? = nil,
        pollEvery: Duration = .seconds(30), contactLimit: Duration = .seconds(600),
        out: @Sendable (String) -> Void = { print($0) },
        err: @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) async -> Int32 {
        let options: Options
        do {
            options = try parse(command, arguments)
        } catch let error as UsageError {
            err(error.reason)
            err("Usage: \(usage[command] ?? command)")
            return 64
        } catch {
            err("\(command) failed: \(error.localizedDescription)")
            return 2
        }

        let rootPath = options.values["--root"] ?? "XcodeCloud"
        let root = URL(filePath: rootPath, directoryHint: .isDirectory, relativeTo: URL.currentDirectory()).standardizedFileURL
        let builds = Builds(scope: BuildScope.resolve(root: root, product: options.values["--product"], all: options.switches.contains("--all")))
        let timeoutMinutes = options.values["--timeout"].flatMap(Double.init) ?? 120
        let wait = options.switches.contains("--wait")

        func waitAndSummarize(_ client: AppStoreConnectClient, runID: String) async throws -> Int32 {
            let status = try await builds.wait(client, runID: runID, every: pollEvery, timeout: .seconds(timeoutMinutes * 60), contactLimit: contactLimit, progress: err)
            out(try await builds.getBuild(client, build: runID))
            return status == "SUCCEEDED" ? 0 : 1
        }

        do {
            let client = try client ?? AppStoreConnectClient(tokens: TokenProvider(credentials: CredentialStore.load()))
            switch command {
            case "builds":
                let limit = options.values["--limit"].flatMap(Int.init) ?? 20
                out(try await builds.listBuilds(client, workflow: options.positionals.first, branch: options.values["--branch"], limit: limit))
                return 0
            case "build":
                let reference = options.positionals[0]
                guard wait else {
                    out(try await builds.getBuild(client, build: reference))
                    return 0
                }
                return try await waitAndSummarize(client, runID: try await builds.buildRunID(client, reference))
            case "logs":
                out(try await builds.getBuildLogs(client, build: options.positionals[0], action: options.values["--action"]))
                return 0
            default:
                let reference = options.values["--branch"] ?? options.values["--tag"] ?? ""
                let clean: Bool? = options.switches.contains("--clean") ? true : nil
                let started = try await builds.start(client, workflow: options.positionals[0], reference: reference, clean: clean)
                out(started.text)
                return wait ? try await waitAndSummarize(client, runID: started.runID) : 0
            }
        } catch let error as WaitError {
            switch error {
            case .timedOut(let number, let runID, _):
                err("Timed out after \(minutes(timeoutMinutes)) minutes; build #\(number) is still running. Id: \(runID)")
                return 124
            case .lostContact(let number, let runID):
                let limit = Double(contactLimit.components.seconds) + Double(contactLimit.components.attoseconds) / 1e18
                err("Lost contact with App Store Connect for \(minutes(limit / 60)) minutes; build #\(number) may still be running. Id: \(runID)")
                return 2
            }
        } catch {
            err("\(command) failed: \(error.localizedDescription)")
            return 2
        }
    }

    /// Whole minutes print without a decimal point; the description is locale-independent.
    private static func minutes(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    private static func parse(_ command: String, _ arguments: [String]) throws -> Options {
        guard let commandValues = valueFlags[command], let commandSwitches = switches[command] else {
            throw UsageError(reason: "Unknown command: \(command)")
        }
        let values = commandValues.union(["--product", "--root"])
        let flags = commandSwitches.union(["--all"])

        var options = Options()
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if values.contains(argument) {
                guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
                    throw UsageError(reason: "\(argument) needs a value.")
                }
                guard options.values[argument] == nil else {
                    throw UsageError(reason: "\(argument) is given twice.")
                }
                options.values[argument] = arguments[index + 1]
                index += 2
                continue
            }
            if flags.contains(argument) {
                options.switches.insert(argument)
            } else if argument.hasPrefix("--") {
                throw UsageError(reason: "Unknown option \(argument) for \(command).")
            } else {
                options.positionals.append(argument)
            }
            index += 1
        }

        if options.values["--product"] != nil && options.switches.contains("--all") {
            throw UsageError(reason: "Pass --product or --all, not both.")
        }
        if let limit = options.values["--limit"], (Int(limit) ?? 0) < 1 {
            throw UsageError(reason: "--limit takes a whole number above zero, not \"\(limit)\".")
        }
        if let timeout = options.values["--timeout"], !(Double(timeout).map { $0 > 0 && $0.isFinite } ?? false) {
            throw UsageError(reason: "--timeout takes a number of minutes above zero, not \"\(timeout)\".")
        }

        switch command {
        case "builds":
            guard options.positionals.count <= 1 else {
                throw UsageError(reason: "builds takes at most one workflow.")
            }
        case "build", "logs":
            guard options.positionals.count == 1 else {
                throw UsageError(reason: "\(command) takes one build number or id.")
            }
        default:
            guard options.positionals.count == 1 else {
                throw UsageError(reason: "run takes one workflow.")
            }
            switch (options.values["--branch"], options.values["--tag"]) {
            case (nil, nil): throw UsageError(reason: "run needs --branch or --tag.")
            case (_?, _?): throw UsageError(reason: "Pass --branch or --tag, not both.")
            default: break
            }
        }
        return options
    }
}
