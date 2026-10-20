import Foundation

// The `uses:` line through which a generated workflow installs xcflow from the published action. A pin names the action's version and, when known, the commit that version points to.
struct ActionPin: Equatable {
    static let repository = "OlafAndreas/xcflow-action"

    let version: String
    let commit: String?

    /// The value after `uses:`. A commit pin carries its version as a trailing comment.
    var uses: String {
        if let commit {
            return "\(Self.repository)@\(commit) # v\(version)"
        }
        return "\(Self.repository)@v\(version)"
    }

    /// The pin a whole workflow file installs xcflow with, or nil when it uses something else.
    static func parse(_ workflow: String) -> ActionPin? {
        let pattern = /OlafAndreas\/xcflow-action@(?:([0-9a-f]{40}) # v(\d+(?:\.\d+)*)|v(\d+(?:\.\d+)*))/
        guard let match = workflow.firstMatch(of: pattern) else {
            return nil
        }
        if let commit = match.1, let version = match.2 {
            return ActionPin(version: String(version), commit: String(commit))
        }
        if let version = match.3 {
            return ActionPin(version: String(version), commit: nil)
        }
        return nil
    }

    /// Whether `version` is later than `other`, comparing dotted numbers part by part.
    static func isNewer(_ version: String, than other: String) -> Bool {
        let lhs = version.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = other.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(lhs.count, rhs.count)
        let padded = { (parts: [Int]) in parts + Array(repeating: 0, count: count - parts.count) }
        return padded(rhs).lexicographicallyPrecedes(padded(lhs))
    }
}
