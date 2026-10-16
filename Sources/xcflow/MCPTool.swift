import MCP

protocol MCPTool: SendableMetatype {
    static var definition: Tool { get }
    static func run(_ tools: XcodeCloudTools, _ client: AppStoreConnectClient, _ arguments: Arguments) async throws -> String
}

enum MCPTools {
    static let all: [any MCPTool.Type] = [
        ChooseAppsTool.self,
        ListWorkflowsTool.self,
        ListBuildsTool.self,
        GetBuildTool.self,
        GetBuildLogsTool.self,
        StartBuildTool.self,
        GetWorkflowTool.self,
        ListEnvironmentsTool.self
    ]

    static let definitions: [Tool] = all.map { $0.definition }

    static let byName: [String: any MCPTool.Type] = Dictionary(uniqueKeysWithValues: all.map { ($0.definition.name, $0) })
}
