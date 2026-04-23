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

    private let totalSteps = 2

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
                    FullDiskAccessScreen(onContinue: advance, stepIndex: 1, totalSteps: totalSteps)
                        .transition(.push(from: .trailing))
                default:
                    AutomationScreen(onContinue: finish, stepIndex: 2, totalSteps: totalSteps)
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
    let stepIndex: Int
    let totalSteps: Int

    @State private var hasAccess = PermissionChecker.hasFullDiskAccess

    /// Polls permission status so the UI updates after the user grants access
    /// in System Settings without requiring a manual refresh.
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        PermissionScreen(
            icon: "externaldrive.fill.badge.checkmark",
            title: "Full Disk Access",
            explanation: "Unlock full-system scans",
            detail: "Gargantua needs Full Disk Access to find hidden caches and "
                + "large files buried in protected directories. Without it, scans "
                + "are limited to your home folder.",
            unlocks: [
                "System caches, logs, and protected Library folders",
                "More complete cleanup recommendations before you delete anything"
            ],
            limitedMode: "Without this, Gargantua only scans what your home folder exposes.",
            settingsURL: fullDiskAccessURL,
            permissionGranted: hasAccess,
            stepIndex: stepIndex,
            totalSteps: totalSteps,
            onContinue: onContinue
        )
        .onReceive(timer) { _ in
            hasAccess = PermissionChecker.hasFullDiskAccess
        }
        .onAppear {
            if hasAccess {
                DispatchQueue.main.async { onContinue() }
            }
        }
        .onChange(of: hasAccess) {
            if hasAccess { onContinue() }
        }
    }

    private var fullDiskAccessURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    }
}

// MARK: - Automation Screen

private struct AutomationScreen: View {
    var onContinue: () -> Void
    let stepIndex: Int
    let totalSteps: Int

    var body: some View {
        PermissionScreen(
            icon: "arrow.3.trianglepath",
            title: "Automation",
            explanation: "Unlock safer cleanup execution",
            detail: "Gargantua asks Finder to move files to Trash first, then falls "
                + "back to macOS Trash APIs if Automation is unavailable. You can "
                + "restore files from Trash if needed.",
            unlocks: [
                "Use Finder-first cleanup for ordinary files",
                "Keep direct Trash fallback available when Automation is denied"
            ],
            limitedMode: "Without Automation, Gargantua can still scan and use direct Trash APIs for cleanup.",
            settingsURL: automationURL,
            permissionGranted: nil,
            stepIndex: stepIndex,
            totalSteps: totalSteps,
            onContinue: onContinue
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
    let unlocks: [String]
    let limitedMode: String
    let settingsURL: URL
    var permissionGranted: Bool?
    let stepIndex: Int
    let totalSteps: Int
    let onContinue: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: GargantuaSpacing.space5) {
            Spacer()

            VStack(spacing: GargantuaSpacing.space2) {
                Text("STEP \(stepIndex) OF \(totalSteps)")
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(GargantuaColors.ink4)

                PermissionProgressIndicator(stepIndex: stepIndex, totalSteps: totalSteps)
                    .frame(maxWidth: 220)
            }

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

            PermissionContextCard(
                permissionGranted: permissionGranted,
                unlocks: unlocks,
                limitedMode: limitedMode
            )
            .frame(maxWidth: 460)

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
                    Text(permissionGranted == true ? "Continue" : "Continue for Now")
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

            Text("Local-only. You can change this later in System Settings.")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink4)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, GargantuaSpacing.space4)
    }
}

private struct PermissionProgressIndicator: View {
    let stepIndex: Int
    let totalSteps: Int

    var body: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            ForEach(0..<totalSteps, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index < stepIndex ? GargantuaColors.accent : GargantuaColors.surface3)
                    .frame(height: 4)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .stroke(GargantuaColors.borderSoft, lineWidth: 1)
        }
    }
}

private struct PermissionContextCard: View {
    let permissionGranted: Bool?
    let unlocks: [String]
    let limitedMode: String

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            if let granted = permissionGranted {
                HStack(spacing: GargantuaSpacing.space2) {
                    Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 14))
                    Text(granted ? "Permission granted" : "Recommended for best results")
                        .font(GargantuaFonts.label)
                }
                .foregroundStyle(granted ? GargantuaColors.safe : GargantuaColors.review)
            }

            VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
                Text("What this unlocks")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                ForEach(unlocks, id: \.self) { item in
                    HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(GargantuaColors.safe)
                            .padding(.top, 3)
                        Text(item)
                            .font(GargantuaFonts.body)
                            .foregroundStyle(GargantuaColors.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                Text("If you continue without it")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                Text(limitedMode)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(GargantuaSpacing.space4)
        .background(GargantuaColors.surface1)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium, style: .continuous)
                .stroke(GargantuaColors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium, style: .continuous))
    }
}
