import Foundation
import Testing
@testable import GargantuaCore

@Suite("DeveloperToolPreviewAdapter")
struct DeveloperToolPreviewAdapterTests {
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

    @Test("env overrides expose installed state and versions")
    func availabilityUsesRuntimeResolvers() throws {
        let brew = try makeScratchBinary(name: "brew")
        let docker = try makeScratchBinary(name: "docker")
        defer {
            try? FileManager.default.removeItem(at: brew.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: docker.deletingLastPathComponent())
        }

        let runner = StubRunner(outputs: [
            "brew --version": ProcessOutput(stdout: "Homebrew 4.2.1\n", stderr: "", exitCode: 0),
            "docker --version": ProcessOutput(stdout: "Docker version 25.0.0, build abc\n", stderr: "", exitCode: 0),
        ])
        let resolver = DeveloperToolBinaryResolver(environment: [
            DeveloperToolBinaryResolver.homebrewEnvVarName: brew.path,
            DeveloperToolBinaryResolver.dockerEnvVarName: docker.path,
        ])
        let adapter = DeveloperToolPreviewAdapter(resolver: resolver, runner: runner)

        let availability = adapter.availability()

        #expect(availability.count == 2)
        #expect(availability.first { $0.tool == .homebrew }?.isInstalled == true)
        #expect(availability.first { $0.tool == .homebrew }?.version == "Homebrew 4.2.1")
        #expect(availability.first { $0.tool == .docker }?.isInstalled == true)
        #expect(availability.first { $0.tool == .docker }?.version?.hasPrefix("Docker version 25.0.0") == true)
    }

