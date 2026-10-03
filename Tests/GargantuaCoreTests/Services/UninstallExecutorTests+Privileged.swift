import Foundation
import GargantuaLicensing
import Testing
@testable import GargantuaCore

extension UninstallExecutorTests {
    @Test("protected items require full-modal override before any operation runs")
    @MainActor
    func protectedItemsRequireOverride() async throws {
        let remover = SpyUninstallRemover()
        let item = Self.makeRemnant(id: "daemon", category: .launchDaemons, path: "/Library/LaunchDaemons/demo.plist", safety: .protected_)
        let executor = UninstallExecutor(
            remover: remover,
            processTerminator: SpyProcessTerminator(),
            auditRecorder: SpyUninstallAuditRecorder()
        )

        await #expect(throws: UninstallExecutionError.protectedItemsRequireFullModalOverride) {
            _ = try await executor.execute(
                Self.makePlan(remnants: [item]),
                options: UninstallExecutionOptions(confirmationMethod: .summaryDialog),
                authorization: .unchecked(.uninstaller)
            )
        }
        #expect(remover.removedPaths.isEmpty)
    }

    @Test("admin-path items are gated behind an authorized privileged helper")
    @MainActor
    func adminPathGating() async throws {
        let helper = SpyPrivilegedUninstallHelper()
        let item = Self.makeRemnant(id: "helper", category: .helpers, path: "/Library/PrivilegedHelperTools/com.demo.helper", safety: .protected_)
        let executor = UninstallExecutor(
            remover: SpyUninstallRemover(),
            privilegedHelper: helper,
            processTerminator: SpyProcessTerminator(),
            auditRecorder: SpyUninstallAuditRecorder()
        )

        await #expect(throws: UninstallExecutionError.authorizationRequired) {
            _ = try await executor.execute(
                Self.makePlan(remnants: [item]),
                options: UninstallExecutionOptions(includeProtectedItems: true, confirmationMethod: .fullModal),
                authorization: .unchecked(.uninstaller)
            )
        }

        let result = try await executor.execute(
            Self.makePlan(remnants: [item]),
            options: UninstallExecutionOptions(
                includeProtectedItems: true,
                confirmationMethod: .fullModal,
                authorization: .authorizedForTesting
            ),
            authorization: .unchecked(.uninstaller)
        )

        #expect(helper.removedPaths == [item.path])
        #expect(helper.requests.map { $0.items.map(\.path) } == [[item.path]])
        #expect(result.privilegedItems.map(\.path) == [item.path])
        #expect(result.cleanupResult.allSucceeded)
    }

    @Test("non-writable Applications app bundles are routed through privileged helper")
    @MainActor
    func nonWritableApplicationsBundleUsesPrivilegedHelper() async throws {
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
            remover: SpyUninstallRemover(),
            privilegedHelper: helper,
            processTerminator: SpyProcessTerminator(),
            auditRecorder: SpyUninstallAuditRecorder(),
            pathExists: { path in path == app.bundlePath },
            isWritablePath: { path in path != app.bundlePath }
        )

        let result = try await executor.execute(
            UninstallPlan(app: app, appBundle: bundle),
            options: UninstallExecutionOptions(
                confirmationMethod: .summaryDialog,
                authorization: .authorizedForTesting
            ),
            authorization: .unchecked(.uninstaller)
        )

        #expect(helper.removedPaths == [app.bundlePath])
        #expect(helper.requests.count == 1)
        #expect(helper.requests[0].items.map(\.path) == [app.bundlePath])
        #expect(helper.requests[0].items.map(\.operation) == [.moveToTrash])
        #expect(result.privilegedItems.map(\.path) == [app.bundlePath])
    }
}

/// Cancels the running task while removing the first item, like Halt Cleanup.
@MainActor
final class CancellingUninstallRemover: UninstallRemoving {
    private(set) var removedPaths: [String] = []

    func moveToTrash(
        _ item: ScanResult,
        authorization _: DestructiveActionAuthorization
    ) async -> CleanupItemResult {
        removedPaths.append(item.path)
        withUnsafeCurrentTask { $0?.cancel() }
        return CleanupItemResult(item: item, succeeded: true)
    }
}

extension UninstallExecutorTests {
    @Test("Halting stops before the remaining items, Spotlight rules, and admin-helper removals")
    @MainActor
    func haltSkipsRemainingPhases() async throws {
        let remover = CancellingUninstallRemover()
        let helper = SpyPrivilegedUninstallHelper()
        let spotlight = SpySpotlightRuleRemover()
        let first = Self.makeRemnant(id: "a", category: .caches, path: "/Users/test/Library/Caches/demo-a", safety: .review)
        let second = Self.makeRemnant(id: "b", category: .caches, path: "/Users/test/Library/Caches/demo-b", safety: .review)
        let rule = Self.makeRemnant(id: "rule", category: .spotlightRules, path: "com.example.Demo", safety: .review)
        let daemon = Self.makeRemnant(
            id: "daemon",
            category: .launchDaemons,
            path: "/Library/LaunchDaemons/demo.plist",
            safety: .review
        )
        let executor = UninstallExecutor(
            remover: remover,
            privilegedHelper: helper,
            processTerminator: SpyProcessTerminator(),
            auditRecorder: SpyUninstallAuditRecorder(),
            spotlightRuleRemover: spotlight
        )

        _ = try await Task { @MainActor in
            try await executor.execute(
                Self.makePlan(remnants: [first, second, rule, daemon]),
                options: UninstallExecutionOptions(confirmationMethod: .fullModal, authorization: .authorizedForTesting),
                authorization: .unchecked(.uninstaller)
            )
        }.value

        #expect(remover.removedPaths == [first.path])
        #expect(spotlight.removed.isEmpty)
        #expect(helper.removedPaths.isEmpty)
    }
}
