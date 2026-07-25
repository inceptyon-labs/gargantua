import Foundation
import GargantuaLicensing
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
            options: UninstallExecutionOptions(dryRun: true, confirmationMethod: .singleButton),
            authorization: nil
        )

        #expect(result.dryRun)
        #expect(result.cleanupResult.allSucceeded)
        #expect(result.cleanupResult.totalFreed == item.size)
        #expect(result.auditWritten == false)
        #expect(result.privilegedItems.map(\.path) == [item.path])
    }

    @Test("non-dry-run without an authorization token is rejected before anything is deleted")
    @MainActor
    func realRunWithoutAuthorizationIsBlocked() async throws {
        let remover = SpyUninstallRemover()
        let audit = SpyUninstallAuditRecorder()
        let item = Self.makeRemnant(id: "prefs", path: "/tmp/prefs.plist", safety: .review)
        let executor = UninstallExecutor(
            remover: remover,
            processTerminator: SpyProcessTerminator(),
            auditRecorder: audit
        )

        await #expect(throws: UninstallExecutionError.licenseBlocked(.noLicense)) {
            try await executor.execute(
                Self.makePlan(remnants: [item]),
                options: UninstallExecutionOptions(confirmationMethod: .summaryDialog),
                authorization: nil
            )
        }

        #expect(remover.removedPaths.isEmpty)
        #expect(audit.entries.isEmpty)
    }

    @Test("non-dry-run with a token minted for another surface is rejected")
    @MainActor
    func realRunWithWrongSurfaceTokenIsBlocked() async throws {
        let remover = SpyUninstallRemover()
        let audit = SpyUninstallAuditRecorder()
        let item = Self.makeRemnant(id: "prefs", path: "/tmp/prefs.plist", safety: .review)
        let executor = UninstallExecutor(
            remover: remover,
            processTerminator: SpyProcessTerminator(),
            auditRecorder: audit
        )

        await #expect(throws: UninstallExecutionError.licenseBlocked(.noLicense)) {
            try await executor.execute(
                Self.makePlan(remnants: [item]),
                options: UninstallExecutionOptions(confirmationMethod: .summaryDialog),
                authorization: .unchecked(.deepClean)
            )
        }

        #expect(remover.removedPaths.isEmpty)
        #expect(audit.entries.isEmpty)
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
            options: UninstallExecutionOptions(confirmationMethod: .summaryDialog),
            authorization: .unchecked(.uninstaller)
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

    @Test("spotlight-rule remnant is removed via cfprefsd, never trashed")
    @MainActor
    func spotlightRuleRoutedToRemover() async throws {
        let remover = SpyUninstallRemover()
        let spotlight = SpySpotlightRuleRemover()
        let file = Self.makeRemnant(id: "prefs", path: "/tmp/prefs.plist", safety: .review)
        let rule = Self.makeRemnant(
            id: "spot",
            category: .spotlightRules,
            path: "Spotlight rule (com.example.Demo)",
            safety: .review,
            size: 0
        )
        let executor = UninstallExecutor(
            remover: remover,
            processTerminator: SpyProcessTerminator(),
            auditRecorder: SpyUninstallAuditRecorder(),
            spotlightRuleRemover: spotlight
        )

        let result = try await executor.execute(
            Self.makePlan(remnants: [file, rule]),
            options: UninstallExecutionOptions(confirmationMethod: .summaryDialog),
            authorization: .unchecked(.uninstaller)
        )

        #expect(spotlight.removed == ["com.example.Demo"])
        #expect(remover.removedPaths == ["/tmp/prefs.plist"]) // rule was NOT trashed
        #expect(result.cleanupResult.allSucceeded)
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
            options: UninstallExecutionOptions(confirmationMethod: .summaryDialog),
            authorization: .unchecked(.uninstaller)
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
            options: UninstallExecutionOptions(confirmationMethod: .summaryDialog),
            authorization: .unchecked(.uninstaller)
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