    @Test("missing binaries report unavailable and preview throws")
    func missingBinary() {
        let resolver = DeveloperToolBinaryResolver(environment: [
            DeveloperToolBinaryResolver.homebrewEnvVarName: "/definitely/not/brew",
        ])
        let adapter = DeveloperToolPreviewAdapter(resolver: resolver, runner: StubRunner(outputs: [:]))

        let availability = adapter.availability(for: .homebrew)

        #expect(!availability.isInstalled)
        #expect(availability.executable == nil)
        #expect(availability.error?.contains("Homebrew") == true)
        #expect(throws: DeveloperToolPreviewError.notInstalled(.homebrew)) {
            _ = try adapter.preview(.homebrew)
        }
    }

    @Test("Homebrew preview invokes cleanup dry-run and parses reclaimable sizes")
    func homebrewPreview() throws {
        let brew = try makeScratchBinary(name: "brew")
        defer { try? FileManager.default.removeItem(at: brew.deletingLastPathComponent()) }

        let runner = StubRunner(outputs: [
            "brew cleanup -n": ProcessOutput(
                stdout: """
                Would remove: /Users/me/Library/Caches/Homebrew/foo--1.0 (12.5MB)
                Would remove: /Users/me/Library/Caches/Homebrew/bar--2.0 (1GB)
                """,
                stderr: "",
                exitCode: 0
            ),
        ])
        let adapter = DeveloperToolPreviewAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.homebrewEnvVarName: brew.path,
            ]),
            runner: runner
        )

        let preview = try adapter.preview(.homebrew)

        #expect(runner.calls.map(\.arguments) == [["cleanup", "-n"]])
        #expect(preview.commandPreview == [brew.path, "cleanup", "-n"])
        #expect(preview.items.count == 2)
        #expect(preview.reclaimableBytes == 1_012_500_000)
    }

    @Test("Docker preview prefers structured system df JSON when available")
    func dockerStructuredPreview() throws {
        let docker = try makeScratchBinary(name: "docker")
        defer { try? FileManager.default.removeItem(at: docker.deletingLastPathComponent()) }

        let runner = StubRunner(outputs: [
            "docker system df --format json": ProcessOutput(
                stdout: """
                {"Type":"Images","TotalCount":"12","Active":"4","Size":"8.5GB","Reclaimable":"2.1GB (24%)"}
                {"Type":"Local Volumes","TotalCount":"5","Active":"5","Size":"10GB","Reclaimable":"0B (0%)"}
                {"Type":"Build Cache","TotalCount":"30","Active":"0","Size":"1.2GB","Reclaimable":"800MB"}
                """,
                stderr: "",
                exitCode: 0
            ),
        ])
        let adapter = DeveloperToolPreviewAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.dockerEnvVarName: docker.path,
            ]),
            runner: runner
        )

        let preview = try adapter.preview(.docker)

        #expect(runner.calls.map(\.arguments) == [["system", "df", "--format", "json"]])
        #expect(preview.commandPreview == [docker.path, "system", "df", "--format", "json"])
        #expect(preview.items.map(\.title) == ["Images", "Local Volumes", "Build Cache"])
        #expect(preview.items.first?.detail?.contains("Reclaimable: 2.1GB (24%)") == true)
        #expect(preview.reclaimableBytes == 2_900_000_000)
    }

    @Test("Docker preview falls back to legacy table when JSON format is unavailable")
    func dockerPreviewFallsBackToLegacyTable() throws {
        let docker = try makeScratchBinary(name: "docker")
        defer { try? FileManager.default.removeItem(at: docker.deletingLastPathComponent()) }

        let runner = StubRunner(outputs: [
            "docker system df --format json": ProcessOutput(
                stdout: "",
                stderr: "template parsing error: function \"json\" not defined",
                exitCode: 1
            ),
            "docker system df": ProcessOutput(
                stdout: """
                TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
                Images          12        4         8.5GB     2.1GB (24%)
                Build Cache     30        0         1.2GB     800MB
                Volumes         5         5         10GB      0B (0%)
                """,
                stderr: "",
                exitCode: 0
            ),
        ])
        let adapter = DeveloperToolPreviewAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.dockerEnvVarName: docker.path,
            ]),
            runner: runner
        )

        let preview = try adapter.preview(.docker)

        #expect(runner.calls.map(\.arguments) == [
            ["system", "df", "--format", "json"],
            ["system", "df"],
        ])
        #expect(preview.commandPreview == [docker.path, "system", "df"])
        #expect(preview.items.map(\.title) == ["Images", "Build Cache", "Volumes"])
        #expect(preview.reclaimableBytes == 2_900_000_000)
    }

    @Test("preview command failures are surfaced without fallback cleanup execution")
    func commandFailure() throws {
        let docker = try makeScratchBinary(name: "docker")
        defer { try? FileManager.default.removeItem(at: docker.deletingLastPathComponent()) }

        let runner = StubRunner(outputs: [
            "docker system df": ProcessOutput(stdout: "", stderr: "daemon unavailable", exitCode: 1),
        ])
        let adapter = DeveloperToolPreviewAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.dockerEnvVarName: docker.path,
            ]),
            runner: runner
        )

        #expect(throws: DeveloperToolPreviewError.commandFailed(
            tool: .docker,
            exitCode: 1,
            stderr: "daemon unavailable"
        )) {
            _ = try adapter.preview(.docker)
        }
        #expect(runner.calls.map(\.arguments) == [
            ["system", "df", "--format", "json"],
            ["system", "df"],
        ])
    }

    @Test("Docker daemon-down stderr maps to .daemonNotRunning, not commandFailed")
    func dockerDaemonNotRunningSurfacesAsDaemonNotRunning() throws {
        let docker = try makeScratchBinary(name: "docker")
        defer { try? FileManager.default.removeItem(at: docker.deletingLastPathComponent()) }

        let runner = StubRunner(outputs: [
            "docker system df": ProcessOutput(
                stdout: "",
                stderr: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?",
                exitCode: 1
            ),
        ])
        let adapter = DeveloperToolPreviewAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.dockerEnvVarName: docker.path,
            ]),
            runner: runner
        )

        #expect(throws: DeveloperToolPreviewError.daemonNotRunning(.docker)) {
            _ = try adapter.preview(.docker)
        }
    }

    @Test("isDockerDaemonNotRunning matches both canonical phrases")
    func dockerDaemonStderrPatterns() {
        #expect(DeveloperToolPreviewError.isDockerDaemonNotRunning(
            stderr: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock"
        ))
        #expect(DeveloperToolPreviewError.isDockerDaemonNotRunning(
            stderr: "error during connect: ... Is the docker daemon running?"
        ))
        #expect(!DeveloperToolPreviewError.isDockerDaemonNotRunning(
            stderr: "permission denied while trying to connect"
        ))
        #expect(!DeveloperToolPreviewError.isDockerDaemonNotRunning(stderr: ""))
    }

    @Test("adapter exposes no destructive prune commands")
    func noDestructiveCommands() {
        #expect(DeveloperToolPreviewAdapter.previewArguments(for: .homebrew) == ["cleanup", "-n"])
        #expect(DeveloperToolPreviewAdapter.previewArguments(for: .docker) == ["system", "df"])
        #expect(DeveloperToolPreviewAdapter.structuredPreviewArguments(for: .docker) == ["system", "df", "--format", "json"])
    }

    private func makeScratchBinary(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeveloperToolPreviewAdapterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
