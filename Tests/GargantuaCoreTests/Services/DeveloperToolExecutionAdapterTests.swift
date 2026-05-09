import Foundation
import Testing
@testable import GargantuaCore

@Suite("DeveloperToolExecutionAdapter")
struct DeveloperToolExecutionAdapterTests {
    private struct StubCall: Equatable {
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval?
    }

    private final class StubRunner: ProcessRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [StubCall] = []
        private let outputs: [String: ProcessOutput]

        init(outputs: [String: ProcessOutput]) {
            self.outputs = outputs
        }

        var calls: [StubCall] {
            lock.lock()
            defer { lock.unlock() }
            return _calls
        }

        func run(executable: URL, arguments: [String]) throws -> ProcessOutput {
            try run(executable: executable, arguments: arguments, timeout: nil)
        }

        func run(executable: URL, arguments: [String], timeout: TimeInterval?) throws -> ProcessOutput {
            lock.lock()
            _calls.append(StubCall(executable: executable.path, arguments: arguments, timeout: timeout))
            lock.unlock()

            let key = ([executable.lastPathComponent] + arguments).joined(separator: " ")
            return outputs[key] ?? ProcessOutput(stdout: "", stderr: "", exitCode: 0)
        }
    }

    private final class AuditSpy: DeveloperToolAuditRecording, @unchecked Sendable {
        private let lock = NSLock()
        private var _entries: [AuditEntry] = []

        var entries: [AuditEntry] {
            lock.lock()
            defer { lock.unlock() }
            return _entries
        }

        func write(_ entry: AuditEntry) throws {
            lock.lock()
            _entries.append(entry)
            lock.unlock()
        }
    }

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
        let entry = try #require(audit.entries.first)
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

        let entry = try #require(audit.entries.first)
        #expect(result.estimatedBytesFreed == 12_000_000)
        #expect(entry.tool == "developer-tools")
        #expect(entry.command == "brew cleanup")
        #expect(entry.files.isEmpty)
        #expect(entry.safetyLevel == .review)
        #expect(entry.confirmationMethod == .summaryDialog)
        #expect(entry.cleanupMethod == .toolNative)
        #expect(entry.bytesFreed == 12_000_000)
    }

    @Test("unknown byte estimates audit as zero instead of borrowing another preview total")
    func unknownEstimateAuditsAsZero() throws {
        let brew = try makeScratchBinary(name: "brew")
        defer { try? FileManager.default.removeItem(at: brew.deletingLastPathComponent()) }

        let audit = AuditSpy()
        let adapter = DeveloperToolExecutionAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.homebrewEnvVarName: brew.path,
            ]),
            runner: StubRunner(outputs: [
                "brew autoremove": ProcessOutput(stdout: "Uninstalled unused formulae\n", stderr: "", exitCode: 0),
            ]),
            auditRecorder: audit
        )

        let result = try adapter.execute(
            .homebrewAutoremove,
            preview: homebrewPreview(bytes: 12_000_000),
            confirmationMethod: .summaryDialog
        )

        let entry = try #require(audit.entries.first)
        #expect(result.estimatedBytesFreed == 0)
        #expect(entry.command == "brew autoremove")
        #expect(entry.bytesFreed == 0)
        #expect(entry.confirmationMethod == .summaryDialog)
    }

    @Test("failure surfaces stderr and does not write audit")
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
        #expect(audit.entries.isEmpty)
    }

    private func homebrewPreview(bytes: Int64) -> DeveloperToolPreview {
        DeveloperToolPreview(
            tool: .homebrew,
            commandPreview: ["brew", "cleanup", "-n"],
            items: [
                DeveloperToolPreviewItem(
                    id: "homebrew-0",
                    tool: .homebrew,
                    title: "Would remove foo",
                    reclaimableBytes: bytes,
                    commandPreview: ["brew", "cleanup", "-n"]
                ),
            ],
            rawOutput: ""
        )
    }

    private func dockerPreview(
        imageBytes: Int64 = 0,
        volumeBytes: Int64 = 0,
        buildBytes: Int64 = 0
    ) -> DeveloperToolPreview {
        DeveloperToolPreview(
            tool: .docker,
            commandPreview: ["docker", "system", "df"],
            items: [
                DeveloperToolPreviewItem(
                    id: "docker-images",
                    tool: .docker,
                    title: "Images",
                    reclaimableBytes: imageBytes,
                    commandPreview: ["docker", "system", "df"]
                ),
                DeveloperToolPreviewItem(
                    id: "docker-volumes",
                    tool: .docker,
                    title: "Local Volumes",
                    reclaimableBytes: volumeBytes,
                    commandPreview: ["docker", "system", "df"]
                ),
                DeveloperToolPreviewItem(
                    id: "docker-build-cache",
                    tool: .docker,
                    title: "Build Cache",
                    reclaimableBytes: buildBytes,
                    commandPreview: ["docker", "system", "df"]
                ),
            ],
            rawOutput: ""
        )
    }

    private func makeScratchBinary(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeveloperToolExecutionAdapterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
