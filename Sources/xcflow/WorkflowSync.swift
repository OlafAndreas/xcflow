import Foundation

struct WorkflowDefinition {
    static let readOnlyAttributes: Set<String> = ["lastModifiedDate"]

    var id: String?
    var repository: String
    var xcodeVersion: String?
    var macOsVersion: String?
    var attributes: JSON

    var name: String {
        attributes["name"] as? String ?? ""
    }

    var fileJSON: JSON {
        var json: JSON = ["repository": repository, "xcodeVersion": xcodeVersion ?? NSNull(), "macOsVersion": macOsVersion ?? NSNull(), "attributes": attributes]
        if let id {
            json["id"] = id
        }
        return json
    }

    init(id: String?, repository: String, xcodeVersion: String?, macOsVersion: String?, attributes: JSON) {
        self.id = id
        self.repository = repository
        self.xcodeVersion = xcodeVersion
        self.macOsVersion = macOsVersion
        self.attributes = Self.withNormalizedMatchers(Self.withoutDisplayLabels(attributes.filter { !Self.readOnlyAttributes.contains($0.key) }))
    }

    // Xcode Cloud fills these in from deviceTypeIdentifier and runtimeIdentifier, and they go stale. Comparing them would show changes nobody made.
    private static let displayLabels: Set<String> = ["deviceTypeName", "runtimeName"]

    private static func withoutDisplayLabels(_ attributes: JSON) -> JSON {
        guard let actions = attributes["actions"] as? [JSON] else {
            return attributes
        }
        var attributes = attributes
        attributes["actions"] = actions.map { action -> JSON in
            guard var configuration = action["testConfiguration"] as? JSON,
                  let destinations = configuration["testDestinations"] as? [JSON]
            else {
                return action
            }
            configuration["testDestinations"] = destinations.map { $0.filter { !displayLabels.contains($0.key) } }
            var action = action
            action["testConfiguration"] = configuration
            return action
        }
        return attributes
    }

    // App Store Connect stores an unset matcher directory as "", while an unset fileExtension or fileName stays null. A file writing null would otherwise always differ.
    private static let startConditionsWithFileRules = ["branchStartCondition", "pullRequestStartCondition", "tagStartCondition"]

    private static func withNormalizedMatchers(_ attributes: JSON) -> JSON {
        var attributes = attributes
        for key in startConditionsWithFileRules {
            guard var condition = attributes[key] as? JSON,
                  var rule = condition["filesAndFoldersRule"] as? JSON,
                  let matchers = rule["matchers"] as? [JSON]
            else {
                continue
            }
            rule["matchers"] = matchers.map { matcher -> JSON in
                guard matcher["directory"] == nil || matcher["directory"] is NSNull else {
                    return matcher
                }
                var matcher = matcher
                matcher["directory"] = ""
                return matcher
            }
            condition["filesAndFoldersRule"] = rule
            attributes[key] = condition
        }
        return attributes
    }

    init(fileJSON json: JSON) throws {
        func required(_ key: String) throws -> String {
            guard let value = json[key] as? String, !value.isEmpty else {
                throw ToolError.missingArgument(key)
            }
            return value
        }
        guard let attributes = json["attributes"] as? JSON else {
            throw ToolError.missingArgument("attributes")
        }
        guard let name = attributes["name"] as? String, !name.isEmpty else {
            throw ToolError.missingArgument("attributes.name")
        }
        self.init(
            id: json["id"] as? String,
            repository: try required("repository"),
            xcodeVersion: json["xcodeVersion"] as? String,
            macOsVersion: json["macOsVersion"] as? String,
            attributes: attributes
        )
    }
}

struct WorkflowFile {
    let path: String
    let product: Product
    let definition: WorkflowDefinition
}

struct LiveWorkflow {
    static let lockedWarning = "> ⚠️ This workflow has **Restrict Editing** turned on in App Store Connect, so App Store Connect may reject this change. Turn Restrict Editing off for it in App Store Connect before merging."

    let product: Product
    let definition: WorkflowDefinition

    var id: String {
        definition.id ?? ""
    }

    var isLockedForEditing: Bool {
        definition.attributes["isLockedForEditing"] as? Bool == true
    }
}

