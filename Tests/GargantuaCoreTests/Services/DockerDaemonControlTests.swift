import Foundation
import Testing
@testable import GargantuaCore

@Suite("DockerDaemonControl")
struct DockerDaemonControlTests {
    private struct StubCall: Equatable {
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval?
    }

    private final class StubRunner: ProcessRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [StubCall] = []
        private let outputs: [String: ProcessOutput]
        private let errors: [String: Error]

        init(outputs: [String: ProcessOutput], errors: [String: Error] = [:]) {
            self.outputs = outputs
            self.errors = errors
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
            if let error = errors[key] {
                throw error
            }
            return outputs[key] ?? ProcessOutput(stdout: "", stderr: "", exitCode: 0)
        }
    }

    private final class AppOpenRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [URL] = []

        var urls: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return _urls
        }

        func open(_ url: URL) -> Bool {
            lock.lock()
            _urls.append(url)
            lock.unlock()
            return true
        }
    }

    @Test("Docker Desktop status output is parsed from the CLI table")
    func desktopStatusParsing() {
        #expect(DockerDaemonControl.parseDesktopStatus("""
        Name                Value
        Status              running
        SessionID           abc
        """) == .running)
        #expect(DockerDaemonControl.parseDesktopStatus("Status starting\n") == .starting)
        #expect(DockerDaemonControl.parseDesktopStatus("Status stopped\n") == .stopped)
        #expect(DockerDaemonControl.parseDesktopStatus("Status confused\n") == .unknown)
    }

    @Test("start restarts Desktop when Desktop is running but daemon is unavailable")
    func startRestartsRunningDesktop() throws {
        let docker = try makeScratchBinary(name: "docker")
        defer { try? FileManager.default.removeItem(at: docker.deletingLastPathComponent()) }
        let runner = StubRunner(outputs: [
            "docker desktop status": ProcessOutput(
                stdout: """
                Name                Value
                Status              running
                """,
                stderr: "",
                exitCode: 0
            ),
            "docker desktop restart --detach --timeout 10": ProcessOutput(stdout: "", stderr: "", exitCode: 0),
        ])
        let recorder = AppOpenRecorder()
        let control = DockerDaemonControl(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.dockerEnvVarName: docker.path,
            ]),
            runner: runner,
            appPaths: [],
            appOpener: { recorder.open($0) }
        )

        #expect(control.start())
        #expect(runner.calls.map(\.arguments) == [
            ["desktop", "status"],
            ["desktop", "restart", "--detach", "--timeout", "10"],
        ])
        #expect(recorder.urls.isEmpty)
    }

    @Test("start uses Docker Desktop CLI start when Desktop is stopped")
    func startUsesDesktopStart() throws {
        let docker = try makeScratchBinary(name: "docker")
        defer { try? FileManager.default.removeItem(at: docker.deletingLastPathComponent()) }
        let runner = StubRunner(outputs: [
            "docker desktop status": ProcessOutput(stdout: "Status stopped\n", stderr: "", exitCode: 0),
            "docker desktop start --detach --timeout 10": ProcessOutput(stdout: "", stderr: "", exitCode: 0),
        ])
        let control = DockerDaemonControl(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.dockerEnvVarName: docker.path,
            ]),
            runner: runner,
            appPaths: []
        )

        #expect(control.start())
        #expect(runner.calls.map(\.arguments) == [
            ["desktop", "status"],
            ["desktop", "start", "--detach", "--timeout", "10"],
        ])
    }

    @Test("start falls back to opening Docker.app when CLI launch is unavailable")
    func startFallsBackToAppOpen() throws {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GargantuaDockerControlTests-\(UUID().uuidString)")
            .appendingPathComponent("Docker.app")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let recorder = AppOpenRecorder()
        let control = DockerDaemonControl(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.dockerEnvVarName: "/definitely/not/docker",
            ]),
            runner: StubRunner(outputs: [:]),
            appPaths: [appURL.path],
            appOpener: { recorder.open($0) }
        )

        #expect(control.start())
        #expect(recorder.urls.map(\.path) == [appURL.path])
    }

    private func makeScratchBinary(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GargantuaDockerControlTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
