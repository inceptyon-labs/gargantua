import Foundation
import Testing
@testable import GargantuaCore

extension DeveloperToolExecutionAdapterTests {
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

    @Test("pnpm and Go unknown byte estimates audit as zero")
    func pnpmAndGoUnknownEstimateAuditsAsZero() throws {
        let pnpm = try makeScratchBinary(name: "pnpm")
        let go = try makeScratchBinary(name: "go")
        defer {
            try? FileManager.default.removeItem(at: pnpm.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: go.deletingLastPathComponent())
        }

        let audit = AuditSpy()
        let adapter = DeveloperToolExecutionAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.pnpmEnvVarName: pnpm.path,
                DeveloperToolBinaryResolver.goEnvVarName: go.path,
            ]),
            runner: StubRunner(outputs: [
                "pnpm store prune": ProcessOutput(stdout: "Removed cached packages\n", stderr: "", exitCode: 0),
                "go clean -cache": ProcessOutput(stdout: "", stderr: "", exitCode: 0),
            ]),
            auditRecorder: audit
        )

        let pnpmResult = try adapter.execute(
            .pnpmStorePrune,
            preview: pnpmPreview(),
            confirmationMethod: .summaryDialog
        )
        let goResult = try adapter.execute(
            .goCleanCache,
            preview: goPreview(),
            confirmationMethod: .summaryDialog
        )

        #expect(pnpmResult.estimatedBytesFreed == 0)
        #expect(goResult.estimatedBytesFreed == 0)
        #expect(audit.entries.map(\.command) == ["pnpm store prune", "go clean -cache"])
        #expect(audit.entries.map(\.bytesFreed) == [0, 0])
    }
}