struct SyncPlan {
    enum Change {
        case create(WorkflowFile)
        case update(WorkflowFile, LiveWorkflow, attributes: [String], environment: [String])
        case delete(LiveWorkflow)
    }

    var changes: [Change] = []
    var unchanged = 0
    var errors: [String] = []
    fileprivate var environments: Environments?
}

/// The live catalog plan checks the files against.
struct Environments {
    let xcodeVersions: [JSON]
    let macOSVersions: [JSON]
    let repositories: [JSON]

    func xcodeID(_ name: String) -> String? {
        Self.id(of: name, in: xcodeVersions, attribute: "name")
    }

    func macOSID(_ name: String) -> String? {
        Self.id(of: name, in: macOSVersions, attribute: "name")
    }

    func repositoryID(_ name: String) -> String? {
        Self.id(of: name, in: repositories, attribute: "repositoryName")
    }

    /// The ids of the macOS versions an Xcode version runs on; nil when the catalog leaves them out, as a dry run does.
    func macOSIDs(forXcode id: String) -> Set<String>? {
        let xcode = xcodeVersions.first { $0.id == id }
        guard let data = (((xcode?["relationships"] as? JSON)?["macOsVersions"] as? JSON)?["data"] as? [JSON]) else {
            return nil
        }
        return Set(data.map(\.id))
    }

    private static func id(of name: String, in items: [JSON], attribute: String) -> String? {
        items.first { $0.string(attribute)?.caseInsensitiveCompare(name) == .orderedSame }?.id
    }
}

struct WorkflowSync {
    let client: AppStoreConnectClient
    let root: URL

    func export(bundleIDs requested: [String]) async throws -> String {
        let products = try await client.products()
        var lines: [String] = []
        var bundleIDs = requested.isEmpty ? try managedBundleIDs() : requested
        if bundleIDs.isEmpty {
            (bundleIDs, lines) = try Self.manifestProducts(in: root.deletingLastPathComponent(), products: products)
        }
        for bundleID in bundleIDs {
            let product = try await product(bundleID, in: products)
            let folder = root.appending(path: bundleID)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let existing = try readFiles(in: folder, product: product).reduce(into: [String: String]()) { names, file in
                if let id = file.definition.id {
                    names[id] = URL(filePath: file.path).lastPathComponent
                }
            }

            var written: Set<String> = []
            for workflow in try await liveWorkflows(of: product) {
                var fileName = existing[workflow.id] ?? "\(Self.slug(workflow.definition.name)).json"
                while written.contains(fileName) {
                    fileName = fileName.replacingOccurrences(of: ".json", with: "-2.json")
                }
                try Self.encode(workflow.definition.fileJSON).write(to: folder.appending(path: fileName))
                written.insert(fileName)
            }
            for stale in try jsonFileNames(in: folder) where !written.contains(stale) {
                try FileManager.default.removeItem(at: folder.appending(path: stale))
            }
            lines.append("Exported \(written.count) workflows of \(product.label) to \(folder.path(percentEncoded: false))")
        }
        return lines.joined(separator: "\n")
    }

