import Foundation

enum SyncCommand {
    static func run(_ command: String, arguments: [String]) async -> Int32 {
        var rest = arguments
        func value(of flag: String) -> String? {
            guard let index = rest.firstIndex(of: flag), rest.indices.contains(index + 1) else {
                return nil
            }
            defer {
                rest.removeSubrange(index...(index + 1))
            }
            return rest[index + 1]
        }
        func directory(_ path: String) -> URL {
            URL(filePath: path, directoryHint: .isDirectory, relativeTo: URL.currentDirectory()).standardizedFileURL
        }

        let root = directory(value(of: "--root") ?? "XcodeCloud")
        var dryRun: DryRunServer?
        var succeeded = false
        do {
            if let snapshot = value(of: "--dry-run") {
                dryRun = try DryRunServer(snapshot: directory(snapshot), desired: root)
            }
            let client = try dryRun.map(AppStoreConnectClient.init(dryRun:))
                ?? AppStoreConnectClient(tokens: TokenProvider(credentials: CredentialStore.load()))
            let sync = WorkflowSync(client: client, root: root)
            switch command {
            case "export":
                print(try await sync.export(bundleIDs: rest))
                succeeded = true
            case "plan":
                let plan = try await sync.plan()
                print(plan.markdown)
                succeeded = plan.errors.isEmpty
            default:
                let plan = try await sync.plan()
                if plan.errors.isEmpty {
                    try await sync.apply(plan) { print($0) }
                    succeeded = true
                } else {
                    print(plan.markdown)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("\(command) failed: \(error.localizedDescription)\n".utf8))
        }
        if let dryRun {
            print("\n## Requests (dry run, nothing was sent)\n")
            print(await dryRun.log.map { "```\n\($0)\n```" }.joined(separator: "\n"))
        }
        return succeeded ? 0 : 1
    }
}
