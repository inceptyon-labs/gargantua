import SwiftUI

struct ClaudeCodeAgentPendingApprovalOverlay: View {
    let pending: ClaudeCodeAgentPendingApproval?
    let lastAssistantText: String
    let onAcknowledgeUnresolved: () -> Void
    let onConfirm: (CleanupMethod) -> Void
    let onCancel: () -> Void

    var body: some View {
        if let pending {
            VStack(spacing: GargantuaSpacing.space3) {
                if !lastAssistantText.isEmpty, !pending.items.isEmpty {
                    AgentReasoningCard(text: lastAssistantText)
                }
                if !pending.unresolvedItemIDs.isEmpty {
                    SmartUninstallerNote(
                        unresolvedCount: pending.unresolvedItemIDs.count,
                        // When the modal is also showing, dismiss is
                        // handled by the modal's own buttons; the note
                        // is purely informational. When there are no
                        // resolved items, the note IS the modal — it
                        // needs its own dismiss path.
                        onAcknowledge: pending.items.isEmpty ? onAcknowledgeUnresolved : nil
                    )
                }
                if !pending.items.isEmpty {
                    ConfirmationModalView(
                        items: pending.items,
                        onConfirm: onConfirm,
                        onCancel: onCancel
                    )
                }
            }
            .transition(.opacity)
        }
    }
}

/// Inline companion to `ConfirmationModalView` shown when the agent's
/// `mcp__gargantua__clean` call referenced item IDs the host scan cache
/// couldn't resolve — typically app-bundle paths the agent wrote out by
/// hand instead of scan-cache IDs. We can't run those through
/// `CleanupEngine` (it expects `ScanResult`s), so we explain the gap and
/// point the user at Smart Uninstaller for app removal.
///
/// `onAcknowledge` is non-nil only when the note is standing in for the
/// modal (every proposed ID was unresolved). In the mixed case the modal
/// owns dismissal and this view is purely informational.
private struct SmartUninstallerNote: View {
    let unresolvedCount: Int
    let onAcknowledge: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
                Image(systemName: "app.badge.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(GargantuaColors.review)
                    .frame(width: 20, alignment: .center)

                VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                    Text(headline)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)

                    Text("These items aren't in the scan cache — likely application bundles. Use Smart Uninstaller to remove apps cleanly.")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let onAcknowledge {
                HStack {
                    Spacer()
                    Button(action: onAcknowledge) {
                        Text("Got it")
                            .font(GargantuaFonts.label)
                            .foregroundStyle(.white)
                            .padding(.horizontal, GargantuaSpacing.space4)
                            .padding(.vertical, GargantuaSpacing.space2)
                            .background(GargantuaColors.accent)
                            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(GargantuaSpacing.space4)
        .frame(maxWidth: 520, alignment: .leading)
        .background(GargantuaColors.surface2)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.review.opacity(0.6), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
    }

    private var headline: String {
        let noun = unresolvedCount == 1 ? "item" : "items"
        return "Claude proposed \(unresolvedCount) additional \(noun) — use Smart Uninstaller"
    }
}

/// Shows the agent's most recent prose summary above the cleanup review
/// modal so the user understands WHY each row was selected. The agent's
/// prompt asks for a one-or-two-sentence rationale alongside the clean
/// call ("These are stale Adobe caches the parent app no longer reads,
/// safe to remove for a macOS upgrade.") — surfacing it here closes the
/// gap where the user couldn't see the agent's reasoning without scrolling
/// the transcript.
private struct AgentReasoningCard: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GargantuaColors.accent)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                Text("WHY THESE ITEMS")
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(GargantuaColors.ink3)

                Text(text)
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(GargantuaSpacing.space4)
        .frame(maxWidth: 520, alignment: .leading)
        .background(GargantuaColors.surface1)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.accent.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
    }
}

/// Non-dismissable overlay shown while CleanupEngine is running. Blocks
/// interaction so the user can't fire a second cleanup mid-flight, surfaces
/// a per-item counter, and uses the AccretionDisk spinner to match the
/// app's ambient motion language. Without this overlay, large permanent
/// deletes left the user staring at a beach ball with no signal that
/// anything was happening.
struct CleanupProgressOverlay: View {
    let progress: Int
    let total: Int

    var body: some View {
        ZStack {
            GargantuaColors.void_.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: GargantuaSpacing.space4) {
                AccretionDiskView(activityRate: 60, size: 56)
                    .frame(width: 80, height: 80)

                VStack(spacing: GargantuaSpacing.space1) {
                    Text("Cleaning…")
                        .font(GargantuaFonts.heading)
                        .foregroundStyle(GargantuaColors.ink)

                    Text(progressLabel)
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink2)
                        .contentTransition(.numericText())
                }

                Text("Don't quit Gargantua until this finishes.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
            .padding(.horizontal, GargantuaSpacing.space6)
            .padding(.vertical, GargantuaSpacing.space5)
            .background(GargantuaColors.surface1)
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                    .stroke(GargantuaColors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
    }

    private var progressLabel: String {
        if total <= 0 {
            return "Preparing…"
        }
        return "\(progress) of \(total)"
    }
}
