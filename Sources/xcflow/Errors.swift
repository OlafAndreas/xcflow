import Foundation

enum ToolError: LocalizedError {
    case unknownTool(String)
    case missingArgument(String)
    case notFound(String)
    case ambiguous(String)
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): "Unknown tool: \(name)"
        case .missingArgument(let name): "Missing required argument `\(name)`."
        case .notFound(let message), .ambiguous(let message), .refused(let message): message
        }
    }
}
