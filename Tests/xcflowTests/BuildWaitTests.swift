import Foundation
import Testing
@testable import xcflow

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func add(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(line)
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

extension CannedAPISuites {
    @Suite struct BuildWaitTests {
        private let builds = Builds(scope: { _ in [] })
        private static let key = "GET /v1/ciBuildRuns/run-12"

        private static func poll(_ progress: String, status: String? = nil) -> CannedResponse {
            var attributes: [String: Any] = ["number": 12, "executionProgress": progress]
            if let status {
                attributes["completionStatus"] = status
                attributes["startedDate"] = "2026-10-20T10:00:00Z"
                attributes["finishedDate"] = "2026-10-20T10:12:00Z"
            }
            return .json(["data": ["type": "ciBuildRuns", "id": "run-12", "attributes": attributes]])
        }

        private func wait(_ table: [CannedResponse], number: String? = nil, timeout: Duration = .seconds(5), contactLimit: Duration = .seconds(5), lines: Lines) async throws -> String {
            CannedAPI.reset([Self.key: table])
            return try await builds.wait(try CannedAPI.client(), runID: "run-12", number: number, every: .milliseconds(1), timeout: timeout, contactLimit: contactLimit) { lines.add($0) }
        }

        @Test func waitReportsEachChangeAndReturnsTheStatus() async throws {
            let lines = Lines()
            let status = try await wait([Self.poll("PENDING"), Self.poll("PENDING"), Self.poll("RUNNING"), Self.poll("COMPLETE", status: "SUCCEEDED")], lines: lines)
            #expect(status == "SUCCEEDED")
            #expect(lines.all.count == 3)
            #expect(lines.all.prefix(2) == ["Build #12 queued", "Build #12 running"])
            #expect(lines.all.last?.hasPrefix("Build #12 finished: SUCCEEDED (") == true)
        }

        @Test func aFinishedBuildReturnsAtOnce() async throws {
            let lines = Lines()
            let status = try await wait([Self.poll("COMPLETE", status: "FAILED")], lines: lines)
            #expect(status == "FAILED")
            #expect(lines.all.count == 1)
        }

        @Test func aFailedPollIsRiddenOut() async throws {
            let lines = Lines()
            let status = try await wait(Array(repeating: .status(500), count: 4) + [Self.poll("COMPLETE", status: "SUCCEEDED")], lines: lines)
            #expect(status == "SUCCEEDED")
        }

        @Test func failingFromTheFirstPollLosesContact() async throws {
            let lines = Lines()
            do {
                _ = try await wait([.status(500)], contactLimit: .milliseconds(20), lines: lines)
                Issue.record("Expected lostContact")
            } catch let error as WaitError {
                #expect(error == .lostContact(number: "run-12", runID: "run-12"))
            }
        }

        @Test func aKnownNumberIsUsedUntilAPollSucceeds() async throws {
            let lines = Lines()
            do {
                _ = try await wait([.status(500)], number: "12", contactLimit: .milliseconds(20), lines: lines)
                Issue.record("Expected lostContact")
            } catch let error as WaitError {
                #expect(error == .lostContact(number: "12", runID: "run-12"))
            }
        }

        @Test func waitTimesOut() async throws {
            let lines = Lines()
            do {
                _ = try await wait([Self.poll("RUNNING")], timeout: .milliseconds(20), lines: lines)
                Issue.record("Expected timedOut")
            } catch let error as WaitError {
                #expect(error == .timedOut(number: "12", runID: "run-12", minutes: 0))
            }
        }

        @Test func failingPollsStillTimeOut() async throws {
            let lines = Lines()
            do {
                _ = try await wait([.status(500)], timeout: .milliseconds(20), contactLimit: .seconds(5), lines: lines)
                Issue.record("Expected timedOut")
            } catch let error as WaitError {
                #expect(error == .timedOut(number: "run-12", runID: "run-12", minutes: 0))
            }
        }

        @Test func cancellingTheTaskThrowsCancellation() async throws {
            CannedAPI.reset([Self.key: [Self.poll("RUNNING")]])
            let client = try CannedAPI.client()
            let builds = self.builds
            let task = Task {
                try await builds.wait(client, runID: "run-12", every: .milliseconds(1), timeout: .seconds(30), contactLimit: .seconds(30)) { _ in }
            }
            try await Task.sleep(for: .milliseconds(20))
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }
}
