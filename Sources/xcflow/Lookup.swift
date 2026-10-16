import Foundation

struct Workflow {
    let json: JSON
    let product: Product

    var id: String {
        json.id
    }

    var name: String {
        json.string("name") ?? id
    }
}

extension XcodeCloudTools {
    func products(_ client: AppStoreConnectClient, matching filter: String? = nil) async throws -> [Product] {
        let all = try await client.products()
        let chosen = try await apps.chosenApps(from: Self.appNames(of: all))
        let products = all.filter { chosen.contains($0.name) }
        guard let filter else {
            return products
        }
        let matches = products.filter { $0.bundleID == filter || $0.name.caseInsensitiveCompare(filter) == .orderedSame || $0.id == filter }
        guard !matches.isEmpty else {
            throw ToolError.notFound("No product matches \"\(filter)\". Products: \(products.map(\.label).joined(separator: ", ")). Apps left out with choose_apps are hidden.")
        }
        return matches
    }

    static func appNames(of products: [Product]) -> [String] {
        Set(products.map(\.name)).sorted()
    }

    func chooseApps(_ client: AppStoreConnectClient, apps names: [String]?) async throws -> String {
        let available = Self.appNames(of: try await client.products())
        let chosen: Set<String>
        if let names {
            let unknown = names.filter { !available.contains($0) }
            guard unknown.isEmpty else {
                throw ToolError.notFound("Unknown app: \(unknown.joined(separator: ", ")). Apps: \(available.joined(separator: ", "))")
            }
            chosen = Set(names)
            try await apps.save(chosen)
        } else {
            chosen = try await apps.ask(available)
        }
        let hidden = available.filter { !chosen.contains($0) }
        return "Showing: \(chosen.sorted().joined(separator: ", "))" + (hidden.isEmpty ? "" : "\nHidden: \(hidden.joined(separator: ", "))")
    }

    func workflows(_ client: AppStoreConnectClient, in products: [Product]) async throws -> [Workflow] {
        var workflows: [Workflow] = []
        for product in products {
            let page = try await client.getAll("/v1/ciProducts/\(product.id)/workflows")
            workflows += page.data.map { Workflow(json: $0, product: product) }
        }
        return workflows
    }

    func workflow(_ client: AppStoreConnectClient, _ reference: String) async throws -> Workflow {
        let all = try await workflows(client, in: try await products(client))
        let matches = all.filter { $0.id == reference || $0.name.caseInsensitiveCompare(reference) == .orderedSame }
        guard let match = matches.first else {
            throw ToolError.notFound("No workflow matches \"\(reference)\". Use list_workflows to see the names.")
        }
        guard matches.count == 1 else {
            let candidates = matches.map { "\($0.product.label): \($0.id)" }.joined(separator: "\n")
            throw ToolError.ambiguous("\"\(reference)\" exists in several products. Use the id instead:\n\(candidates)")
        }
        return match
    }

    func buildRunID(_ client: AppStoreConnectClient, _ reference: String) async throws -> String {
        guard let number = Int(reference.trimmingCharacters(in: CharacterSet(charactersIn: "# "))) else {
            return reference
        }
        for product in try await products(client) {
            let page = try await client.getAll(
                "/v1/ciProducts/\(product.id)/buildRuns",
                query: ["sort": "-number", "limit": "200", "fields[ciBuildRuns]": "number"],
                limit: 2000,
                until: { ($0.attributes["number"] as? Int ?? 0) <= number }
            )
            if let run = page.data.first(where: { $0.attributes["number"] as? Int == number }) {
                return run.id
            }
        }
        throw ToolError.notFound("No build number \(number) found.")
    }
}

enum Format {
    private static let displayStyle = Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        timeZone: .current,
        calendar: Calendar(identifier: .gregorian)
    )

    static func parse(_ value: Any?) -> Date? {
        guard let string = value as? String else {
            return nil
        }
        return (try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(string, strategy: Date.ISO8601FormatStyle()))
    }

    static func date(_ value: Any?) -> String {
        parse(value)?.formatted(displayStyle) ?? "-"
    }

    static func duration(from start: Any?, to end: Any?) -> String? {
        guard let start = parse(start), let end = parse(end) else {
            return nil
        }
        return "\(Int(end.timeIntervalSince(start) / 60)) min"
    }

    static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else {
            return value is NSNull ? "null" : "\(value)"
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func compactJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        else {
            return value is NSNull ? "null" : "\(value)"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
