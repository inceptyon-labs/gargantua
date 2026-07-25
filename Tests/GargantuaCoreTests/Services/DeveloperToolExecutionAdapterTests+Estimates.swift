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
        let completed = audit.entries.filter { $0.status == .completed }
        #expect(completed.map(\.command) == ["pnpm store prune", "go clean -cache"])
        #expect(completed.map(\.bytesFreed) == [0, 0])
    }

    @Test("npm and Yarn cache cleans run their args and audit the sized estimate")
    func npmAndYarnCacheCleanAudit() throws {
        let npm = try makeScratchBinary(name: "npm")
        let yarn = try makeScratchBinary(name: "yarn")
        defer {
            try? FileManager.default.removeItem(at: npm.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: yarn.deletingLastPathComponent())
        }

        let audit = AuditSpy()
        let adapter = DeveloperToolExecutionAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.npmEnvVarName: npm.path,
                DeveloperToolBinaryResolver.yarnEnvVarName: yarn.path,
            ]),
            runner: StubRunner(outputs: [
                "npm cache clean --force": ProcessOutput(stdout: "", stderr: "", exitCode: 0),
                "yarn cache clean": ProcessOutput(stdout: "success Cleared cache.\n", stderr: "", exitCode: 0),
            ]),
            auditRecorder: audit
        )

        let npmResult = try adapter.execute(
            .npmCacheClean,
            preview: cachePreview(tool: .npm, id: "npm-cache", command: ["npm", "config", "get", "cache"], bytes: 4_096),
            confirmationMethod: .summaryDialog
        )
        let yarnResult = try adapter.execute(
            .yarnCacheClean,
            preview: cachePreview(tool: .yarn, id: "yarn-cache", command: ["yarn", "cache", "dir"], bytes: 8_192),
            confirmationMethod: .summaryDialog
        )

        #expect(npmResult.estimatedBytesFreed == 4_096)
        #expect(yarnResult.estimatedBytesFreed == 8_192)
        let completed = audit.entries.filter { $0.status == .completed }
        #expect(completed.map(\.command) == ["npm cache clean --force", "yarn cache clean"])
        #expect(completed.map(\.bytesFreed) == [4_096, 8_192])
    }

    private func cachePreview(
        tool: DeveloperTool,
        id: String,
        command: [String],
        bytes: Int64
    ) -> DeveloperToolPreview {
        DeveloperToolPreview(
            tool: tool,
            commandPreview: command,
            items: [
                DeveloperToolPreviewItem(
                    id: id,
                    tool: tool,
                    title: id,
                    detail: "/tmp/\(id)",
                    reclaimableBytes: bytes,
                    commandPreview: command
                ),
            ],
            rawOutput: ""
        )
    }
}