    func plan() async throws -> SyncPlan {
        var plan = SyncPlan()
        let products = try await client.products()
        let environments = Environments(
            xcodeVersions: try await client.getAll("/v1/ciXcodeVersions", query: ["include": "macOsVersions", "limit[macOsVersions]": "50"]).data,
            macOSVersions: try await client.getAll("/v1/ciMacOsVersions").data,
            repositories: try await client.getAll("/v1/scmRepositories", query: ["fields[scmRepositories]": "repositoryName"]).data
        )
        plan.environments = environments

        var managed: [(Product, [WorkflowFile])] = []
        for bundleID in try managedBundleIDs() {
            do {
                let product = try await product(bundleID, in: products)
                let files = try readFiles(in: root.appending(path: bundleID), product: product, errors: &plan.errors)
                plan.errors += Self.validate(files, environments, repo: root.deletingLastPathComponent())
                managed.append((product, files))
            } catch {
                plan.errors.append("\(bundleID): \(error.localizedDescription)")
            }
        }
        guard plan.errors.isEmpty else {
            return plan
        }

        for (product, files) in managed {
            var live = try await liveWorkflows(of: product)
            for file in files {
                let index: Int?
                if let id = file.definition.id {
                    index = live.firstIndex { $0.id == id }
                    guard index != nil else {
                        plan.errors.append("\(file.path): no workflow with id \(id) in \(product.label). Remove the id to create it again.")
                        continue
                    }
                } else {
                    index = live.firstIndex { $0.definition.name.caseInsensitiveCompare(file.definition.name) == .orderedSame }
                }
                guard let index else {
                    plan.changes.append(.create(file))
                    continue
                }
                let current = live.remove(at: index)
                if current.definition.repository.caseInsensitiveCompare(file.definition.repository) != .orderedSame {
                    plan.errors.append("\(file.path): the repository can't be changed. Delete the file and add a new one instead.")
                    continue
                }
                let attributes = Self.changedAttributes(from: current.definition.attributes, to: file.definition.attributes)
                let environment = [("xcodeVersion", \WorkflowDefinition.xcodeVersion), ("macOsVersion", \WorkflowDefinition.macOsVersion)]
                    .filter { _, path in
                        guard let desired = file.definition[keyPath: path] else {
                            return false
                        }
                        return current.definition[keyPath: path]?.caseInsensitiveCompare(desired) != .orderedSame
                    }
                    .map(\.0)
                if attributes.isEmpty && environment.isEmpty {
                    plan.unchanged += 1
                } else {
                    plan.changes.append(.update(file, current, attributes: attributes, environment: environment))
                }
            }
            plan.changes += live.map { .delete($0) }
        }
        return plan
    }

    func apply(_ plan: SyncPlan, report: (String) -> Void) async throws {
        guard let environments = plan.environments else {
            throw ToolError.refused("The plan has no environments. Run plan before apply.")
        }
        report("## Xcode Cloud apply\n")
        for change in plan.changes {
            switch change {
            case .create(let file):
                let definition = file.definition
                let relationships: JSON = [
                    "product": ["data": ["type": "ciProducts", "id": file.product.id]],
                    "repository": ["data": ["type": "scmRepositories", "id": environments.repositoryID(definition.repository) ?? ""]],
                    "xcodeVersion": ["data": ["type": "ciXcodeVersions", "id": definition.xcodeVersion.flatMap(environments.xcodeID) ?? ""]],
                    "macOsVersion": ["data": ["type": "ciMacOsVersions", "id": definition.macOsVersion.flatMap(environments.macOSID) ?? ""]]
                ]
                let created = try await client.post("/v1/ciWorkflows", body: [
                    "data": ["type": "ciWorkflows", "attributes": definition.attributes.filter { !($0.value is NSNull) }, "relationships": relationships] as JSON
                ])
                report("- Created **\(definition.name)** in \(file.product.label), id `\((created["data"] as? JSON)?.id ?? "?")`")
            case .update(let file, let current, let attributes, let environment):
                var data: JSON = ["type": "ciWorkflows", "id": current.id]
                if !attributes.isEmpty {
                    data["attributes"] = Dictionary(uniqueKeysWithValues: attributes.map { ($0, file.definition.attributes[$0] ?? NSNull()) })
                }
                var relationships: JSON = [:]
                if environment.contains("xcodeVersion") {
                    relationships["xcodeVersion"] = ["data": ["type": "ciXcodeVersions", "id": file.definition.xcodeVersion.flatMap(environments.xcodeID) ?? ""]]
                }
                if environment.contains("macOsVersion") {
                    relationships["macOsVersion"] = ["data": ["type": "ciMacOsVersions", "id": file.definition.macOsVersion.flatMap(environments.macOSID) ?? ""]]
                }
                if !relationships.isEmpty {
                    data["relationships"] = relationships
                }
                _ = try await client.patch("/v1/ciWorkflows/\(current.id)", body: ["data": data])
                report("- Updated **\(file.definition.name)** in \(file.product.label): \((attributes + environment).joined(separator: ", "))")
            case .delete(let workflow):
                try await client.delete("/v1/ciWorkflows/\(workflow.id)")
                report("- Deleted **\(workflow.definition.name)** from \(workflow.product.label)")
            }
        }
        if plan.changes.isEmpty {
            report("Nothing to change.")
        }
    }

