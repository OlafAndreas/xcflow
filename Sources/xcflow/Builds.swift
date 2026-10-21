import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The products a caller may see. The MCP server scopes to the apps chosen with choose_apps.
typealias ProductScope = @Sendable (AppStoreConnectClient) async throws -> [Product]

/// Build lookups and actions, shared by the MCP tools and the CLI.
struct Builds: Sendable {
    let scope: ProductScope
    /// Ends the "No workflow matches" error: the MCP server points at list_workflows, the CLI at the workflow files.
    var workflowHint = "Use list_workflows to see the names."
}

extension XcodeCloudTools {
    var builds: Builds {
        Builds { [apps] client in
            let all = try await client.products()
            let chosen = try await apps.chosenApps(from: Self.appNames(of: all))
            return all.filter { chosen.contains($0.name) }
        }
    }
}

enum WaitError: Error, Equatable {
    case timedOut(number: String, runID: String, minutes: Int)
    case lostContact(number: String, runID: String)
}

extension Builds {
    /// Polls GET /v1/ciBuildRuns/<id> until the run is COMPLETE and returns its completionStatus.
    /// Calls `progress` once per change of executionProgress and once for the finished line.
    /// Failed polls are ridden out until they have lasted `contactLimit` without a success.
    /// `number`, when known, names the build in the lines and errors until a poll returns it.
    func wait(
        _ client: AppStoreConnectClient, runID: String, number initialNumber: String? = nil, every: Duration, timeout: Duration, contactLimit: Duration,
        progress: @Sendable (String) -> Void
    ) async throws -> String {
        let clock = ContinuousClock()
        let start = clock.now
        var lastContact = start
        var number = initialNumber ?? runID
        var reported: String?
        while true {
            do {
                let response = try await client.get("/v1/ciBuildRuns/\(runID)", query: ["fields[ciBuildRuns]": "number,executionProgress,completionStatus,startedDate,finishedDate"])
                let attributes = (response["data"] as? JSON ?? [:]).attributes
                lastContact = clock.now
                if let value = attributes["number"] {
                    number = "\(value)"
                }
                let state = attributes["executionProgress"] as? String ?? ""
                if state == "COMPLETE" {
                    let status = attributes["completionStatus"] as? String ?? "UNKNOWN"
                    let duration = Format.duration(from: attributes["startedDate"], to: attributes["finishedDate"]).map { " (\($0))" } ?? ""
                    progress("Build #\(number) finished: \(status)\(duration)")
                    return status
                }
                if state != reported {
                    reported = state
                    switch state {
                    case "PENDING": progress("Build #\(number) queued")
                    case "RUNNING": progress("Build #\(number) running")
                    default: break
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                if clock.now - lastContact >= contactLimit {
                    throw WaitError.lostContact(number: number, runID: runID)
                }
            }
            if clock.now - start >= timeout {
                throw WaitError.timedOut(number: number, runID: runID, minutes: Int(timeout.components.seconds / 60))
            }
            try await Task.sleep(for: every)
        }
    }
}
