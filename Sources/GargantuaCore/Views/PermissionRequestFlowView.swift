import SwiftUI

// MARK: - Flow Container

/// First-launch permission request flow.
///
/// Steps through Full Disk Access and Automation permission screens.
/// Each screen explains what the permission unlocks with a skip option.
/// The flow completes by setting `hasCompletedOnboarding` to `true`.
public struct PermissionRequestFlowView: View {
    @Binding var isComplete: Bool
    @State private var step = 0

    public init(isComplete: Binding<Bool>) {
        self._isComplete = isComplete
    }

    public var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()

            Group {
                switch step {
                case 0:
                    FullDiskAccessScreen(onContinue: advance, onSkip: advance)
                        .transition(.push(from: .trailing))
                default:
                    AutomationScreen(onContinue: finish, onSkip: finish)
                        .transition(.push(from: .trailing))
                }
            }
            .animation(.easeOut(duration: 0.2), value: step)
        }
    }

    private func advance() {
        step += 1
    }

    private func finish() {
        isComplete = true
    }
}

// MARK: - Full Disk Access Screen

private struct FullDiskAccessScreen: View {
    var onContinue: () -> Void
    var onSkip: () -> Void

    var body: some View {
        PermissionScreen(
            icon: "externaldrive.fill.badge.checkmark",
            title: "Full Disk Access",
            explanation: "Scan system caches, Library, Mail attachments",
            detail: "Gargantua needs Full Disk Access to find hidden caches and large files buried in protected directories. Without it, scans are limited to your home folder.",
            settingsURL: fullDiskAccessURL,
            onContinue: onContinue,
            onSkip: onSkip
        )
    }

    private var fullDiskAccessURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    }
}

// MARK: - Automation Screen

private struct AutomationScreen: View {
    var onContinue: () -> Void
    var onSkip: () -> Void

    var body: some View {
        PermissionScreen(
            icon: "arrow.3.trianglepath",
            title: "Automation",
            explanation: "Move files to Trash via Finder",
            detail: "Gargantua uses Finder automation to safely move files to Trash instead of permanently deleting them. You can always restore from Trash if needed.",
            settingsURL: automationURL,
            onContinue: onContinue,
            onSkip: onSkip
        )
    }

    private var automationURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
    }
}

// MARK: - Shared Permission Screen Layout

private struct PermissionScreen: View {
    let icon: String
    let title: String
    let explanation: String
    let detail: String
    let settingsURL: URL
    let onContinue: () -> Void
    let onSkip: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: GargantuaSpacing.space6) {
            Spacer()

            // Icon
            Image(systemName: icon)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(GargantuaColors.accent)

            // Title + explanation
            VStack(spacing: GargantuaSpacing.space2) {
                Text(title)
                    .font(GargantuaFonts.display)
                    .foregroundStyle(GargantuaColors.ink)

                Text(explanation)
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink2)
            }

            // Detail paragraph
            Text(detail)
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            // Actions
            VStack(spacing: GargantuaSpacing.space3) {
                Button {
                    openURL(settingsURL)
                } label: {
                    Text("Open System Settings")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(.white)
                        .frame(maxWidth: 240)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(GargantuaColors.accent, in: RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)

                Button {
                    onContinue()
                } label: {
                    Text("Continue")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                        .frame(maxWidth: 240)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(GargantuaColors.surface3, in: RoundedRectangle(cornerRadius: GargantuaRadius.small))
                        .overlay(
                            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                                .stroke(GargantuaColors.borderEm, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            // Skip — always available, no guilt
            Button {
                onSkip()
            } label: {
                Text("Skip")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink4)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
