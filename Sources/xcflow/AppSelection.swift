import Foundation
import MCP

/// The apps the MCP tools show, chosen per repo on this machine: a repo for one team never hides another team's apps.
actor AppSelection {
    static let defaultStore = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "xcflow/apps.json")

    private let server: Server
    nonisolated let repo: RepoIdentity
    /// A JSON object mapping each repo to its app names. xcflow 0.3.0 and earlier kept one array for every repo; it is still read for a repo with no entry.
    private let store: URL
    private var supportsElicitation = false
    private var chosen: Set<String>?

    init(server: Server, repo: RepoIdentity = .here(root: nil), store: URL = defaultStore) {
        self.server = server
        self.repo = repo
        self.store = store
    }

    func clientConnected(_ capabilities: Client.Capabilities) {
        supportsElicitation = capabilities.elicitation != nil
    }

    /// The saved choice when it names an app this key sees, else the apps in the repo's XcodeCloud/ folders, else the user's answer.
    func chosenApps(of products: [Product]) async throws -> Set<String> {
        let available = XcodeCloudTools.appNames(of: products)
        if let chosen, !chosen.isDisjoint(with: available) {
            return chosen
        }
        if let saved = load(), !saved.isDisjoint(with: available) {
            chosen = saved
            return saved
        }
        let folders = Set(BuildScope.folders(in: repo.root.appending(path: "XcodeCloud")))
        let inRepo = Set(products.filter { folders.contains($0.bundleID) }.map(\.name))
        if !inRepo.isEmpty {
            chosen = inRepo
            return inRepo
        }
        return try await ask(available)
    }

    func ask(_ available: [String]) async throws -> Set<String> {
        guard supportsElicitation else {
            throw ToolError.refused("No apps chosen yet. Ask the user which of these apps the Xcode Cloud tools should show: \(available.joined(separator: ", ")). Then call choose_apps with their answer in `apps`.")
        }
        let current = (chosen ?? load() ?? []).filter(available.contains).sorted()
        let result = try await server.requestElicitation(
            message: "Which apps should the Xcode Cloud tools show in this repo? Apps you leave out are hidden here until you run choose_apps again.",
            requestedSchema: .init(
                properties: [
                    "apps": [
                        "type": "array",
                        "title": "Apps",
                        "items": ["type": "string", "enum": .array(available.map { .string($0) })],
                        "default": .array(current.map { .string($0) })
                    ]
                ],
                required: ["apps"]
            )
        )
        guard result.action == .accept else {
            throw ToolError.refused("No apps chosen, so the Xcode Cloud tools can't show anything yet. Call choose_apps to pick them.")
        }
        guard case .array(let values) = result.content?["apps"] else {
            throw ToolError.refused("Choose at least one app.")
        }
        let picked = Set(values.compactMap { value -> String? in
            guard case .string(let app) = value, available.contains(app) else {
                return nil
            }
            return app
        })
        try save(picked)
        return picked
    }

    func save(_ apps: Set<String>) throws {
        guard !apps.isEmpty else {
            throw ToolError.refused("Choose at least one app.")
        }
        // An unreadable store or the old single array starts afresh; the other repos' choices are kept.
        var choices = (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: store))) ?? [:]
        choices[repo.id] = apps.sorted()
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(choices)
        data.append(Data("\n".utf8))
        try data.write(to: store, options: .atomic)
        chosen = apps
    }

    /// This repo's saved apps, else the single array an older xcflow saved for every repo.
    private func load() -> Set<String>? {
        guard let data = try? Data(contentsOf: store) else {
            return nil
        }
        let apps = (try? JSONDecoder().decode([String: [String]].self, from: data))?[repo.id]
            ?? (try? JSONDecoder().decode([String].self, from: data))
        guard let apps, !apps.isEmpty else {
            return nil
        }
        return Set(apps)
    }
}
