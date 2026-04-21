import Foundation
import SwiftUI

// MARK: - Container

/// Availability-gated read-only panel for Homebrew and Docker.
///
/// Shows a panel per tool only when ``DeveloperToolPreviewAdapter/availability()``
/// reports it installed. For each installed tool, renders the dry-run preview
/// from ``DeveloperToolPreviewAdapter/preview(_:)`` with reclaimable sizes.
/// When nothing is installed, renders an empty state.
///
/// Destructive operations are intentionally not exposed — Phase 3 will route
/// execution through the Trust Layer / ``ConfirmationModalView``. The visible
/// command preview lets the user see exactly what would run.
public struct DeveloperToolsView: View {
    public typealias AvailabilityProvider = @Sendable () -> [DeveloperToolAvailability]
    public typealias PreviewProvider = @Sendable (DeveloperTool) throws -> DeveloperToolPreview
    public typealias ExecutionProvider = @Sendable (
        DeveloperToolCleanupOperation,
        DeveloperToolPreview,
        ConfirmationTier
    ) throws -> DeveloperToolExecutionResult

    let availabilityProvider: AvailabilityProvider
    let previewProvider: PreviewProvider
    let executionProvider: ExecutionProvider

    @State var phase: Phase = .loading
    @State var pendingExecution: ExecutionRequest?
    @State var executingOperationID: DeveloperToolCleanupOperation.ID?
    @State var executionNotices: [DeveloperToolCleanupOperation.ID: ExecutionNotice] = [:]

    public enum Phase: Equatable {
        case loading
        case ready(availabilities: [DeveloperToolAvailability], previews: [DeveloperTool: PreviewState])
        case empty(availabilities: [DeveloperToolAvailability])
    }

    public enum PreviewState: Equatable {
        case loading
        case loaded(DeveloperToolPreview)
        case failed(String)
    }

    struct ExecutionRequest: Equatable, Identifiable {
        let operation: DeveloperToolCleanupOperation
        let preview: DeveloperToolPreview

        var id: String { operation.id }
    }

    enum ExecutionNotice: Equatable {
        case success(String)
        case failure(String)
    }

    public init(
        availabilityProvider: @escaping AvailabilityProvider = { DeveloperToolPreviewAdapter().availability() },
        previewProvider: @escaping PreviewProvider = { try DeveloperToolPreviewAdapter().preview($0) },
        executionProvider: @escaping ExecutionProvider = {
            try DeveloperToolExecutionAdapter().execute($0, preview: $1, confirmationMethod: $2)
        }
    ) {
        self.availabilityProvider = availabilityProvider
        self.previewProvider = previewProvider
        self.executionProvider = executionProvider
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)

                Group {
                    switch phase {
                    case .loading:
                        loadingView
                    case .empty(let availabilities):
                        emptyView(availabilities: availabilities)
                    case .ready(let availabilities, let previews):
                        resultsView(availabilities: availabilities, previews: previews)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(GargantuaColors.void_)

            if let pendingExecution {
                ConfirmationModalView(
                    items: [Self.confirmationItem(for: pendingExecution)],
                    allowsPermanentDelete: false,
                    initialCleanupMethod: .toolNative,
                    onConfirm: { _ in confirmExecution(pendingExecution) },
                    onCancel: { self.pendingExecution = nil }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: pendingExecution)
        .task(id: "developer-tools-load") {
            await load()
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                Text("Developer Tools")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)
                Text("Read-only previews — no changes are made.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
            Spacer()
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space4)
    }

    private var loadingView: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            ProgressView()
                .controlSize(.regular)
            Text("Checking installed tools…")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
        }
    }

    private func emptyView(availabilities: [DeveloperToolAvailability]) -> some View {
        VStack(spacing: GargantuaSpacing.space4) {
            Image(systemName: "hammer")
                .font(.system(size: 32))
                .foregroundStyle(GargantuaColors.ink4)

            VStack(spacing: GargantuaSpacing.space2) {
                Text("No developer tools detected")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)
                Text(
                    "Gargantua looks for Homebrew and Docker in standard install locations. "
                    + "Install one to see dry-run cleanup previews here."
                )
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if availabilities.contains(where: { !$0.isInstalled && $0.error != nil }) {
                VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                    ForEach(availabilities.filter { !$0.isInstalled }, id: \.tool) { availability in
                        HStack(spacing: GargantuaSpacing.space2) {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(GargantuaColors.ink4)
                            Text(availability.tool.displayName)
                                .font(GargantuaFonts.label)
                                .foregroundStyle(GargantuaColors.ink3)
                            Text(availability.error ?? "not found")
                                .font(GargantuaFonts.caption)
                                .foregroundStyle(GargantuaColors.ink4)
                        }
                    }
                }
                .padding(.top, GargantuaSpacing.space2)
            }
        }
        .padding(GargantuaSpacing.space5)
    }

    private func resultsView(
        availabilities: [DeveloperToolAvailability],
        previews: [DeveloperTool: PreviewState]
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
                ForEach(availabilities.filter(\.isInstalled), id: \.tool) { availability in
                    DeveloperToolPanel(
                        availability: availability,
                        preview: previews[availability.tool] ?? .loading,
                        executingOperationID: executingOperationID,
                        executionNotices: executionNotices,
                        onRetry: {
                            Task { await reloadPreview(for: availability.tool) }
                        },
                        onRun: { operation, preview in
                            pendingExecution = ExecutionRequest(operation: operation, preview: preview)
                        },
                        onRetryOperation: { operation, preview in
                            pendingExecution = ExecutionRequest(operation: operation, preview: preview)
                        }
                    )
                }

                let missing = availabilities.filter { !$0.isInstalled }
                if !missing.isEmpty {
                    missingRow(missing: missing)
                }
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space4)
        }
    }

    private func missingRow(missing: [DeveloperToolAvailability]) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            Text("NOT INSTALLED")
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(GargantuaColors.ink4)
            ForEach(missing, id: \.tool) { item in
                HStack(spacing: GargantuaSpacing.space2) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(GargantuaColors.ink4)
                    Text(item.tool.displayName)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink3)
                    Text(item.error ?? "not found")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink4)
                    Spacer()
                }
            }
        }
        .padding(GargantuaSpacing.space3)
        .background(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .fill(GargantuaColors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.borderSoft, lineWidth: 1)
        )
    }
}
