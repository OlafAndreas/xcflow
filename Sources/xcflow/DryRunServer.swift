import Foundation

// Answers reads from workflow files instead of App Store Connect. Ids the files don't carry become readable placeholders.
actor DryRunServer {
    private struct SnapshotWorkflow {
        let bundleID: String
        let definition: WorkflowDefinition
    }

    private let workflows: [SnapshotWorkflow]
    private let xcodeVersions: [String]
    private let macOSVersions: [String]
    private let repositories: [String]
    private(set) var log: [String] = []

    init(snapshot: URL, desired: URL) throws {
        let snapshotFiles = try Self.read(snapshot)
        workflows = snapshotFiles.map { SnapshotWorkflow(bundleID: $0.bundleID, definition: $0.definition) }
        let all = (snapshotFiles + (try Self.read(desired))).map(\.definition)
        xcodeVersions = Set(all.compactMap(\.xcodeVersion)).sorted()
        macOSVersions = Set(all.compactMap(\.macOsVersion)).sorted()
        repositories = Set(all.map(\.repository)).sorted()
    }

    func respond(_ method: String, _ url: URL, body: Data?) throws -> Data {
        let json = try response(method, url, body: body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSON })
        return json.isEmpty ? Data() : try JSONSerialization.data(withJSONObject: json)
    }

    private func response(_ method: String, _ url: URL, body: JSON?) throws -> JSON {
        let path = url.path(percentEncoded: false)
        let query = url.query(percentEncoded: false).map { "?\($0)" } ?? ""
        let parts = path.split(separator: "/").map(String.init)

        guard method == "GET" else {
            var entry = "\(method) \(path)"
            if let body, let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                entry += "\n" + String(decoding: data, as: UTF8.self)
            }
            log.append(entry)
            switch method {
            case "POST":
                return ["data": ["type": "ciWorkflows", "id": "<new workflow id>"] as JSON]
            case "PATCH":
                return ["data": (body?["data"] as? JSON) ?? [:]]
            default:
                return [:]
            }
        }

        log.append("GET \(path)\(query)")
        switch parts {
        case ["v1", "ciProducts"]:
            let bundleIDs = Set(workflows.map(\.bundleID)).sorted()
            return [
                "data": bundleIDs.map { bundleID -> JSON in
                    [
                        "type": "ciProducts",
                        "id": Self.placeholder("ciProducts", bundleID),
                        "attributes": ["name": bundleID],
                        "relationships": ["app": ["data": ["type": "apps", "id": Self.placeholder("apps", bundleID)]]]
                    ]
                },
                "included": bundleIDs.map { ["type": "apps", "id": Self.placeholder("apps", $0), "attributes": ["bundleId": $0]] as JSON }
            ]
        case let parts where parts.count == 4 && parts[1] == "ciProducts" && parts[3] == "workflows":
            return ["data": workflows.filter { Self.placeholder("ciProducts", $0.bundleID) == parts[2] }.map { workflow -> JSON in
                ["type": "ciWorkflows", "id": workflow.definition.id ?? "", "attributes": ["name": workflow.definition.name]]
            }]
        case let parts where parts.count == 3 && parts[1] == "ciWorkflows":
            guard let workflow = workflows.first(where: { $0.definition.id == parts[2] }) else {
                throw AppStoreConnectError(status: 404, details: ["Dry run: no workflow \(parts[2]) in the snapshot"])
            }
            return workflowResponse(workflow.definition)
        case ["v1", "ciXcodeVersions"]:
            return ["data": xcodeVersions.map { Self.environment("ciXcodeVersions", $0) }]
        case ["v1", "ciMacOsVersions"]:
            return ["data": macOSVersions.map { Self.environment("ciMacOsVersions", $0) }]
        case ["v1", "scmRepositories"]:
            return ["data": repositories.map { ["type": "scmRepositories", "id": Self.placeholder("scmRepositories", $0), "attributes": ["repositoryName": $0]] as JSON }]
        default:
            throw AppStoreConnectError(status: 404, details: ["Dry run: no snapshot answer for GET \(path)"])
        }
    }

    private func workflowResponse(_ definition: WorkflowDefinition) -> JSON {
        var relationships: JSON = ["repository": ["data": ["type": "scmRepositories", "id": Self.placeholder("scmRepositories", definition.repository)]]]
        var included: [JSON] = [["type": "scmRepositories", "id": Self.placeholder("scmRepositories", definition.repository), "attributes": ["repositoryName": definition.repository]]]
        if let xcode = definition.xcodeVersion {
            relationships["xcodeVersion"] = ["data": ["type": "ciXcodeVersions", "id": Self.placeholder("ciXcodeVersions", xcode)]]
            included.append(Self.environment("ciXcodeVersions", xcode))
        }
        if let macOS = definition.macOsVersion {
            relationships["macOsVersion"] = ["data": ["type": "ciMacOsVersions", "id": Self.placeholder("ciMacOsVersions", macOS)]]
            included.append(Self.environment("ciMacOsVersions", macOS))
        }
        return ["data": ["type": "ciWorkflows", "id": definition.id ?? "", "attributes": definition.attributes, "relationships": relationships] as JSON, "included": included]
    }

    private static func environment(_ type: String, _ name: String) -> JSON {
        ["type": type, "id": placeholder(type, name), "attributes": ["name": name]]
    }

    private static func placeholder(_ type: String, _ name: String) -> String {
        "<\(type): \(name)>"
    }

    private static func read(_ root: URL) throws -> [(bundleID: String, definition: WorkflowDefinition)] {
        var result: [(String, WorkflowDefinition)] = []
        let fileManager = FileManager.default
        for folder in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            for file in try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? JSON else {
                    continue
                }
                result.append((folder.lastPathComponent, try WorkflowDefinition(fileJSON: json)))
            }
        }
        return result
    }
}
