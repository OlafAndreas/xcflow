import Foundation
import MCP

let arguments = Array(CommandLine.arguments.dropFirst())

func runOrExit(_ name: String, _ work: () async throws -> Void) async -> Never {
    do {
        try await work()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(name) failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

switch arguments.first {
case nil:
    break
case "--version", "version":
    print(Version.current)
    exit(0)
case "auth":
    await runOrExit("auth") { try await Auth.run(arguments: Array(arguments.dropFirst())) }
case "setup":
    await runOrExit("setup") { _ = try await RepoSetup.run(arguments: Array(arguments.dropFirst())) }
case "get" where arguments.count >= 2:
    await runOrExit("get") {
        let client = AppStoreConnectClient(tokens: try TokenProvider(credentials: try loadKey(root: nil)))
        let query = Dictionary(uniqueKeysWithValues: arguments.dropFirst(2).compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        })
        let response = try await client.get(arguments[1], query: query)
        let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
case "export", "plan", "apply":
    exit(await SyncCommand.run(arguments[0], arguments: Array(arguments.dropFirst())))
case "builds", "build", "logs", "run":
    exit(await BuildCommand.run(arguments[0], arguments: Array(arguments.dropFirst())))
default:
    FileHandle.standardError.write(Data(Usage.text.utf8))
    exit(arguments.first == "help" || arguments.first == "--help" ? 0 : 64)
}

let server = Server(
    name: "xcflow",
    version: Version.current,
    capabilities: .init(tools: .init(listChanged: false))
)
let apps = AppSelection(server: server)
let tools = XcodeCloudTools(apps: apps)

await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: MCPTools.definitions)
}

await server.withMethodHandler(CallTool.self) { params in
    do {
        let text = try await tools.call(params.name, arguments: params.arguments ?? [:])
        return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    } catch {
        return CallTool.Result(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
    }
}

try await server.start(transport: StdioTransport()) { _, capabilities in
    await apps.clientConnected(capabilities)
}
await server.waitUntilCompleted()
