import SwiftUI

/// Settings surface for the TCC permissions Gargantua relies on.
///
/// Onboarding only runs once, so users who installed before this flow existed —
/// or who skipped/denied a permission — need a durable place to grant or repair
/// it. Full Disk Access is link-only (macOS has no programmatic grant).
struct PermissionsSettingsSection: View {
    @State private var hasFullDiskAccess: Bool
    @State private var helperStatus: PrivilegedHelperStatus
    /// Set when re-registering the helper threw, so the row can explain why the
    /// Login Items toggle the user was just sent to find is missing.
    @State private var registerError: String?

    /// Whether this bundle ships the helper's launch daemon plist at all.
    /// `FileManager.fileExists` can't change during the process lifetime, so
    /// this is resolved once (via the cached static default below) rather than
    /// re-stat'd on every body pass under the 2s poll.
    private let isHelperBundled: Bool

    @Environment(\.openURL) private var openURL

    /// Reflects grants made directly in System Settings without a manual refresh.
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// Computed exactly once per process, regardless of how many times this
    /// view struct is initialized, unlike a plain stored-property default would be.
    private static let cachedIsHelperBundled = PrivilegedHelperConfiguration.isHelperBundled(
        bundleURL: Bundle.main.bundleURL
    )

    init(
        hasFullDiskAccess: Bool = PermissionChecker.hasFullDiskAccess,
        helperStatus: PrivilegedHelperStatus = SMAppServicePrivilegedHelperInstaller().status(),
        isHelperBundled: Bool = Self.cachedIsHelperBundled
    ) {
        self._hasFullDiskAccess = State(initialValue: hasFullDiskAccess)
        self._helperStatus = State(initialValue: helperStatus)
        self.isHelperBundled = isHelperBundled
    }

    var body: some View {
        SettingsSectionContainer(
            "Permissions",
            subtitle: "Grant these any time. Cleanup still works without them, just with fewer guarantees."
        ) {
            fullDiskAccessRow

            SettingsHairlineDivider()

            privilegedHelperRow
        }
        .onReceive(timer) { _ in
            hasFullDiskAccess = PermissionChecker.hasFullDiskAccess
            let polledStatus = SMAppServicePrivilegedHelperInstaller().status()
            if Self.pollClearsRegisterError(previous: helperStatus, polled: polledStatus) {
                // A stale `registerError` from an earlier failed `register()`
                // call would otherwise outlive the condition it described —
                // e.g. the user fixes things in System Settings and the row
                // still shows a red "could not register" message next to a
                // green "Granted" badge until relaunch. Any polled status
                // change means the world has moved since that error, so drop it.
                registerError = nil
            }
            helperStatus = polledStatus
        }
    }

    // MARK: - Privileged helper

    /// Trailing accessory shown in place of the exhaustive `switch` on
    /// `PrivilegedHelperRowState` — see `helperTrailingAccessory` below.
    enum HelperTrailingAccessory: Equatable {
        case grantedBadge
        case registrationRetryButton
        case notBundledLabel
    }

    /// Outcome of retrying registration from the "Open Settings" button.
    /// `register()` throwing most often means the status was `.notFound` —
    /// deep-linking to Login Items & Extensions in that case would send the
    /// user to hunt for a toggle that was never created, so the two outcomes
    /// carry different behavior (open the pane vs. don't) in the type itself
    /// rather than in a call site that could drift.
    enum RegistrationRetryOutcome: Equatable {
        case registered(PrivilegedHelperStatus)
        case failed(String)
    }

