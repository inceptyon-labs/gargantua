import SwiftUI

struct ClaudeCodeAgentApprovalGateSection: View {
    let gates: [ClaudeCodeAgentApprovalGate]
    let onApprove: (ClaudeCodeAgentApprovalGate) -> Void
    let onDeny: (ClaudeCodeAgentApprovalGate) -> Void

    var body: some View {
        if !gates.isEmpty {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                Text("CLEANUP REVIEW")
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(GargantuaColors.ink2)

                ForEach(gates) { gate in
                    ApprovalGateRow(
                        gate: gate,
                        onApprove: { onApprove(gate) },
                        onDeny: { onDeny(gate) }
                    )
                }
            }
        }
    }
}

private struct ApprovalGateRow: View {
    let gate: ClaudeCodeAgentApprovalGate
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tone)
                    .frame(width: 20, alignment: .center)

                VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                    Text(gate.summary)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)

                    Text(gate.rawTranscript)
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(3)
                }

                Spacer()
            }

            HStack(spacing: GargantuaSpacing.space2) {
                Button(action: onApprove) {
                    Label(primaryActionTitle, systemImage: primaryActionIcon)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(primaryActionTone)
                        .padding(.horizontal, GargantuaSpacing.space3)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(primaryActionTone.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
                .disabled(gate.status != .pending)
                .help(primaryActionHelp)

                Button(action: onDeny) {
                    Label(secondaryActionTitle, systemImage: "xmark.circle.fill")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.protected_)
                        .padding(.horizontal, GargantuaSpacing.space3)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(GargantuaColors.protected_.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
                .disabled(gate.status != .pending)
                .help(secondaryActionHelp)

                Text(statusLabel)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }

            if gate.status == .pending, isReviewGate {
                Text("Review opens the cleanup modal. Nothing is removed until you confirm there.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(GargantuaSpacing.space4)
        .background(GargantuaColors.surface1)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(tone.opacity(0.65), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
    }

    private var icon: String {
        switch gate.status {
        case .pending: "hand.raised.fill"
        case .approved: "checkmark.shield.fill"
        case .denied: "xmark.shield.fill"
        }
    }

    private var tone: Color {
        switch gate.status {
        case .pending: GargantuaColors.review
        case .approved: GargantuaColors.safe
        case .denied: GargantuaColors.protected_
        }
    }

    private var isReviewGate: Bool {
        !gate.proposedItemIDs.isEmpty
    }

    private var primaryActionTitle: String {
        isReviewGate ? "Review" : "Approve"
    }

    private var primaryActionIcon: String {
        isReviewGate ? "doc.text.magnifyingglass" : "checkmark.circle.fill"
    }

    private var primaryActionTone: Color {
        isReviewGate ? GargantuaColors.review : GargantuaColors.safe
    }

    private var primaryActionHelp: String {
        isReviewGate
            ? "Open the cleanup review modal before approving."
            : "Approve this gate."
    }

    private var secondaryActionTitle: String {
        isReviewGate ? "Reject" : "Deny"
    }

    private var secondaryActionHelp: String {
        isReviewGate
            ? "Reject this cleanup proposal without removing anything."
            : "Deny this gate."
    }

    private var statusLabel: String {
        switch gate.status {
        case .pending:
            isReviewGate ? "Needs review" : "Pending"
        case .approved:
            "Approved"
        case .denied:
            isReviewGate ? "Rejected" : "Denied"
        }
    }
}
