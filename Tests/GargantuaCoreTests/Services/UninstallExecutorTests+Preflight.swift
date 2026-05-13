import Foundation
import Testing
@testable import GargantuaCore

extension UninstallExecutorTests {
    @Test("missing authorization for non-writable app bundle prevents ordinary remnants from being trashed")
    @MainActor
    func nonWritableBundlePreflightPreventsPartialRemoval() async throws {
        let remover = SpyUninstallRemover()
        let app = Self.makeApp()
        let bundle = Self.makeRemnant(id: "bundle", category: .other, path: app.bundlePath, safety: .review)
        let ordinary = Self.makeRemnant(id: "cache", path: "/tmp/cache", safety: .safe)
        let executor = UninstallExecutor(
            remover: remover,
            privilegedHelper: SpyPrivilegedUninstallHelper(),
            processTerminator: SpyProcessTerminator(),
            auditRecorder: SpyUninstallAuditRecorder(),
            pathExists: { path in path == app.bundlePath },
            isWritablePath: { path in path != app.bundlePath }
        )

        await #expect(throws: UninstallExecutionError.authorizationRequired) {
            _ = try await executor.execute(
                UninstallPlan(app: app, appBundle: bundle, remnants: [ordinary]),
                options: UninstallExecutionOptions(confirmationMethod: .summaryDialog)
            )
        }

        #expect(remover.removedPaths.isEmpty)
    }

    @Test("missing admin authorization is checked before ordinary items are trashed")
    @MainActor
    func adminPreflightPreventsPartialRemoval() async throws {
        let remover = SpyUninstallRemover()
        let ordinary = Self.makeRemnant(id: "cache", path: "/tmp/cache", safety: .safe)
        let privileged = Self.makeRemnant(
            id: "daemon",
            category: .launchDaemons,
            path: "/Library/LaunchDaemons/demo.plist",
            safety: .protected_
        )
        let executor = UninstallExecutor(
            remover: remover,
            privilegedHelper: SpyPrivilegedUninstallHelper(),
            processTerminator: SpyProcessTerminator(),
            auditRecorder: SpyUninstallAuditRecorder()
        )

        await #expect(throws: UninstallExecutionError.authorizationRequired) {
            _ = try await executor.execute(
                Self.makePlan(remnants: [ordinary, privileged]),
                options: UninstallExecutionOptions(includeProtectedItems: true, confirmationMethod: .fullModal)
            )
        }

        #expect(remover.removedPaths.isEmpty)
    }
}