    /// Re-registers the helper via `installer` and reports what happened,
    /// without touching any `@State` — the view applies the result. Pure so
    /// tests can drive both the success and throwing paths with a stub
    /// installer.
    static func registrationRetryOutcome(
        installer: any PrivilegedUninstallHelperInstalling
    ) -> RegistrationRetryOutcome {
        do {
            return .registered(try installer.register())
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Whether a poll that saw `polled` after `previous` should drop a stale
    /// `registerError`. Any status change means the world has moved since the
    /// error was recorded, so it no longer describes the current state.
    static func pollClearsRegisterError(
        previous: PrivilegedHelperStatus,
        polled: PrivilegedHelperStatus
    ) -> Bool {
        polled != previous
    }

    // Internal (not `private`) so tests can construct this view and assert it
    // actually consumes `PrivilegedHelperRowState` rather than reimplementing
    // status handling inline — see PermissionsSettingsSectionTests.
    var helperRowState: PrivilegedHelperRowState {
        PrivilegedHelperRowState(status: helperStatus, isHelperBundled: isHelperBundled)
    }

    /// What the trailing accessory should show for the current row state.
    /// Kept as an exhaustive switch (not `if/else`) so a future
    /// `PrivilegedHelperRowState` case fails to compile here instead of
    /// silently falling through to the wrong accessory.
    var helperTrailingAccessory: HelperTrailingAccessory {
        switch helperRowState {
        case .granted: .grantedBadge
        case .needsApproval, .registrationRefused, .statusUnknown: .registrationRetryButton
        case .notBundled: .notBundledLabel
        }
    }

    private var privilegedHelperRow: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: "lock.shield.fill", size: 20)

            SettingsRowText(
                title: "Privileged helper",
                detail: helperDetail,
                detailColor: helperDetailColor
            )

            Spacer(minLength: GargantuaSpacing.space3)

            switch helperTrailingAccessory {
            case .grantedBadge:
                grantedBadge
            case .registrationRetryButton:
                GargantuaButton("Open Settings", icon: "arrow.up.forward.app") {
                    // Re-register so the toggle is present in the list, reflect
                    // the new status immediately, then deep-link straight to the
                    // Login Items & Extensions pane — but only once registration
                    // actually succeeded. `.notFound` (the status `register()`
                    // most often fails from) would otherwise send the user to a
                    // toggle that was never created.
                    switch Self.registrationRetryOutcome(installer: SMAppServicePrivilegedHelperInstaller()) {
                    case .registered(let status):
                        helperStatus = status
                        registerError = nil
                        openURL(loginItemsURL)
                    case .failed(let message):
                        registerError = message
                    }
                }
            case .notBundledLabel:
                // No embedded helper (a raw `swift build` run, or a fork signed
                // by another team). Informational — there's nothing to approve.
                Text("Not in this build")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink4)
            }
        }
    }

    var helperDetail: String {
        if let registerError {
            return "Gargantua could not register the helper, so it may not appear under Login Items & "
                + "Extensions: \(registerError)"
        }
        return helperRowState.detail
    }

    var helperDetailColor: Color {
        if registerError != nil { return GargantuaColors.review }
        return switch helperRowState {
        case .granted: GargantuaColors.safe
        case .notBundled: GargantuaColors.ink3
        case .needsApproval, .registrationRefused, .statusUnknown: GargantuaColors.review
        }
    }

    private var loginItemsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
    }

    // MARK: - Full Disk Access

    private var fullDiskAccessRow: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: "externaldrive.fill.badge.checkmark", size: 20)

            SettingsRowText(
                title: "Full Disk Access",
                detail: hasFullDiskAccess
                    ? "Granted — scans reach protected system folders."
                    : "Not granted — scans are limited to your home folder.",
                detailColor: hasFullDiskAccess ? GargantuaColors.safe : GargantuaColors.review
            )

            Spacer(minLength: GargantuaSpacing.space3)

            if hasFullDiskAccess {
                grantedBadge
            } else {
                GargantuaButton("Open Settings", icon: "arrow.up.forward.app") {
                    openURL(fullDiskAccessURL)
                }
            }
        }
    }

    private var grantedBadge: some View {
        HStack(spacing: GargantuaSpacing.space1) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
            Text("Granted")
                .font(GargantuaFonts.label)
        }
        .foregroundStyle(GargantuaColors.safe)
    }

    private var fullDiskAccessURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    }
}
