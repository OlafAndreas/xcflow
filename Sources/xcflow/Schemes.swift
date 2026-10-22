import Foundation

/// The schemes in a project or workspace. Xcode Cloud builds only shared ones, from `xcshareddata/xcschemes`.
enum Schemes {
    /// The shared scheme names of an .xcodeproj, or of an .xcworkspace and the projects it references. Nil for any other container, such as a package.
    static func shared(in container: URL) -> [String]? {
        switch container.pathExtension {
        case "xcodeproj":
            return names(in: container.appending(path: "xcshareddata/xcschemes"))
        case "xcworkspace":
            let projects = referencedProjects(of: container).flatMap { names(in: $0.appending(path: "xcshareddata/xcschemes")) }
            return Array(Set(names(in: container.appending(path: "xcshareddata/xcschemes")) + projects)).sorted()
        default:
            return nil
        }
    }

    /// Scheme names kept only in someone's `xcuserdata`, which Xcode Cloud never sees.
    static func userOnly(in container: URL) -> [String] {
        let users = (try? FileManager.default.contentsOfDirectory(at: container.appending(path: "xcuserdata"), includingPropertiesForKeys: nil)) ?? []
        return Array(Set(users.flatMap { names(in: $0.appending(path: "xcschemes")) })).sorted()
    }

    private static func names(in folder: URL) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return files.filter { $0.hasSuffix(".xcscheme") }.map { String($0.dropLast(".xcscheme".count)) }.sorted()
    }

    /// The projects in `contents.xcworkspacedata`, resolved from the workspace's folder.
    private static func referencedProjects(of workspace: URL) -> [URL] {
        guard let text = try? String(contentsOf: workspace.appending(path: "contents.xcworkspacedata"), encoding: .utf8) else {
            return []
        }
        return text.matches(of: /location\s*=\s*"(?:group|container):([^"]+\.xcodeproj)"/).map { match in
            workspace.deletingLastPathComponent().appending(path: String(match.1), directoryHint: .isDirectory)
        }
    }
}
