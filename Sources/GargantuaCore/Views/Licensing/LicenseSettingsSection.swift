import AppKit
import GargantuaLicensing
import SwiftUI

/// Settings → License pane. Displays current license / trial state and accepts
/// a Polar license key (pasted) for activation. Activation is a network call to
/// Polar's public customer-portal API.
struct LicenseSettingsSection: View {
    @State private var model = LicenseStateModel.shared
    @State private var keyDraft: String = ""
    @State private var inlineFeedback: InlineFeedback?
    @State private var isWorking = false

    private enum InlineFeedback: Equatable {
        case success(String)
        case error(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space5) {
            statusCard
            activationCard
        }
        .task { await model.refresh() }
    }

    // MARK: Status card

    private var statusCard: some View {
        SettingsSectionContainer("License", subtitle: statusSubtitle) {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
                statusRow

                // Deactivation feedback belongs here, not on the activation
                // card: that card is `EmptyView` while licensed, which is
                // exactly when "Deactivate this Mac" is on screen.
                if let inlineFeedback, case .licensed = model.state {
                    feedbackRow(inlineFeedback)
                }
            }
        }
    }

    private var statusRow: some View {
        Group {
            HStack(spacing: GargantuaSpacing.space3) {
                SettingsRowIcon(systemName: statusIconName, size: 16)

                VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                    Text(statusHeadline)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)

                    if let detail = statusDetail {
                        Text(detail)
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink3)
                    }
                }

                Spacer()

                if case .licensed = model.state {
                    GargantuaButton("Deactivate this Mac", icon: "minus.circle", tone: .neutral) {
                        Task {
                            isWorking = true
                            // Report the outcome. A failed deactivation leaves
                            // the activation slot consumed, and the card would
                            // otherwise just keep saying "Licensed to …" — the
                            // user has no way to tell it did not work.
                            switch await model.deactivate() {
                            case .success:
                                inlineFeedback = .success("This Mac has been deactivated.")
                            case .failure(let error):
                                inlineFeedback = .error(LicenseErrorCopy.message(for: error))
                            }
                            isWorking = false
                        }
                    }
                    .disabled(isWorking)
                }
            }
            .padding(.vertical, GargantuaSpacing.space1)
        }
    }

    // MARK: Activation card

    @ViewBuilder
    private var activationCard: some View {
        if case .licensed = model.state {
            EmptyView()
        } else {
            SettingsSectionContainer(
                "Activate",
                subtitle: "Paste the license key from your purchase email."
            ) {
                VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                    TextField(
                        "GARG-XXXX-XXXX-XXXX-XXXX",
                        text: $keyDraft,
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(GargantuaFonts.monoData)
                    .lineLimit(2 ... 4)
                    .disabled(isWorking)

                    if let inlineFeedback {
                        feedbackRow(inlineFeedback)
                    }

                    manageDevicesLink

                    HStack(spacing: GargantuaSpacing.space3) {
                        Spacer()
                        GargantuaButton("Buy Gargantua · $29", icon: "arrow.up.right.square", tone: .neutral) {
                            openCheckout()
                        }
                        .disabled(isWorking)
                        GargantuaButton(
                            isWorking ? "Activating…" : "Activate",
                            icon: "key.fill",
                            tone: .primary,
                            isDisabled: isWorking || keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ) {
                            activate()
                        }
                    }
                }
            }
        }
    }

    /// Self-serve escape hatch for orphaned activation slots. A reinstalled or
    /// replaced Mac can't be freed with "Deactivate this Mac" (no local receipt
    /// survives), so point the user at Polar's portal where they log in by email
    /// and deactivate the stale device themselves.
    private var manageDevicesLink: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "macbook.and.iphone")
                .foregroundStyle(GargantuaColors.ink3)
            Button {
                openPortal()
            } label: {
                Text("Replaced or reinstalled a Mac? Manage activated devices")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.accent)
                    .underline()
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
        }
    }

    private func feedbackRow(_ feedback: InlineFeedback) -> some View {
        let color: Color = switch feedback {
        case .success: GargantuaColors.safe
        case .error: GargantuaColors.protected_
        }
        let icon: String = switch feedback {
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
        let text: String = switch feedback {
        case .success(let message): message
        case .error(let message): message
        }
        return HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(GargantuaFonts.caption)
                .foregroundStyle(color)
        }
    }

    private func activate() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Task {
            isWorking = true
            let result = await model.activate(key: key)
            isWorking = false
            switch result {
            case .success:
                inlineFeedback = .success("Activated. Thanks for funding development.")
                keyDraft = ""
            case .failure(let error):
                inlineFeedback = .error(LicenseErrorCopy.message(for: error))
            }
        }
    }

    private func openCheckout() {
        NSWorkspace.shared.open(LicensePolarConfig.checkoutURL)
    }

    private func openPortal() {
        NSWorkspace.shared.open(LicensePolarConfig.customerPortalURL)
    }

    // MARK: State helpers

    private var statusIconName: String {
        switch model.state {
        case .licensed: "checkmark.seal.fill"
        case .trial: "hourglass"
        case .expired: "exclamationmark.triangle.fill"
        case .none: "lock.fill"
        }
    }

    private var statusHeadline: String {
        switch model.state {
        case .licensed(let email, _, _): "Licensed to \(email)"
        case .trial(let days) where days == 1: "Trial — 1 day remaining"
        case .trial(let days): "Trial — \(days) days remaining"
        case .expired: "Trial ended"
        case .none: "No license active"
        }
    }

    private var statusDetail: String? {
        switch model.state {
        case .licensed(_, _, let activatedAt):
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return "Activated \(formatter.string(from: activatedAt)). One license covers up to 3 Macs."
        case .trial:
            return "Scans and previews stay free forever. Deep Clean, Uninstall, and Quarantine apply require a license after trial."
        case .expired:
            return "Scans still run. Destructive actions are paused until you activate a license."
        case .none:
            return "Activate a license to enable destructive actions."
        }
    }

    private var statusSubtitle: String {
        switch model.state {
        case .licensed: "Thanks for funding development."
        case .trial: "Honesty setting one hundred percent."
        case .expired, .none: "Or build from source — fully unlocked under AGPL-3.0."
        }
    }
}
