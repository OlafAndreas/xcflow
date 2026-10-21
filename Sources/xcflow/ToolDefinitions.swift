import MCP

private enum Schema {
    static let workflow: Value = [
        "type": "string",
        "description": "Workflow id or exact name, e.g. \"Publish to TestFlight\". If the name exists in several products, the error lists the ids to use."
    ]

    static let build: Value = [
        "type": "string",
        "description": "Build number (e.g. 60282) or build run id."
    ]
}

struct ChooseAppsTool: MCPTool {
    static let definition = Tool(
        name: "choose_apps",
        description: "Choose which apps the Xcode Cloud tools show; the others are hidden from every tool. Without `apps`, the user picks them in a form. The choice is saved per repo on this machine; without one, the tools show the apps in the repo's XcodeCloud/ folders.",
        inputSchema: [
            "type": "object",
            "properties": [
                "apps": ["type": "array", "items": ["type": "string"], "description": "App names to show, e.g. [\"My App\"]. Omit to let the user pick."]
            ]
        ],
        annotations: .init(destructiveHint: false, idempotentHint: true)
    )

    static func run(_ tools: XcodeCloudTools, _ client: AppStoreConnectClient, _ arguments: Arguments) async throws -> String {
        try await tools.chooseApps(client, apps: arguments.strings("apps"))
    }
}

struct ListWorkflowsTool: MCPTool {
    static let definition = Tool(
        name: "list_workflows",
        description: "List Xcode Cloud workflows, grouped by product (app and bundle id).",
        inputSchema: [
            "type": "object",
            "properties": [
                "product": ["type": "string", "description": "Only this product: bundle id (e.g. com.example.app) or product name."]
            ]
        ],
        annotations: .init(readOnlyHint: true)
    )

    static func run(_ tools: XcodeCloudTools, _ client: AppStoreConnectClient, _ arguments: Arguments) async throws -> String {
        try await tools.listWorkflows(client, product: arguments.string("product"))
    }
}

struct ListBuildsTool: MCPTool {
    static let definition = Tool(
        name: "list_builds",
        description: "List the most recent Xcode Cloud builds, newest first, with status, workflow and branch.",
        inputSchema: [
            "type": "object",
            "properties": [
                "workflow": Schema.workflow,
                "branch": ["type": "string", "description": "Only builds of this branch or tag name."],
                "limit": ["type": "integer", "description": "Maximum number of builds to return. Default 10."]
            ]
        ],
        annotations: .init(readOnlyHint: true)
    )

    static func run(_ tools: XcodeCloudTools, _ client: AppStoreConnectClient, _ arguments: Arguments) async throws -> String {
        try await tools.builds.listBuilds(
            client,
            workflow: arguments.string("workflow"),
            branch: arguments.string("branch"),
            limit: arguments.int("limit") ?? 10
        )
    }
}

struct GetBuildTool: MCPTool {
    static let definition = Tool(
        name: "get_build",
        description: "Summarize one build: status, branch, commit, each action's result, compiler errors and failing tests.",
        inputSchema: [
            "type": "object",
            "properties": ["build": Schema.build],
            "required": ["build"]
        ],
        annotations: .init(readOnlyHint: true)
    )

    static func run(_ tools: XcodeCloudTools, _ client: AppStoreConnectClient, _ arguments: Arguments) async throws -> String {
        try await tools.builds.getBuild(client, build: try arguments.required("build"))
    }
}

struct GetBuildLogsTool: MCPTool {
    static let definition = Tool(
        name: "get_build_logs",
        description: "Download a build's log bundles and return the error and failure lines, plus the local folder with the full logs.",
        inputSchema: [
            "type": "object",
            "properties": [
                "build": Schema.build,
                "action": ["type": "string", "description": "Action name, e.g. \"Test - iOS\". Default: every failed action, or all actions if none failed."]
            ],
            "required": ["build"]
        ],
        annotations: .init(readOnlyHint: true)
    )

    static func run(_ tools: XcodeCloudTools, _ client: AppStoreConnectClient, _ arguments: Arguments) async throws -> String {
        try await tools.builds.getBuildLogs(client, build: try arguments.required("build"), action: arguments.string("action"))
    }
}

struct StartBuildTool: MCPTool {
    static let definition = Tool(
        name: "start_build",
        description: "Start a build of a workflow on a branch or tag.",
        inputSchema: [
            "type": "object",
            "properties": [
                "workflow": Schema.workflow,
                "branch": ["type": "string", "description": "Branch or tag name, e.g. feature/new-onboarding."],
                "clean": ["type": "boolean", "description": "Clean build. Default: the workflow's setting."]
            ],
            "required": ["workflow", "branch"]
        ],
        annotations: .init(destructiveHint: false, idempotentHint: false)
    )

    static func run(_ tools: XcodeCloudTools, _ client: AppStoreConnectClient, _ arguments: Arguments) async throws -> String {
        try await tools.builds.startBuild(
            client,
            workflow: try arguments.required("workflow"),
            branch: try arguments.required("branch"),
            clean: arguments.bool("clean")
        )
    }
}

struct GetWorkflowTool: MCPTool {
    static let definition = Tool(
        name: "get_workflow",
        description: "Show a workflow's live configuration in Xcode Cloud and the file in XcodeCloud/ that defines it. To change a workflow, edit that file and open a PR; there is no tool that writes workflows.",
        inputSchema: [
            "type": "object",
            "properties": ["workflow": Schema.workflow],
            "required": ["workflow"]
        ],
        annotations: .init(readOnlyHint: true)
    )

    static func run(_ tools: XcodeCloudTools, _ client: AppStoreConnectClient, _ arguments: Arguments) async throws -> String {
        try await tools.getWorkflow(client, workflow: try arguments.required("workflow"))
    }
}

struct ListEnvironmentsTool: MCPTool {
    static let definition = Tool(
        name: "list_environments",
        description: "List the Xcode and macOS versions Xcode Cloud offers, by the names the workflow files in XcodeCloud/ use.",
        inputSchema: ["type": "object", "properties": [:]],
        annotations: .init(readOnlyHint: true)
    )

    static func run(_ tools: XcodeCloudTools, _ client: AppStoreConnectClient, _ arguments: Arguments) async throws -> String {
        try await tools.listEnvironments(client)
    }
}
