import Foundation
import Testing
@testable import GargantuaCore

extension DeveloperToolPreviewAdapterTests {
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

    @Test("Docker preview timeout maps to daemon-stopped recovery")
    func dockerPreviewTimeoutMapsToDaemonStopped() throws {
        let docker = try makeScratchBinary(name: "docker")
        defer { try? FileManager.default.removeItem(at: docker.deletingLastPathComponent()) }

        let runner = StubRunner(
            outputs: [:],
            errors: [
                "docker system df --format json": ProcessRunnerError.timedOut(seconds: 15),
            ]
        )
        let adapter = DeveloperToolPreviewAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.dockerEnvVarName: docker.path,
            ]),
            runner: runner
        )

        #expect(throws: DeveloperToolPreviewError.daemonNotRunning(.docker)) {
            _ = try adapter.preview(.docker)
        }
        #expect(runner.calls.map(\.arguments) == [
            ["system", "df", "--format", "json"],
        ])
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
}
