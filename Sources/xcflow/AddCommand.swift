import Foundation

/// `xcflow add <preset>`: writes a new workflow file, copying the repository, container, versions and platform from a workflow file already in the product's folder.
enum AddCommand {
    static let usage = "Usage: xcflow add <\(Preset.allCases.map(\.rawValue).joined(separator: " | "))> [--product <bundle id>] [--scheme <name>] [--name <workflow name>] [--root <folder>]"

    enum Preset: String, CaseIterable {
        case prChecks = "pr-checks"
        case nightlyTests = "nightly-tests"
        case testflightOnTag = "testflight-on-tag"

        var defaultName: String {
            switch self {
            case .prChecks: "PR checks"
            case .nightlyTests: "Nightly tests"
            case .testflightOnTag: "TestFlight on tag"
            }
        }
    }

    /// 0 ok, 2 error, 64 usage.
    static func run(
        arguments: [String],
        timeZone: TimeZone = .current,
        out: (String) -> Void = { print($0) },
        err: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) -> Int32 {
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
        let product = value(of: "--product")
        let scheme = value(of: "--scheme")
        let name = value(of: "--name")
        let root = URL(filePath: value(of: "--root") ?? "XcodeCloud", directoryHint: .isDirectory, relativeTo: URL.currentDirectory()).standardizedFileURL
        guard rest.count == 1, let preset = Preset(rawValue: rest[0]) else {
            err(usage)
            return 64
        }
        do {
            let written = try add(preset, root: root, product: product, scheme: scheme, name: name, timeZone: timeZone)
            out(written.joined(separator: "\n"))
            return 0
        } catch {
            err(error.localizedDescription)
            return 2
        }
    }

    /// Writes the preset's file and returns what to tell the developer.
    static func add(_ preset: Preset, root: URL, product: String?, scheme: String?, name: String?, timeZone: TimeZone) throws -> [String] {
        let folder = try productFolder(root: root, requested: product)
        let existing = try workflows(in: folder)
        guard let reference = existing.first(where: { $0.attributes["containerFilePath"] is String }) else {
            throw ToolError.refused("\(display(folder)) has no workflow file to copy the repository and project from. Run xcflow export first.")
        }
        let name = name ?? preset.defaultName
        if let clash = existing.first(where: { $0.name.lowercased() == name.lowercased() }) {
            throw ToolError.refused("\(display(folder)) already has a workflow named \"\(clash.name)\". Pick another with --name.")
        }
        let file = folder.appending(path: "\(WorkflowSync.slug(name)).json")
        guard !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
            throw ToolError.refused("\(display(file)) already exists. Pick another name with --name.")
        }

        let container = reference.attributes["containerFilePath"] as? String ?? ""
        let referenceActions = reference.attributes["actions"] as? [JSON] ?? []
        let platform = referenceActions.first?["platform"] as? String ?? "IOS"
        let scheme = try scheme ?? pickScheme(container: root.deletingLastPathComponent().appending(path: container), used: referenceActions.first?["scheme"] as? String)
        let label = platformLabels[platform] ?? platform

        var attributes: JSON = [
            "name": name,
            "description": "",
            "containerFilePath": container,
            "isEnabled": true,
            "isLockedForEditing": false,
            "clean": preset != .prChecks,
            "branchStartCondition": NSNull(),
            "pullRequestStartCondition": NSNull(),
            "tagStartCondition": NSNull(),
            "scheduledStartCondition": NSNull(),
            "manualBranchStartCondition": NSNull(),
            "manualPullRequestStartCondition": NSNull(),
            "manualTagStartCondition": NSNull(),
        ]
        let summary: String
        switch preset {
        case .prChecks:
            attributes["pullRequestStartCondition"] = [
                "source": allBranches,
                "destination": allBranches,
                "autoCancel": true,
                "filesAndFoldersRule": NSNull(),
            ] as JSON
            attributes["actions"] = [try testAction(scheme: scheme, platform: platform, existing: existing)]
            summary = "tests \(scheme) on \(label) for every pull request"
        case .nightlyTests:
            let branch = defaultBranch(of: existing)
            attributes["scheduledStartCondition"] = [
                "source": ["isAllMatch": false, "patterns": [["pattern": branch, "isPrefix": false]]],
                "schedule": ["frequency": "DAILY", "days": [String](), "hour": 3, "minute": 0, "timezone": timeZone.identifier],
            ] as JSON
            attributes["actions"] = [try testAction(scheme: scheme, platform: platform, existing: existing)]
            summary = "tests \(scheme) on \(label) from \(branch) every night at 03:00 \(timeZone.identifier)"
        case .testflightOnTag:
            attributes["tagStartCondition"] = [
                "source": ["isAllMatch": false, "patterns": [["pattern": "v", "isPrefix": true]]],
                "autoCancel": true,
                "filesAndFoldersRule": NSNull(),
            ] as JSON
            attributes["actions"] = [[
                "actionType": "ARCHIVE",
                "name": "Archive - \(label)",
                "platform": platform,
                "scheme": scheme,
                "destination": archiveDestinations[platform] ?? NSNull(),
                "buildDistributionAudience": "APP_STORE_ELIGIBLE",
                "isRequiredToPass": true,
                "testConfiguration": NSNull(),
            ] as JSON]
            summary = "archives \(scheme) for \(label) when a tag starting with v is pushed"
        }

