import SwiftUI

/// Settings surface for the TCC permissions Gargantua relies on.
///
/// Onboarding only runs once, so users who installed before this flow existed —
/// or who skipped/denied a permission — need a durable place to grant or repair
/// it. Full Disk Access is link-only (macOS has no programmatic grant).
struct PermissionsSettingsSection: View {
    @State private var hasFullDiskAccess = PermissionChecker.hasFullDiskAccess
    @State private var helperStatus = SMAppServicePrivilegedHelperInstaller().status()
    /// Set when re-registering the helper threw, so the row can explain why the
    /// Login Items toggle the user was just sent to find is missing.
    @State private var registerError: String?

    @Environment(\.openURL) private var openURL

    /// Reflects grants made directly in System Settings without a manual refresh.
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

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
            helperStatus = SMAppServicePrivilegedHelperInstaller().status()
        }
    }

    // MARK: - Privileged helper

    private var helperRowState: PrivilegedHelperRowState {
        PrivilegedHelperRowState(
            status: helperStatus,
            isHelperBundled: PrivilegedHelperConfiguration.isHelperBundled(
                bundleURL: Bundle.main.bundleURL
            )
        )
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

            let state = helperRowState
            if state == .granted {
                grantedBadge
            } else if state.offersRegistrationRetry {
                GargantuaButton("Open Settings", icon: "arrow.up.forward.app") {
                    // Re-register so the toggle is present in the list, reflect
                    // the new status immediately, then deep-link straight to the
                    // Login Items & Extensions pane. A failed registration means
                    // the toggle will not be there at all, so say so rather than
                    // sending the user to hunt for a row that does not exist.
                    do {
                        helperStatus = try SMAppServicePrivilegedHelperInstaller().register()
                        registerError = nil
                    } catch {
                        registerError = error.localizedDescription
                    }
                    openURL(loginItemsURL)
                }
            } else {
                // `.notBundled`: no embedded helper (a raw `swift build` run, or
                // a fork signed by another team). Informational — there's
                // nothing to approve.
                Text("Not in this build")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink4)
            }
        }
    }

    private var helperDetail: String {
        if let registerError {
            return "Gargantua could not register the helper, so it may not appear under Login Items & "
                + "Extensions: \(registerError)"
        }
        return helperRowState.detail
    }

    private var helperDetailColor: Color {
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