    // MARK: - Live workflows

    private func liveWorkflows(of product: Product) async throws -> [LiveWorkflow] {
        var workflows: [LiveWorkflow] = []
        for summary in try await client.getAll("/v1/ciProducts/\(product.id)/workflows", query: ["fields[ciWorkflows]": "name"]).data {
            let response = try await client.get("/v1/ciWorkflows/\(summary.id)", query: ["include": "xcodeVersion,macOsVersion,repository"])
            let data = response["data"] as? JSON ?? [:]
            let included = response["included"] as? [JSON] ?? []
            func includedName(_ relationship: String, attribute: String = "name") -> String? {
                data.relationshipID(relationship).flatMap { id in included.first { $0.id == id }?.string(attribute) }
            }
            let definition = WorkflowDefinition(
                id: data.id,
                repository: includedName("repository", attribute: "repositoryName") ?? "?",
                xcodeVersion: includedName("xcodeVersion"),
                macOsVersion: includedName("macOsVersion"),
                attributes: data.attributes
            )
            workflows.append(LiveWorkflow(product: product, definition: definition))
        }
        return workflows.sorted { $0.definition.name < $1.definition.name }
    }

    // MARK: - Files

    private func managedBundleIDs() throws -> [String] {
        guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
    }

    private func jsonFileNames(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            .filter { $0.hasSuffix(".json") }
            .sorted()
    }

    private func readFiles(in folder: URL, product: Product) throws -> [WorkflowFile] {
        var errors: [String] = []
        return try readFiles(in: folder, product: product, errors: &errors)
    }

    private func readFiles(in folder: URL, product: Product, errors: inout [String]) throws -> [WorkflowFile] {
        var files: [WorkflowFile] = []
        for name in try jsonFileNames(in: folder) {
            let path = "\(root.lastPathComponent)/\(folder.lastPathComponent)/\(name)"
            do {
                let data = try Data(contentsOf: folder.appending(path: name))
                guard let json = try JSONSerialization.jsonObject(with: data) as? JSON else {
                    throw ToolError.refused("not a JSON object")
                }
                files.append(WorkflowFile(path: path, product: product, definition: try WorkflowDefinition(fileJSON: json)))
            } catch {
                errors.append("\(path): \(error.localizedDescription)")
            }
        }
        return files
    }

    static func noProductMessage(bundleID: String, apps: [App]) -> String {
        if let app = apps.first(where: { $0.bundleID == bundleID }) {
            return """
            Xcode Cloud isn't set up for \(app.name) (\(bundleID)) yet.
            Create its first workflow by hand, which also connects the repository:
              - in Xcode: Product → Xcode Cloud → Create Workflow…
              - or in App Store Connect: the app → Xcode Cloud → Get Started
            The App Store Connect API can't create a product. Once the workflow exists, run `xcflow export \(bundleID)`.
            """
        }
        let known = apps.map(\.label).sorted()
        return "No app with bundle id \(bundleID) in this team. Check the bundle id, and that the key belongs to the right team. Apps: \(known.isEmpty ? "none" : known.joined(separator: ", "))."
    }

    /// The products named by the project's Xcode Cloud manifests, as bundle ids, with a line per manifest for the report.
    static func manifestProducts(in projectRoot: URL, products: [Product]) throws -> (bundleIDs: [String], lines: [String]) {
        let hint = "xcflow export com.example.app"
        var bundleIDs: Set<String> = []
        var lines: [String] = []
        var stale: [String] = []
        for manifest in try Manifests.find(in: projectRoot) {
            var found: [Product] = []
            for id in manifest.productIDs {
                if let product = products.first(where: { $0.id == id }) {
                    found.append(product)
                } else {
                    stale.append("\(manifest.path) names the product \(id), which App Store Connect doesn't have. The product was probably deleted.")
                }
            }
            if !found.isEmpty {
                bundleIDs.formUnion(found.map(\.bundleID))
                lines.append("Products in \(manifest.path): \(found.map(\.label).joined(separator: ", "))")
            }
        }
        guard !bundleIDs.isEmpty else {
            if stale.isEmpty {
                throw ToolError.notFound(Manifests.noManifestMessage(projects: Manifests.projects(in: projectRoot), root: projectRoot, hint: hint))
            }
            throw ToolError.notFound((stale + ["Pass the bundle id of the product to manage instead: \(hint)"]).joined(separator: "\n"))
        }
        return (bundleIDs.sorted(), lines + stale)
    }

