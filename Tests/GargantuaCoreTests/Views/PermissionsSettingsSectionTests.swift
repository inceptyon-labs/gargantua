import SwiftUI
import Testing
@testable import GargantuaCore

/// Guards the view's wiring to `PrivilegedHelperRowState`, not just the state
/// enum's own mapping (already covered by `PrivilegedHelperRowStateTests`).
/// Issue #9 regressed exactly here once: the button condition was narrowed
/// back to `state == .needsApproval`, silently dropping `.registrationRefused`
/// (the "helper is bundled but macOS refused to register it" case) into the
/// dead-end "Not in this build" label — with every other test still green.
@Suite("PermissionsSettingsSection helper row wiring")
@MainActor
struct PermissionsSettingsSectionTests {

    @Test("Enabled status derives granted state regardless of bundle presence")
    func enabledDerivesGranted() {
        let bundled = PermissionsSettingsSection(helperStatus: .enabled, isHelperBundled: true)
        let unbundled = PermissionsSettingsSection(helperStatus: .enabled, isHelperBundled: false)

        #expect(bundled.helperRowState == .granted)
        #expect(unbundled.helperRowState == .granted)
        #expect(bundled.helperTrailingAccessory == .grantedBadge)
        #expect(bundled.helperDetailColor == GargantuaColors.safe)
    }

    @Test("Not found and bundled derives registration refused and offers the retry button")
    func notFoundBundledOffersRetryButton() {
        let view = PermissionsSettingsSection(helperStatus: .notFound, isHelperBundled: true)

        #expect(view.helperRowState == .registrationRefused)
        #expect(view.helperTrailingAccessory == .registrationRetryButton)
        #expect(view.helperDetailColor == GargantuaColors.review)
    }

    @Test("Not found and not bundled keeps the old copy and the informational label")
    func notFoundUnbundledKeepsOldCopyAndLabel() {
        let view = PermissionsSettingsSection(helperStatus: .notFound, isHelperBundled: false)

        #expect(view.helperRowState == .notBundled)
        #expect(view.helperTrailingAccessory == .notBundledLabel)
        #expect(view.helperDetail.contains("Not included in this build"))
        #expect(view.helperDetailColor == GargantuaColors.ink3)
    }

    @Test("Requires approval offers the retry button and reviews red")
    func requiresApprovalOffersRetryButton() {
        let view = PermissionsSettingsSection(helperStatus: .requiresApproval, isHelperBundled: true)

        #expect(view.helperRowState == .needsApproval)
        #expect(view.helperTrailingAccessory == .registrationRetryButton)
        #expect(view.helperDetailColor == GargantuaColors.review)
    }

    @Test("Not registered offers the retry button and reviews red")
    func notRegisteredOffersRetryButton() {
        let view = PermissionsSettingsSection(helperStatus: .notRegistered, isHelperBundled: true)

        #expect(view.helperRowState == .needsApproval)
        #expect(view.helperTrailingAccessory == .registrationRetryButton)
        #expect(view.helperDetailColor == GargantuaColors.review)
    }

    @Test("Unknown status offers the retry button and reviews red")
    func unknownStatusOffersRetryButton() {
        let view = PermissionsSettingsSection(helperStatus: .unknown(99), isHelperBundled: true)

        #expect(view.helperRowState == .statusUnknown(99))
        #expect(view.helperTrailingAccessory == .registrationRetryButton)
        #expect(view.helperDetailColor == GargantuaColors.review)
    }

    // MARK: - Registration retry outcome

    //
    // Issue #9: users hitting `.notFound` had `register()` fail and were sent
    // to hunt for a Login Items toggle that was never created. These pin the
    // decision (not just the button's inline closure, which tests can't
    // drive) that a failed `register()` never yields the "open Login Items"
    // outcome.

    @Test("Successful registration reports the registered status")
    func registrationRetrySucceeds() {
        let installer = StubPrivilegedUninstallHelperInstaller(registerResult: .success(.enabled))

        let outcome = PermissionsSettingsSection.registrationRetryOutcome(installer: installer)

        #expect(outcome == .registered(.enabled))
    }

    @Test("Failed registration reports the error message and never the registered outcome")
    func registrationRetryFails() {
        let installer = StubPrivilegedUninstallHelperInstaller(
            registerResult: .failure(StubInstallerError(message: "boom"))
        )

        let outcome = PermissionsSettingsSection.registrationRetryOutcome(installer: installer)

        #expect(outcome == .failed("boom"))
        #expect(outcome != .registered(.enabled))
    }

    // MARK: - Poll clearing a stale registerError

    @Test("Poll clears a stale registerError when the status changed")
    func pollClearsErrorWhenStatusChanged() {
        #expect(
            PermissionsSettingsSection.pollClearsRegisterError(previous: .notFound, polled: .enabled)
        )
    }

    @Test("Poll leaves registerError alone when the status is unchanged")
    func pollKeepsErrorWhenStatusUnchanged() {
        #expect(
            !PermissionsSettingsSection.pollClearsRegisterError(previous: .notFound, polled: .notFound)
        )
    }
}

/// Test double for `PrivilegedUninstallHelperInstalling` whose `register()`
/// result is fixed at construction, so tests can drive the success and
/// throwing paths of `registrationRetryOutcome` without touching real
/// `SMAppService` state.
private struct StubPrivilegedUninstallHelperInstaller: PrivilegedUninstallHelperInstalling {
    var statusResult: PrivilegedHelperStatus = .notFound
    var registerResult: Result<PrivilegedHelperStatus, StubInstallerError>
    var unregisterResult: Result<PrivilegedHelperStatus, StubInstallerError> = .success(.notRegistered)

    func status() -> PrivilegedHelperStatus { statusResult }

    func register() throws -> PrivilegedHelperStatus {
        try registerResult.get()
    }

    func unregister() throws -> PrivilegedHelperStatus {
        try unregisterResult.get()
    }
}

private struct StubInstallerError: Error, LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
