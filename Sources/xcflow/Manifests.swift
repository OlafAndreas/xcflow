import Foundation

// Xcode writes this file into a project when it creates the project's first Xcode Cloud workflow. Each target entry is one Xcode Cloud product, by its App Store Connect id.
struct XcodeCloudManifest: Equatable {
    static let relativePath = "xcshareddata/xcodecloud/manifest.json"

    let project: String
    let productIDs: [String]

    var path: String {
        "\(project)/\(Self.relativePath)"
    }
}

enum Manifests {
    // Other people's projects and build output. Hidden folders such as .build are skipped as well.
    private static let skipped: Set<String> = ["Pods", "Carthage", "DerivedData", "node_modules", "build", "XcodeCloud"]

    /// Every Xcode project under `root`, as paths relative to it.
    static func projects(in root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        // The enumerator resolves symlinks, e.g. /var to /private/var, so the root has to be resolved the same way.
        let base = root.resolvingSymlinksInPath().path(percentEncoded: false).replacing(/\/$/, with: "")
        var projects: [String] = []
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if url.pathExtension == "xcodeproj" {
                let path = url.resolvingSymlinksInPath().path(percentEncoded: false).replacing(/\/$/, with: "")
                projects.append(String(path.dropFirst(base.count)).replacing(/^\//, with: ""))
                enumerator.skipDescendants()
            } else if skipped.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
            }
        }
        return projects.sorted()
    }

    /// The Xcode Cloud manifests of those projects that have one.
    static func find(in root: URL) throws -> [XcodeCloudManifest] {
        try projects(in: root).compactMap { project in
            let url = root.appending(path: "\(project)/\(XcodeCloudManifest.relativePath)")
            guard let data = try? Data(contentsOf: url) else {
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? JSON, let targets = json["targets"] as? [JSON] else {
                throw ToolError.refused("\(project)/\(XcodeCloudManifest.relativePath) is not an Xcode Cloud manifest.")
            }
            return XcodeCloudManifest(project: project, productIDs: targets.compactMap { $0["id"] as? String })
        }
    }

    static func noManifestMessage(projects: [String], root: URL, hint: String) -> String {
        guard !projects.isEmpty else {
            return "No Xcode project found under \(root.path(percentEncoded: false)). Run xcflow from the repo root, or pass the bundle id: \(hint)"
        }
        return """
        No Xcode Cloud manifest (\(XcodeCloudManifest.relativePath)) found in \(projects.joined(separator: ", ")).
        Xcode Cloud isn't set up for this project yet. Create its first workflow by hand, which also connects the repository:
          - in Xcode: Product → Xcode Cloud → Create Workflow…
          - or in App Store Connect: the app → Xcode Cloud → Get Started
        The App Store Connect API can't create a product. If you create it in App Store Connect, open the project in Xcode once afterwards so it writes the manifest. Or pass the bundle id: \(hint)
        """
    }
}