    private func product(_ bundleID: String, in products: [Product]) async throws -> Product {
        guard let product = products.first(where: { $0.bundleID == bundleID }) else {
            throw ToolError.notFound(Self.noProductMessage(bundleID: bundleID, apps: try await client.apps()))
        }
        return product
    }

    // MARK: - Validation and diffing

    /// Errors in the files against the live catalog, and against the schemes the repo shares.
    static func validate(_ files: [WorkflowFile], _ environments: Environments, repo: URL) -> [String] {
        var errors: [String] = []
        for (name, group) in Dictionary(grouping: files, by: { $0.definition.name.lowercased() }) where group.count > 1 {
            errors.append("Several files use the workflow name \"\(name)\": \(group.map(\.path).joined(separator: ", "))")
        }
        for (id, group) in Dictionary(grouping: files.filter { $0.definition.id != nil }, by: { $0.definition.id ?? "" }) where group.count > 1 {
            errors.append("Several files use the workflow id \(id): \(group.map(\.path).joined(separator: ", "))")
        }
        for file in files {
            let definition = file.definition
            if definition.id == nil && (definition.xcodeVersion == nil || definition.macOsVersion == nil) {
                errors.append("\(file.path): a new workflow needs both xcodeVersion and macOsVersion.")
            }
            if definition.id == nil && (definition.attributes["description"] as? String ?? "").isEmpty {
                errors.append("\(file.path): a new workflow needs a description; App Store Connect refuses to create one without.")
            }
            if let xcodeVersion = definition.xcodeVersion, environments.xcodeID(xcodeVersion) == nil {
                let names = environments.xcodeVersions.compactMap { $0.string("name") }
                let latest = names.contains("Latest Release") ? " \"Latest Release\" follows Apple's newest release, so the file never goes stale." : ""
                errors.append("\(file.path): unknown Xcode version \"\(xcodeVersion)\". Available: \(names.joined(separator: ", ")).\(latest)")
            }
            if let macOsVersion = definition.macOsVersion, environments.macOSID(macOsVersion) == nil {
                errors.append("\(file.path): unknown macOS version \"\(macOsVersion)\". Available: \(environments.macOSVersions.compactMap { $0.string("name") }.joined(separator: ", "))")
            }
            if environments.repositoryID(definition.repository) == nil {
                errors.append("\(file.path): unknown repository \"\(definition.repository)\".")
            }
            if let xcode = definition.xcodeVersion, let macOS = definition.macOsVersion,
               let xcodeID = environments.xcodeID(xcode), let macOSID = environments.macOSID(macOS),
               let compatible = environments.macOSIDs(forXcode: xcodeID), !compatible.contains(macOSID) {
                let names = environments.macOSVersions.filter { compatible.contains($0.id) }.compactMap { $0.string("name") }
                errors.append("\(file.path): \(xcode) doesn't run on \(macOS). With \(xcode), use: \(names.joined(separator: ", ")).")
            }
            errors += schemeErrors(in: file, repo: repo)
        }
        return errors.sorted()
    }

    /// Each action's scheme against the shared schemes of the workflow's container. A container that isn't checked in, such as a generated project, or that isn't a project or workspace, isn't checked.
    private static func schemeErrors(in file: WorkflowFile, repo: URL) -> [String] {
        guard let container = file.definition.attributes["containerFilePath"] as? String,
              FileManager.default.fileExists(atPath: repo.appending(path: container).path(percentEncoded: false)),
              let shared = Schemes.shared(in: repo.appending(path: container))
        else {
            return []
        }
        let userOnly = Schemes.userOnly(in: repo.appending(path: container))
        return (file.definition.attributes["actions"] as? [JSON] ?? []).compactMap { action in
            guard let scheme = action["scheme"] as? String, !shared.contains(scheme) else {
                return nil
            }
            let name = action["name"] as? String ?? "?"
            if userOnly.contains(scheme) {
                return "\(file.path): action \"\(name)\" uses the scheme \"\(scheme)\", which isn't shared in \(container), so Xcode Cloud can't see it. Tick Shared for it in Xcode (Product → Scheme → Manage Schemes…) and commit its .xcscheme file."
            }
            return "\(file.path): action \"\(name)\" uses the scheme \"\(scheme)\", which \(container) doesn't share. Shared schemes: \(shared.isEmpty ? "none" : shared.joined(separator: ", "))."
        }
    }

