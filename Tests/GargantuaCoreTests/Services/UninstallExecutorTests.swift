import Foundation
import Testing
@testable import GargantuaCore

@Suite("UninstallExecutor")
struct UninstallExecutorTests {
    @Test("dry-run mode reports planned trash operations without moving files or writing audit")
    @MainActor
    func dryRunDoesNotMutate() async throws {
        let item = Self.makeRemnant(
            id: "daemon",
            category: .launchDaemons,
            path: "/Library/LaunchDaemons/demo.plist",
            safety: .protected_
        )
        let executor = UninstallExecutor(
            remover: SpyUninstallRemover(),
            processTerminator: SpyProcessTerminator(),
            auditRecorder: SpyUninstallAuditRecorder()
        )

        let result = try await executor.execute(
            Self.makePlan(remnants: [item]),
            options: UninstallExecutionOptions(dryRun: true, confirmationMethod: .singleButton)
        )

        #expect(result.dryRun)
        #expect(result.cleanupResult.allSucceeded)
        #expect(result.cleanupResult.totalFreed == item.size)
        #expect(result.auditWritten == false)
        #expect(result.privilegedItems.map(\.path) == [item.path])
    }

    @Test("trash execution moves non-privileged items and writes uninstaller audit entry")
    @MainActor
    func trashExecutionWritesAudit() async throws {
        let remover = SpyUninstallRemover()
        let audit = SpyUninstallAuditRecorder()
        let item = Self.makeRemnant(id: "prefs", path: "/tmp/prefs.plist", safety: .review, size: 42)
        let executor = UninstallExecutor(
            remover: remover,
            processTerminator: SpyProcessTerminator(),
            auditRecorder: audit
        )

        let result = try await executor.execute(
            Self.makePlan(remnants: [item]),
            options: UninstallExecutionOptions(confirmationMethod: .summaryDialog)
        )

        #expect(result.cleanupResult.allSucceeded)
        #expect(remover.removedPaths == [item.path])
        #expect(audit.entries.count == 1)
        #expect(audit.entries[0].tool == "uninstaller")
        #expect(audit.entries[0].command == "uninstall")
        #expect(audit.entries[0].confirmationMethod == .summaryDialog)
        #expect(audit.entries[0].cleanupMethod == .trash)
        #expect(audit.entries[0].bytesFreed == 42)
        #expect(audit.entries[0].files.map(\.path) == [item.path])
        #expect(result.auditWritten)
    }

    @Test("writable Applications app bundles stay on ordinary trash path")
    @MainActor
    func writableApplicationsBundleUsesWorkspaceTrash() async throws {
        let remover = SpyUninstallRemover()
        let helper = SpyPrivilegedUninstallHelper()
        let app = Self.makeApp()
        let bundle = Self.makeRemnant(
            id: "bundle",
            category: .other,
            path: app.bundlePath,
            safety: .review,
            tags: ["app_bundle"]
        )
        let executor = UninstallExecutor(
            remover: remover,
            privilegedHelper: helper,
            processTerminator: SpyProcessTerminator(),
            auditRecorder: SpyUninstallAuditRecorder(),
            pathExists: { path in path == app.bundlePath },
            isWritablePath: { _ in true }
        )

        let result = try await executor.execute(
            UninstallPlan(app: app, appBundle: bundle),
            options: UninstallExecutionOptions(confirmationMethod: .summaryDialog)
        )

        #expect(remover.removedPaths == [app.bundlePath])
        #expect(helper.removedPaths.isEmpty)
        #expect(result.privilegedItems.isEmpty)
    }

    @Test("running app bundles are terminated before bundle trash")
    @MainActor
    func runningAppBundleTerminatesBeforeTrash() async throws {
        let remover = SpyUninstallRemover()
        let terminator = SpyProcessTerminator()
        let app = Self.makeApp(isRunning: true)
        let bundle = Self.makeRemnant(
            id: "bundle",
            category: .other,
            path: app.bundlePath,
            safety: .review,
            tags: ["app_bundle"]
        )
        let executor = UninstallExecutor(
            remover: remover,
            processTerminator: terminator,
            auditRecorder: SpyUninstallAuditRecorder()
        )

        _ = try await executor.execute(
            UninstallPlan(app: app, appBundle: bundle),
            options: UninstallExecutionOptions(confirmationMethod: .summaryDialog)
        )

        #expect(terminator.terminatedBundleIDs == [app.bundleID])
        #expect(remover.removedPaths == [app.bundlePath])
    }

    static func makePlan(remnants: [RemnantItem]) -> UninstallPlan {
        UninstallPlan(app: makeApp(), remnants: remnants)
    }

    static func makeApp(isRunning: Bool = false) -> AppInfo {
        AppInfo(
            bundleID: "com.example.Demo",
            name: "Demo",
            bundlePath: "/Applications/Demo.app",
            isRunning: isRunning,
            sizeOnDisk: 100
        )
    }

    static func makeRemnant(
        id: String,
        category: RemnantCategory = .caches,
        path: String,
        safety: SafetyLevel,
        size: Int64 = 100,
        tags: [String] = []
    ) -> RemnantItem {
        RemnantItem(
            id: id,
            appBundleID: "com.example.Demo",
            category: category,
            path: path,
            size: size,
            safety: safety,
            confidence: 95,
            explanation: "Test remnant",
            source: SourceAttribution(name: "Demo", bundleID: "com.example.Demo"),
            ruleID: "test",
            tags: tags
        )
    }
}
