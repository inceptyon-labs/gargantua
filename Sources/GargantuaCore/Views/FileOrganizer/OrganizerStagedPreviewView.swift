import SwiftUI

/// AI file organizer's staged-preview surface. Switches between phases
/// of `OrganizerSessionState` (idle → proposing → preview → applying →
/// applied), preserving the dark "void" background and the project's
/// signature spinner (AccretionDiskView, not ProgressView).
public struct OrganizerStagedPreviewView: View {
    @ObservedObject var session: OrganizerSessionState
    @State private var expandedPlanIDs: Set<UUID> = []

    public init(session: OrganizerSessionState) {
        self.session = session
    }

    public var body: some View {
        ZStack {
            GargantuaColors.void_.ignoresSafeArea()

            switch session.phase {
            case .idle:
                idleState
            case .proposing:
                statusState(message: "Reading folder…")
            case .preview:
                previewState
            case .applying:
                statusState(message: "Applying moves…")
            case .applied(let summary):
                appliedState(summary: summary)
            case .undoing:
                statusState(message: "Reversing moves…")
            case .undone(let summary):
                undoneState(summary: summary)
            case .failed(let message):
                failedState(message: message)
            }
        }
    }

    // MARK: - Idle (folder picker)

    private var idleState: some View {
        VStack(spacing: GargantuaSpacing.space5) {
            VStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 44))
                    .foregroundStyle(GargantuaColors.accent)
                Text("Organize a cluttered folder")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)
                Text("AI proposes folder groupings. Review them before any file moves.")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            folderPicker

            Button("Propose groupings for \(session.selectedFolder.displayName)") {
                session.startScan()
            }
            .font(GargantuaFonts.label)
            .foregroundStyle(.white)
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(GargantuaColors.accent)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            .buttonStyle(.plain)
        }
        .padding(GargantuaSpacing.space6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var folderPicker: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            ForEach(OrganizerFolder.allCases) { folder in
                folderChip(folder)
            }
        }
    }

    private func folderChip(_ folder: OrganizerFolder) -> some View {
        let isSelected = session.selectedFolder == folder
        return Button { session.selectedFolder = folder } label: {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: folder.systemImage)
                    .font(.system(size: 12))
                Text(folder.displayName)
                    .font(GargantuaFonts.label)
            }
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(isSelected ? GargantuaColors.accent.opacity(0.18) : GargantuaColors.surface2)
            .foregroundStyle(isSelected ? GargantuaColors.accent : GargantuaColors.ink2)
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .stroke(
                        isSelected ? GargantuaColors.accent : GargantuaColors.borderSoft,
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Working states

    private func statusState(message: String) -> some View {
        VStack(spacing: GargantuaSpacing.space3) {
            AccretionDiskView(activityRate: 2, size: 56)
            Text(message)
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Preview

    private var previewState: some View {
        VStack(spacing: 0) {
            previewHeader
            Divider().overlay(GargantuaColors.border)

            ScrollView {
                VStack(spacing: GargantuaSpacing.space2) {
                    if let plans = session.proposal?.plans, !plans.isEmpty {
                        ForEach(plans) { plan in
                            OrganizerPlanRow(
                                plan: plan,
                                isExpanded: Binding(
                                    get: { expandedPlanIDs.contains(plan.id) },
                                    set: { isOn in
                                        if isOn {
                                            expandedPlanIDs.insert(plan.id)
                                        } else {
                                            expandedPlanIDs.remove(plan.id)
                                        }
                                    }
                                )
                            )
                        }
                    } else {
                        Text("No groupings found. The folder looks already organized.")
                            .font(GargantuaFonts.body)
                            .foregroundStyle(GargantuaColors.ink3)
                            .padding(.top, GargantuaSpacing.space4)
                    }
                }
                .padding(GargantuaSpacing.space3)
            }

            Divider().overlay(GargantuaColors.border)
            previewActionBar
        }
    }

    private var previewHeader: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Proposed groupings")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                Text(previewSummary)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
            Spacer()
            backendBadge
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
        .background(GargantuaColors.surface2)
    }

    private var previewSummary: String {
        guard let proposal = session.proposal else { return "" }
        let planCount = proposal.plans.count
        let fileCount = proposal.plans.reduce(0) { $0 + $1.moves.count }
        return "\(planCount) plan\(planCount == 1 ? "" : "s") · \(fileCount) file\(fileCount == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var backendBadge: some View {
        if let proposal = session.proposal {
            Text(proposal.backend == .cloud ? "Cloud AI" : "On-device")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .padding(.horizontal, GargantuaSpacing.space2)
                .padding(.vertical, 2)
                .background(GargantuaColors.surface3)
                .clipShape(Capsule())
        }
    }

    private var previewActionBar: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Button("Cancel") { session.reset() }
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink2)
                .padding(.horizontal, GargantuaSpacing.space3)
                .padding(.vertical, GargantuaSpacing.space2)
                .background(GargantuaColors.surface2)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                .buttonStyle(.plain)

            Spacer()

            Button(applyButtonLabel) { session.applyAll() }
                .font(GargantuaFonts.label)
                .foregroundStyle(.white)
                .padding(.horizontal, GargantuaSpacing.space4)
                .padding(.vertical, GargantuaSpacing.space2)
                .background(GargantuaColors.accent)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                .buttonStyle(.plain)
            .disabled(session.proposal?.plans.isEmpty ?? true)
            .opacity((session.proposal?.plans.isEmpty ?? true) ? 0.5 : 1)
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
        .background(GargantuaColors.surface2)
    }

    private var applyButtonLabel: String {
        let fileCount = session.proposal?.plans.reduce(0) { $0 + $1.moves.count } ?? 0
        return fileCount > 0 ? "Apply (\(fileCount) move\(fileCount == 1 ? "" : "s"))" : "Apply"
    }
}
