import Foundation
import MCP

actor AppSelection {
    private static let file = URL.applicationSupportDirectory.appending(path: "xcflow/apps.json")

    private let server: Server
    private var supportsElicitation = false
    private var chosen: Set<String>?

    init(server: Server) {
        self.server = server
    }

    func clientConnected(_ capabilities: Client.Capabilities) {
        supportsElicitation = capabilities.elicitation != nil
    }

    func chosenApps(from available: [String]) async throws -> Set<String> {
        if let chosen {
            return chosen
        }
        if let saved = Self.load() {
            chosen = saved
            return saved
        }
        return try await ask(available)
    }

    func ask(_ available: [String]) async throws -> Set<String> {
        guard supportsElicitation else {
            throw ToolError.refused("No apps chosen yet. Ask the user which of these apps the Xcode Cloud tools should show: \(available.joined(separator: ", ")). Then call choose_apps with their answer in `apps`.")
        }
        let current = (chosen ?? Self.load() ?? []).filter(available.contains).sorted()
        let result = try await server.requestElicitation(
            message: "Which apps should the Xcode Cloud tools show? Apps you leave out are hidden until you run choose_apps again.",
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
        try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(apps.sorted()).write(to: Self.file)
        chosen = apps
    }

    private static func load() -> Set<String>? {
        guard let data = try? Data(contentsOf: file),
              let apps = try? JSONDecoder().decode([String].self, from: data),
              !apps.isEmpty
        else {
            return nil
        }
        return Set(apps)
    }
}
