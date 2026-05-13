import Foundation
import Testing
@testable import GargantuaCore

extension DeveloperToolPreviewAdapterTests {
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

    @Test("adapter exposes no destructive prune commands")
    func noDestructiveCommands() {
        #expect(DeveloperToolPreviewAdapter.previewArguments(for: .homebrew) == ["cleanup", "-n"])
        #expect(DeveloperToolPreviewAdapter.previewArguments(for: .docker) == ["system", "df"])
        #expect(DeveloperToolPreviewAdapter.previewArguments(for: .xcode) == ["simctl", "list", "-j", "devices", "unavailable"])
        #expect(DeveloperToolPreviewAdapter.previewArguments(for: .pnpm) == ["store", "path"])
        #expect(DeveloperToolPreviewAdapter.previewArguments(for: .go) == ["env", "-json", "GOCACHE", "GOMODCACHE"])
        #expect(DeveloperToolPreviewAdapter.previewArguments(for: .cargo) == ["--version"])
        #expect(DeveloperToolPreviewAdapter.structuredPreviewArguments(for: .docker) == ["system", "df", "--format", "json"])
    }
}
