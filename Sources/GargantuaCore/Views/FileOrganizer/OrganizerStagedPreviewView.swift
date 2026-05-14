import AppKit
import SwiftUI

/// AI file organizer's staged-preview surface. Switches between phases
/// of `OrganizerSessionState` (idle → proposing → preview → applying →
/// applied), preserving the dark "void" background and the project's
/// signature spinner (AccretionDiskView, not ProgressView).
public struct OrganizerStagedPreviewView: View {
    @ObservedObject var session: OrganizerSessionState
    @State var expandedPlanIDs: Set<UUID> = []
    @State var customFolders: [URL] = []

    let folderStore: OrganizerCustomFolderStore
    let mlxAvailabilityProvider: @MainActor () -> Bool

    public init(
        session: OrganizerSessionState,
        folderStore: OrganizerCustomFolderStore = OrganizerCustomFolderStore(),
        mlxAvailabilityProvider: @escaping @MainActor () -> Bool = { false }
    ) {
        self.session = session
        self.folderStore = folderStore
        self.mlxAvailabilityProvider = mlxAvailabilityProvider
    }

    public var body: some View {
        ZStack {
            GargantuaColors.void_.ignoresSafeArea()

            switch session.phase {
            case .idle:
                idleState
            case .proposing:
                statusState(message: proposingStatusMessage)
            case .preview:
                previewState
            case .applying:
                statusState(message: "Moving files…")
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
        .onAppear { customFolders = folderStore.load() }
    }

    // MARK: - Working states

    func statusState(message: String) -> some View {
        OrganizerStatusView(message: message, onCancel: { session.cancelInProgress() })
    }

    // MARK: - Preview

    private var previewState: some View {
        VStack(spacing: 0) {
            previewHeader
            previewTrustStrip
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
                Text("AI-proposed groupings")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                Text(previewSummary)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
            Spacer()
            prominentBackendBadge
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
    private var prominentBackendBadge: some View {
        if let proposal = session.proposal {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: proposal.backend == .cloud ? "cloud.fill" : "cpu")
                    .font(.system(size: 11))
                Text(badgeLabel(for: proposal.backend))
                    .font(GargantuaFonts.caption)
                    .fontWeight(.medium)
            }
            .foregroundStyle(GargantuaColors.accent)
            .padding(.horizontal, GargantuaSpacing.space2)
            .padding(.vertical, 4)
            .background(GargantuaColors.accent.opacity(0.12))
            .clipShape(Capsule())
        }
    }

    private func badgeLabel(for backend: ProposalBackend) -> String {
        switch backend {
        case .local:
            return "On-device rules"
        case .cloud:
            let modelID = CloudAIConfigurationStore().load().model
            return AnthropicModelCatalog.bakedInModels
                .first(where: { $0.id == modelID })?
                .displayName ?? "Cloud AI"
        }
    }

    private var previewTrustStrip: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 11))
                .foregroundStyle(GargantuaColors.safe)
            Text("Nothing moves until you click Apply. Every move is recorded and reversible.")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink2)
            Spacer()
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(GargantuaColors.surface1)
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

    private var proposingStatusMessage: String {
        switch OrganizerBackendPreference.stored() {
        case .local: return "Scanning folder…"
        case .mlx: return "Asking your local model for groupings…"
        case .cloud: return "Asking Cloud AI for groupings…"
        case .claudeCode: return "Asking the Claude Code agent for groupings…"
        }
    }

    private var applyButtonLabel: String {
        let fileCount = session.proposal?.plans.reduce(0) { $0 + $1.moves.count } ?? 0
        return fileCount > 0 ? "Apply (\(fileCount) move\(fileCount == 1 ? "" : "s"))" : "Apply"
    }
}