        let definition = WorkflowDefinition(id: nil, repository: reference.repository, xcodeVersion: reference.xcodeVersion, macOsVersion: reference.macOsVersion, attributes: attributes)
        try WorkflowSync.encode(definition.fileJSON).write(to: file)

        var lines = [
            "Wrote \(display(file)): \"\(name)\" \(summary).",
            "Check it with xcflow plan, then commit it. The workflow is created when the change reaches the default branch.",
        ]
        if preset == .testflightOnTag {
            lines.append("The App Store Connect API can't add post-actions. Once the workflow exists, add a TestFlight post-action to it in Xcode or App Store Connect so each archive reaches your testers.")
        }
        return lines
    }

    private static let platformLabels = ["IOS": "iOS", "MACOS": "macOS", "TVOS": "tvOS", "WATCHOS": "watchOS", "VISIONOS": "visionOS"]
    private static let archiveDestinations = ["IOS": "ANY_IOS_DEVICE", "MACOS": "ANY_MAC", "TVOS": "ANY_TVOS_DEVICE", "WATCHOS": "ANY_WATCHOS_DEVICE", "VISIONOS": "ANY_VISIONOS_DEVICE"]
    private static var allBranches: JSON { ["isAllMatch": true, "patterns": [JSON]()] }

    /// The path from the repo, e.g. `XcodeCloud/com.example.app/pr-checks.json`.
    private static func display(_ url: URL) -> String {
        let components = url.standardizedFileURL.pathComponents
        guard let index = components.lastIndex(of: "XcodeCloud") else {
            return url.path(percentEncoded: false)
        }
        return components[index...].joined(separator: "/")
    }

    private static func productFolder(root: URL, requested: String?) throws -> URL {
        let folders = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let requested {
            guard let folder = folders.first(where: { $0.lastPathComponent == requested }) else {
                throw ToolError.refused("\(display(root)) has no folder for \(requested). Products here: \(folders.map(\.lastPathComponent).joined(separator: ", ")).")
            }
            return folder
        }
        switch folders.count {
        case 0:
            throw ToolError.refused("\(display(root)) has no product folders. Run xcflow setup or xcflow export first.")
        case 1:
            return folders[0]
        default:
            throw ToolError.refused("\(display(root)) has several products. Pick one with --product: \(folders.map(\.lastPathComponent).joined(separator: ", ")).")
        }
    }

    private static func workflows(in folder: URL) throws -> [WorkflowDefinition] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? JSON else {
                    return nil
                }
                return try? WorkflowDefinition(fileJSON: json)
            }
    }

    /// The scheme the existing workflow uses when the project still shares it, else the project's only shared scheme.
    private static func pickScheme(container: URL, used: String?) throws -> String {
        guard FileManager.default.fileExists(atPath: container.path(percentEncoded: false)), let shared = Schemes.shared(in: container) else {
            guard let used else {
                throw ToolError.refused("Couldn't read the schemes of \(container.lastPathComponent). Name one with --scheme.")
            }
            return used
        }
        if let used, shared.contains(used) {
            return used
        }
        guard shared.count == 1 else {
            throw ToolError.refused(shared.isEmpty
                ? "\(container.lastPathComponent) shares no schemes, and Xcode Cloud only builds shared ones. Tick Shared for one in Xcode (Product → Scheme → Manage Schemes…) and commit its .xcscheme file."
                : "\(container.lastPathComponent) shares several schemes. Pick one with --scheme: \(shared.joined(separator: ", ")).")
        }
        return shared[0]
    }

    /// A test action using the test destinations of an existing test action, or the newest iPhone simulator for iOS.
    private static func testAction(scheme: String, platform: String, existing: [WorkflowDefinition]) throws -> JSON {
        let existingTest = existing.lazy
            .flatMap { $0.attributes["actions"] as? [JSON] ?? [] }
            .first { $0["actionType"] as? String == "TEST" && $0["platform"] as? String == platform && $0["testConfiguration"] is JSON }
        let configuration: Any
        if let existingTest, let copied = existingTest["testConfiguration"] {
            configuration = copied
        } else if platform == "IOS" {
            configuration = [
                "kind": "USE_SCHEME_SETTINGS",
                "testDestinations": [[
                    "kind": "SIMULATOR",
                    "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
                    "runtimeIdentifier": "default",
                ]],
            ] as JSON
        } else {
            throw ToolError.refused("No \(platformLabels[platform] ?? platform) test action to copy test destinations from. Add one to an existing workflow in Xcode, run xcflow export, then try again.")
        }
        return [
            "actionType": "TEST",
            "name": "Test - \(platformLabels[platform] ?? platform)",
            "platform": platform,
            "scheme": scheme,
            "destination": NSNull(),
            "buildDistributionAudience": NSNull(),
            "isRequiredToPass": true,
            "testConfiguration": configuration,
        ]
    }

    /// The exact branch an existing workflow starts from or schedules, else main.
    private static func defaultBranch(of existing: [WorkflowDefinition]) -> String {
        for definition in existing {
            for key in ["branchStartCondition", "scheduledStartCondition"] {
                let patterns = ((definition.attributes[key] as? JSON)?["source"] as? JSON)?["patterns"] as? [JSON] ?? []
                if let exact = patterns.first(where: { $0["isPrefix"] as? Bool == false }), let branch = exact["pattern"] as? String {
                    return branch
                }
            }
        }
        return "main"
    }
}
