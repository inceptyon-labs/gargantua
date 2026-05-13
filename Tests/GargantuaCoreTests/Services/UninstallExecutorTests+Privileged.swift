import Foundation
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
                options: UninstallExecutionOptions(confirmationMethod: .summaryDialog)
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
                options: UninstallExecutionOptions(includeProtectedItems: true, confirmationMethod: .fullModal)
            )
        }

        let result = try await executor.execute(
            Self.makePlan(remnants: [item]),
            options: UninstallExecutionOptions(
                includeProtectedItems: true,
                confirmationMethod: .fullModal,
                authorization: .authorizedForTesting
            )
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
            )
        )

        #expect(helper.removedPaths == [app.bundlePath])
        #expect(helper.requests.count == 1)
        #expect(helper.requests[0].items.map(\.path) == [app.bundlePath])
        #expect(helper.requests[0].items.map(\.operation) == [.moveToTrash])
        #expect(result.privilegedItems.map(\.path) == [app.bundlePath])
    }
}
