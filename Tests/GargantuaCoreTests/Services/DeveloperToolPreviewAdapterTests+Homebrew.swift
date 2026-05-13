import Foundation
import Testing
@testable import GargantuaCore

extension DeveloperToolPreviewAdapterTests {
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
}
