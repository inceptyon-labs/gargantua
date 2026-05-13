import Foundation
import Testing
@testable import GargantuaCore

extension PrivilegedBackgroundItemValidatorTests {

    // MARK: - Argument shape

    @Test("launchctl arguments have the expected shape")
    func argumentShape() {
        let bootout = PrivilegedBackgroundItemValidator.launchctlArguments(
            for: .bootoutDaemon,
            label: "com.acme.tool",
            plistPath: nil
        )
        #expect(bootout == ["bootout", "system/com.acme.tool"])

        let disable = PrivilegedBackgroundItemValidator.launchctlArguments(
            for: .disableDaemon,
            label: "com.acme.tool",
            plistPath: nil
        )
        #expect(disable == ["disable", "system/com.acme.tool"])

        let enable = PrivilegedBackgroundItemValidator.launchctlArguments(
            for: .enableDaemon,
            label: "com.acme.tool",
            plistPath: nil
        )
        #expect(enable == ["enable", "system/com.acme.tool"])

        let bootstrap = PrivilegedBackgroundItemValidator.launchctlArguments(
            for: .bootstrapDaemon,
            label: "com.acme.tool",
            plistPath: "/Library/LaunchDaemons/com.acme.tool.plist"
        )
        #expect(bootstrap == ["bootstrap", "system", "/Library/LaunchDaemons/com.acme.tool.plist"])

        // Trash op has no launchctl arguments — the helper handles it via
        // FileManager.trashItem instead.
        let trash = PrivilegedBackgroundItemValidator.launchctlArguments(
            for: .trashLaunchPlist,
            label: "com.acme.tool",
            plistPath: nil
        )
        #expect(trash == nil)
    }
}
