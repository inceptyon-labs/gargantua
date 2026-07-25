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
        let adapter = DeveloperToolExecutionAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.homebrewEnvVarName: brew.path,
            ]),
            runner: StubRunner(outputs: [
                "brew cleanup": ProcessOutput(stdout: "Removed 12MB\n", stderr: "", exitCode: 0),
            ]),
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
