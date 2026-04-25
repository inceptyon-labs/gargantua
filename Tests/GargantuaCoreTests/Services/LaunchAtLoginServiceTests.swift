import Foundation
import Testing
@testable import GargantuaCore

@Suite("LaunchAtLoginService")
struct LaunchAtLoginServiceTests {
    @Test("controller registers when enabled and unregisters when disabled")
    func controllerSynchronizesInstaller() throws {
        let installer = SpyLaunchAtLoginInstaller()
        let controller = LaunchAtLoginController(installer: installer)

        #expect(try controller.synchronize(isEnabled: true) == .enabled)
        #expect(installer.registerCount == 1)

        #expect(try controller.synchronize(isEnabled: false) == .notRegistered)
        #expect(installer.unregisterCount == 1)
    }

    @Test("controller does not re-register when approval is pending")
    func controllerKeepsRequiresApprovalStatus() throws {
        let installer = SpyLaunchAtLoginInstaller(initialStatus: .requiresApproval)
        let controller = LaunchAtLoginController(installer: installer)

        #expect(try controller.synchronize(isEnabled: true) == .requiresApproval)
        #expect(installer.registerCount == 0)
    }
}

private final class SpyLaunchAtLoginInstaller: LaunchAtLoginInstalling, @unchecked Sendable {
    var registerCount = 0
    var unregisterCount = 0
    private var currentStatus: LaunchAtLoginStatus

    init(initialStatus: LaunchAtLoginStatus = .notRegistered) {
        self.currentStatus = initialStatus
    }

    func status() -> LaunchAtLoginStatus {
        currentStatus
    }

    func register() throws -> LaunchAtLoginStatus {
        registerCount += 1
        currentStatus = .enabled
        return currentStatus
    }

    func unregister() throws -> LaunchAtLoginStatus {
        unregisterCount += 1
        currentStatus = .notRegistered
        return currentStatus
    }
}
