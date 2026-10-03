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
                Would remove: /Users/me/Library/Caches/Homebrew/bootsnap/3d3385fbb25b (0B)
                ==> This operation would free approximately 1GB of disk space.
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

        #expect(runner.calls.map(\.arguments) == [["cleanup", "-n"], ["autoremove", "-n"]])
        #expect(preview.commandPreview == [brew.path, "cleanup", "-n"])
        // The "==>" total isn't an item, and the hash in the bootsnap path
        // isn't read as a size.
        #expect(preview.items.count == 3)
        #expect(preview.reclaimableBytes == 1_012_500_000)
    }

    @Test("Homebrew autoremove estimate sums each orphan formula's Cellar size")
    func homebrewAutoremoveEstimate() throws {
        let brew = try makeScratchBinary(name: "brew")
        defer { try? FileManager.default.removeItem(at: brew.deletingLastPathComponent()) }
        let cellar = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cellar) }
        try makeSizedFile(at: cellar.appendingPathComponent("libyaml/0.2.5/lib.a"), byteCount: 1_000)
        try makeSizedFile(at: cellar.appendingPathComponent("readline/8.2/lib.a"), byteCount: 2_500)
        let runner = StubRunner(outputs: [
            "brew cleanup -n": ProcessOutput(stdout: "", stderr: "", exitCode: 0),
            "brew autoremove -n": ProcessOutput(
                stdout: "==> Would autoremove 2 unneeded formulae:\nlibyaml\nreadline",
                stderr: "", exitCode: 0),
            "brew --cellar": ProcessOutput(stdout: cellar.path + "\n", stderr: "", exitCode: 0),
        ])
        let adapter = DeveloperToolPreviewAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.homebrewEnvVarName: brew.path]),
            runner: runner)
        let preview = try adapter.preview(.homebrew)
        let autoremove = try #require(preview.homebrewAutoremove)
        #expect(autoremove.formulae.map(\.title) == ["libyaml", "readline"])
        // Sizes come from directorySize()'s allocated-block accounting, which
        // rounds up on APFS, so assert the sum is correctly composed of the
        // per-item sizes rather than hardcoding the raw byte counts written.
        #expect(autoremove.formulae.compactMap(\.reclaimableBytes).allSatisfy { $0 > 0 })
        #expect(autoremove.totalBytes == autoremove.formulae.compactMap(\.reclaimableBytes).reduce(0, +))
        #expect(DeveloperToolCleanupOperation.homebrewAutoremove
            .estimatedReclaimableBytes(in: preview) == autoremove.totalBytes)
        #expect(preview.reclaimableBytes == 0)
    }

    @Test("No orphan formulae yields a present-but-zero autoremove estimate")
    func homebrewAutoremoveNoOrphans() throws {
        let brew = try makeScratchBinary(name: "brew")
        defer { try? FileManager.default.removeItem(at: brew.deletingLastPathComponent()) }
        let runner = StubRunner(outputs: [
            "brew cleanup -n": ProcessOutput(stdout: "", stderr: "", exitCode: 0),
            "brew autoremove -n": ProcessOutput(stdout: "", stderr: "", exitCode: 0),
        ])
        let adapter = DeveloperToolPreviewAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.homebrewEnvVarName: brew.path]),
            runner: runner)
        let preview = try adapter.preview(.homebrew)
        #expect(preview.homebrewAutoremove?.formulae.isEmpty == true)
        #expect(DeveloperToolCleanupOperation.homebrewAutoremove
            .estimatedReclaimableBytes(in: preview) == 0)
        #expect(runner.calls.map(\.arguments) == [["cleanup", "-n"], ["autoremove", "-n"]])
    }

    // The failure branch must yield `homebrewAutoremove == nil` (row stays
    // "Exact reclaim estimate unavailable") — never a present-but-empty 0,
    // which would read as a misleading "0 B previewed". This distinction is
    // the most regression-prone part of the feature, so guard each way it
    // can fail.

    @Test("A non-zero `brew autoremove -n` exit leaves the autoremove estimate unavailable")
    func homebrewAutoremoveDryRunFailure() throws {
        let brew = try makeScratchBinary(name: "brew")
        defer { try? FileManager.default.removeItem(at: brew.deletingLastPathComponent()) }
        let runner = StubRunner(outputs: [
            "brew cleanup -n": ProcessOutput(stdout: "", stderr: "", exitCode: 0),
            "brew autoremove -n": ProcessOutput(stdout: "", stderr: "boom", exitCode: 1),
        ])
        let adapter = DeveloperToolPreviewAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.homebrewEnvVarName: brew.path]),
            runner: runner)
        let preview = try adapter.preview(.homebrew)
        #expect(preview.homebrewAutoremove == nil)
        #expect(DeveloperToolCleanupOperation.homebrewAutoremove
            .estimatedReclaimableBytes(in: preview) == nil)
    }

    @Test("A failing `brew --cellar` while orphans exist leaves the estimate unavailable")
    func homebrewAutoremoveCellarFailure() throws {
        let brew = try makeScratchBinary(name: "brew")
        defer { try? FileManager.default.removeItem(at: brew.deletingLastPathComponent()) }
        let runner = StubRunner(outputs: [
            "brew cleanup -n": ProcessOutput(stdout: "", stderr: "", exitCode: 0),
            "brew autoremove -n": ProcessOutput(
                stdout: "==> Would autoremove 1 unneeded formula:\nlibyaml",
                stderr: "", exitCode: 0),
            "brew --cellar": ProcessOutput(stdout: "", stderr: "nope", exitCode: 1),
        ])
        let adapter = DeveloperToolPreviewAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.homebrewEnvVarName: brew.path]),
            runner: runner)
        let preview = try adapter.preview(.homebrew)
        #expect(preview.homebrewAutoremove == nil)
    }

    @Test("A non-absolute Cellar root leaves the autoremove estimate unavailable")
    func homebrewAutoremoveNonAbsoluteCellarRoot() throws {
        let brew = try makeScratchBinary(name: "brew")
        defer { try? FileManager.default.removeItem(at: brew.deletingLastPathComponent()) }
        let runner = StubRunner(outputs: [
            "brew cleanup -n": ProcessOutput(stdout: "", stderr: "", exitCode: 0),
            "brew autoremove -n": ProcessOutput(
                stdout: "==> Would autoremove 1 unneeded formula:\nlibyaml",
                stderr: "", exitCode: 0),
            "brew --cellar": ProcessOutput(stdout: "   \n", stderr: "", exitCode: 0),
        ])
        let adapter = DeveloperToolPreviewAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.homebrewEnvVarName: brew.path]),
            runner: runner)
        let preview = try adapter.preview(.homebrew)
        #expect(preview.homebrewAutoremove == nil)
    }
}
