import Foundation
import Testing
@testable import GargantuaCore

extension DeveloperToolExecutionAdapterTests {
    @Test("command construction uses the fixed operation arguments")
    func commandConstruction() throws {
        let docker = try makeScratchBinary(name: "docker")
        defer { try? FileManager.default.removeItem(at: docker.deletingLastPathComponent()) }

        let audit = AuditSpy()
        let runner = StubRunner(outputs: [
            "docker volume prune --force": ProcessOutput(stdout: "Deleted Volumes: a\n", stderr: "", exitCode: 0),
        ])
        let adapter = DeveloperToolExecutionAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.dockerEnvVarName: docker.path,
            ]),
            runner: runner,
            auditRecorder: audit
        )

        _ = try adapter.execute(.dockerVolumePrune, preview: dockerPreview(volumeBytes: 900), confirmationMethod: .fullModal)

        #expect(runner.calls.map(\.arguments) == [["volume", "prune", "--force"]])
        #expect(runner.calls.first?.timeout == 60)
        let entry = try #require(audit.entries.last)
        #expect(entry.command == "docker volume prune --force")
        #expect(entry.safetyLevel == .protected_)
        #expect(entry.confirmationMethod == .fullModal)
        #expect(entry.cleanupMethod == .toolNative)
        #expect(entry.bytesFreed == 900)
    }

    @Test("successful execution writes developer-tools audit entry shape")
    func auditEntryShape() throws {
        let brew = try makeScratchBinary(name: "brew")
        defer { try? FileManager.default.removeItem(at: brew.deletingLastPathComponent()) }

        let audit = AuditSpy()
        let runner = StubRunner(outputs: [
            "brew cleanup": ProcessOutput(stdout: "Removed 12MB\n", stderr: "", exitCode: 0),
        ])
        // Observe at write time how many runner.run calls have completed. If
        // the intent write moved to after runner.run, the first write's
        // observation would flip from 0 to 1 and this test would fail.
        audit.observeRunnerCallCount = { runner.calls.count }
        let adapter = DeveloperToolExecutionAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.homebrewEnvVarName: brew.path,
            ]),
            runner: runner,
            auditRecorder: audit
        )

        let result = try adapter.execute(
            .homebrewCleanup,
            preview: homebrewPreview(bytes: 12_000_000),
            confirmationMethod: .summaryDialog
        )

        #expect(audit.entries.count == 2)
        #expect(audit.entries.first?.status == .attempted)
        #expect(audit.entries.first?.id == audit.entries.last?.id)
        // The intent write must happen before runner.run, and the completed
        // write after it — not merely that a pair exists once execution
        // finishes.
        #expect(audit.runnerCallCountAtWrite == [0, 1])
        let entry = try #require(audit.entries.last)
        #expect(result.estimatedBytesFreed == 12_000_000)
        #expect(entry.tool == "developer-tools")
        #expect(entry.command == "brew cleanup")
        #expect(entry.files.isEmpty)
        #expect(entry.safetyLevel == .review)
        #expect(entry.confirmationMethod == .summaryDialog)
        #expect(entry.cleanupMethod == .toolNative)
        #expect(entry.bytesFreed == 12_000_000)
        #expect(entry.status == .completed)
    }

    @Test("Xcode simulator cleanup runs through xcrun and audits preview bytes")
    func xcodeSimulatorCleanup() throws {
        let xcrun = try makeScratchBinary(name: "xcrun")
        defer { try? FileManager.default.removeItem(at: xcrun.deletingLastPathComponent()) }

        let audit = AuditSpy()
        let adapter = DeveloperToolExecutionAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.xcrunEnvVarName: xcrun.path,
            ]),
            runner: StubRunner(outputs: [
                "xcrun simctl delete unavailable": ProcessOutput(stdout: "Deleted 2 devices\n", stderr: "", exitCode: 0),
            ]),
            auditRecorder: audit
        )

        let result = try adapter.execute(
            .xcodeDeleteUnavailableSimulators,
            preview: xcodePreview(bytes: 24_000_000),
            confirmationMethod: .summaryDialog
        )

        let entry = try #require(audit.entries.last)
        #expect(result.commandPreview == [xcrun.path, "simctl", "delete", "unavailable"])
        #expect(entry.command == "xcrun simctl delete unavailable")
        #expect(entry.safetyLevel == .review)
        #expect(entry.bytesFreed == 24_000_000)
    }

    @Test("failure surfaces stderr and writes a completed outcome entry with the exit code")
    func failureSurfacesStderr() throws {
        let docker = try makeScratchBinary(name: "docker")
        defer { try? FileManager.default.removeItem(at: docker.deletingLastPathComponent()) }

        let audit = AuditSpy()
        let adapter = DeveloperToolExecutionAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.dockerEnvVarName: docker.path,
            ]),
            runner: StubRunner(outputs: [
                "docker image prune --force": ProcessOutput(stdout: "", stderr: "daemon unavailable\n", exitCode: 1),
            ]),
            auditRecorder: audit
        )

        #expect(throws: DeveloperToolExecutionError.commandFailed(
            operation: .dockerImagePrune,
            exitCode: 1,
            stderr: "daemon unavailable"
        )) {
            _ = try adapter.execute(.dockerImagePrune, preview: dockerPreview(imageBytes: 500), confirmationMethod: .summaryDialog)
        }
        // The prune ran and failed on its own terms — we know the exit code,
        // so this is an outcome, not a crash. A surviving `.attempted` line
        // would misreport this as the process having died mid-operation.
        #expect(audit.entries.count == 2)
        #expect(audit.entries.first?.status == .attempted)
        #expect(audit.entries.first?.id == audit.entries.last?.id)
        let outcome = try #require(audit.entries.last)
        #expect(outcome.status == .completed)
        #expect(outcome.bytesFreed == 0)
        #expect(outcome.commandExitCode == 1)
    }

    /// Runner that always throws, standing in for `DefaultProcessRunner`
    /// surfacing `ProcessRunnerError.spawnFailed`/`.timedOut`/`.waitFailed`
    /// when `posix_spawn` fails, the tool hangs past the timeout, or `wait4`
    /// itself fails — none of which run the destructive tool.
    final class ThrowingRunner: ProcessRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var _callCount = 0
        let error: Error

        init(error: Error) {
            self.error = error
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _callCount
        }

        func run(executable: URL, arguments: [String]) throws -> ProcessOutput {
            try run(executable: executable, arguments: arguments, timeout: nil)
        }

        func run(executable: URL, arguments: [String], timeout: TimeInterval?) throws -> ProcessOutput {
            lock.lock()
            _callCount += 1
            lock.unlock()
            throw error
        }
    }

    @Test("a throw from runner.run writes a completed outcome entry instead of leaving an orphaned attempt")
    func runnerThrowWritesCompletedOutcome() throws {
        let brew = try makeScratchBinary(name: "brew")
        defer { try? FileManager.default.removeItem(at: brew.deletingLastPathComponent()) }

        let audit = AuditSpy()
        let runner = ThrowingRunner(error: ProcessRunnerError.spawnFailed(errno: 2))
        let adapter = DeveloperToolExecutionAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.homebrewEnvVarName: brew.path,
            ]),
            runner: runner,
            auditRecorder: audit
        )

        #expect(throws: ProcessRunnerError.spawnFailed(errno: 2)) {
            _ = try adapter.execute(.homebrewCleanup, preview: homebrewPreview(bytes: 12_000_000), confirmationMethod: .summaryDialog)
        }

        // `posix_spawn` failing is a strictly false-record risk: NOTHING ran,
        // yet a surviving `.attempted` line would claim a destructive prune
        // died mid-flight. If the runner.run throw were left unhandled (the
        // original gap), only the intent write would exist and this count
        // would be 1, not 2.
        #expect(audit.entries.count == 2)
        #expect(audit.entries.first?.status == .attempted)
        #expect(audit.entries.first?.id == audit.entries.last?.id)
        let outcome = try #require(audit.entries.last)
        #expect(outcome.status == .completed)
        #expect(outcome.bytesFreed == 0)
    }

    @Test("missing binary throws notInstalled and writes no audit entry")
    func missingBinaryWritesNoAudit() throws {
        let audit = AuditSpy()
        let adapter = DeveloperToolExecutionAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.dockerEnvVarName: "/nonexistent/path/to/docker",
            ]),
            runner: StubRunner(outputs: [:]),
            auditRecorder: audit
        )

        #expect(throws: DeveloperToolExecutionError.notInstalled(.docker)) {
            _ = try adapter.execute(.dockerImagePrune, preview: dockerPreview(imageBytes: 500), confirmationMethod: .summaryDialog)
        }
        #expect(audit.entries.isEmpty)
    }
}
