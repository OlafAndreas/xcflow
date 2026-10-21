import Foundation

extension XcodeCloudTools {
    func getWorkflow(_ client: AppStoreConnectClient, workflow reference: String) async throws -> String {
        let workflow = try await builds.workflow(client, reference)
        let response = try await client.get("/v1/ciWorkflows/\(workflow.id)", query: ["include": "xcodeVersion,macOsVersion,repository"])
        let data = response["data"] as? JSON ?? [:]
        let included = response["included"] as? [JSON] ?? []

        func includedName(_ relationship: String, attribute: String = "name") -> String {
            data.relationshipID(relationship).flatMap { id in included.first { $0.id == id }?.string(attribute) } ?? "?"
        }

        return """
        \(workflow.name) – \(workflow.product.label)
        Id: \(workflow.id)
        Xcode: \(includedName("xcodeVersion"))  macOS: \(includedName("macOsVersion"))  Repository: \(includedName("repository", attribute: "repositoryName"))
        File: \(workflowFile(id: workflow.id, bundleID: workflow.product.bundleID) ?? "none. Workflows are changed through files in XcodeCloud/, and this one has no file yet.")

        Attributes:
        \(Format.json(data.attributes))
        """
    }

    func listEnvironments(_ client: AppStoreConnectClient) async throws -> String {
        let xcode = try await client.getAll("/v1/ciXcodeVersions", query: ["fields[ciXcodeVersions]": "name,version,macOsVersions", "include": "macOsVersions", "fields[ciMacOsVersions]": "name"])
        let macOSNames = Dictionary(xcode.included.map { ($0.id, $0.string("name") ?? "?") }) { first, _ in first }

        let lines = xcode.data.map { version in
            let compatible = (((version["relationships"] as? JSON)?["macOsVersions"] as? JSON)?["data"] as? [JSON] ?? [])
                .compactMap { macOSNames[$0.id] }
            let suffix = compatible.isEmpty ? "" : "  macOS: \(compatible.joined(separator: ", "))"
            return "- \(version.string("name") ?? "?") (\(version.string("version") ?? "?"))\(suffix)"
        }
        return "Xcode versions, with the macOS versions each can run on:\n" + lines.joined(separator: "\n")
    }

    private func workflowFile(id: String, bundleID: String) -> String? {
        let root = ProcessInfo.processInfo.environment["XCFLOW_REPO_ROOT"].map { URL(filePath: $0, directoryHint: .isDirectory) } ?? URL.currentDirectory()
        let folder = root.appending(path: "XcodeCloud/\(bundleID)")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().first { name in
            guard let data = try? Data(contentsOf: folder.appending(path: name)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? JSON
            else {
                return false
            }
            return json["id"] as? String == id
        }.map { "XcodeCloud/\(bundleID)/\($0)" }
    }
}