    static func changedAttributes(from current: JSON, to desired: JSON) -> [String] {
        Set(current.keys).union(desired.keys)
            .filter { !WorkflowDefinition.readOnlyAttributes.contains($0) }
            .filter { canonical(current[$0]) != canonical(desired[$0]) }
            .sorted()
    }

    struct Difference: Equatable {
        let path: String
        let before: String
        let after: String

        var markdown: [String] {
            guard before.count + after.count > 120 else {
                return ["- `\(path)`: `\(before)` → `\(after)`"]
            }
            return ["- `\(path)`:", "  ```", "  before: \(before)", "  after:  \(after)", "  ```"]
        }
    }

    static func differences(_ before: Any?, _ after: Any?, path: String) -> [Difference] {
        if let before = before as? JSON, let after = after as? JSON {
            return Set(before.keys).union(after.keys).sorted().flatMap { key in
                differences(before[key], after[key], path: "\(path).\(key)")
            }
        }
        if let before = before as? [Any], let after = after as? [Any], before.count == after.count {
            return before.indices.flatMap { index in
                differences(before[index], after[index], path: "\(path)[\(index)]")
            }
        }
        let beforeText = canonical(before)
        let afterText = canonical(after)
        return beforeText == afterText ? [] : [Difference(path: path, before: beforeText, after: afterText)]
    }

    static func canonical(_ value: Any?) -> String {
        let value = value ?? NSNull()
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) else {
            return "\(value)"
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func encode(_ json: JSON) throws -> Data {
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
    }

    static func slug(_ name: String) -> String {
        let slug = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return slug.isEmpty ? "workflow" : slug
    }
}

extension SyncPlan {
    var markdown: String {
        var lines = ["## Xcode Cloud plan", ""]
        guard errors.isEmpty else {
            lines.append("**The workflow files are invalid. Nothing will change until these are fixed:**")
            lines += errors.map { "- \($0)" }
            return lines.joined(separator: "\n")
        }
        let creates = changes.filter { if case .create = $0 { true } else { false } }.count
        let deletes = changes.filter { if case .delete = $0 { true } else { false } }.count
        lines.append("**\(creates) to create, \(changes.count - creates - deletes) to update, \(deletes) to delete, \(unchanged) unchanged.**")
        for change in changes {
            lines.append("")
            switch change {
            case .create(let file):
                lines.append("### Create: \(file.definition.name) (\(file.product.label))")
                lines.append("From `\(file.path)`.")
            case .update(let file, let current, let attributes, let environment):
                lines.append("### Update: \(file.definition.name) (\(file.product.label))")
                if current.isLockedForEditing {
                    lines.append(LiveWorkflow.lockedWarning)
                }
                for key in environment {
                    let path: KeyPath<WorkflowDefinition, String?> = key == "xcodeVersion" ? \.xcodeVersion : \.macOsVersion
                    lines.append("- `\(key)`: \(current.definition[keyPath: path] ?? "none") → \(file.definition[keyPath: path] ?? "none")")
                }
                for key in attributes {
                    for difference in WorkflowSync.differences(current.definition.attributes[key], file.definition.attributes[key], path: key) {
                        lines += difference.markdown
                    }
                }
            case .delete(let workflow):
                lines.append("### ⚠️ Delete: \(workflow.definition.name) (\(workflow.product.label))")
                if workflow.isLockedForEditing {
                    lines.append(LiveWorkflow.lockedWarning)
                }
                lines.append("No file defines this workflow any more. Deleting it also deletes its build history.")
            }
        }
        return lines.joined(separator: "\n")
    }
}
