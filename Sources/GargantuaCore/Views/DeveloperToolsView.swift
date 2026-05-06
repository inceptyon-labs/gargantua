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
    let dockerControl: DockerDaemonControl

    /// Session-scoped state hoisted out of the view so navigating away and
    /// back doesn't discard scan results. Owned by `MainContentView`.
    @Bindable var session: DeveloperToolsSessionState

    public enum Phase: Equatable {
        /// User hasn't kicked off a scan yet — we show the CTA. Mirrors the
        /// idle state on Deep Clean / File Health / Duplicate Finder so all
        /// scan flows share one entry pattern.
        case idle
        case loading
        case ready(availabilities: [DeveloperToolAvailability], previews: [DeveloperTool: PreviewState])
        case empty(availabilities: [DeveloperToolAvailability])
    }

    public enum PreviewState: Equatable {
        case loading
        case loaded(DeveloperToolPreview)
        /// Tool is installed but the background daemon (currently only
        /// Docker) isn't running. Driven by
        /// `DeveloperToolPreviewError.daemonNotRunning`.
        case daemonStopped(DeveloperTool)
        case failed(String)
    }

    public enum DockerLifecycleActivity: Equatable {
        case starting
        case stopping
    }

    public struct ExecutionRequest: Equatable, Identifiable, Sendable {
        public let operation: DeveloperToolCleanupOperation
        public let preview: DeveloperToolPreview

        public var id: String { operation.id }

        public init(operation: DeveloperToolCleanupOperation, preview: DeveloperToolPreview) {
            self.operation = operation
            self.preview = preview
        }
    }

    public enum ExecutionNotice: Equatable, Sendable {
        case success(String)
        case failure(String)
    }

    public init(
        session: DeveloperToolsSessionState,
        availabilityProvider: @escaping AvailabilityProvider = { DeveloperToolPreviewAdapter().availability() },
        previewProvider: @escaping PreviewProvider = { try DeveloperToolPreviewAdapter().preview($0) },
        executionProvider: @escaping ExecutionProvider = {
            try DeveloperToolExecutionAdapter().execute($0, preview: $1, confirmationMethod: $2)
        },
        dockerControl: DockerDaemonControl = DockerDaemonControl()
    ) {
        self.session = session
        self.availabilityProvider = availabilityProvider
        self.previewProvider = previewProvider
        self.executionProvider = executionProvider
        self.dockerControl = dockerControl
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)

                Group {
                    switch session.phase {
                    case .idle:
                        idleView
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

            if let pendingExecution = session.pendingExecution {
                ConfirmationModalView(
                    items: [Self.confirmationItem(for: pendingExecution)],
                    allowsPermanentDelete: false,
                    initialCleanupMethod: .toolNative,
                    onConfirm: { _ in confirmExecution(pendingExecution) },
                    onCancel: { session.pendingExecution = nil }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: session.pendingExecution)
    }

    private var idleView: some View {
        VStack(spacing: GargantuaSpacing.space4) {
            GargantuaBrandIcon(
                resourceName: "developer-tools-gargantua-gpt2",
                fallbackSystemName: "hammer",
                fallbackColor: GargantuaColors.ink4
            )

            VStack(spacing: GargantuaSpacing.space2) {
                Text("Scan developer tools")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Text("Checks Homebrew and Docker for cleanup opportunities. Read-only previews — nothing runs without an explicit Run click.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Button(action: startScan) {
                Text("Scan tools")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(
                        RoundedRectangle(cornerRadius: GargantuaRadius.small)
                            .fill(GargantuaColors.accent)
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Sections

    private var header: some View {
        PageHeaderView(
            title: "Developer Tools",
            subtitle: "Run each tool's own cleanup commands. Homebrew, Docker — they know what's safe to release.",
            subtitleStyle: .voice
        ) {
            HStack(spacing: GargantuaSpacing.space3) {
                if session.phase != .idle {
                    backButton
                    refreshButton
                }
            }
        }
    }

    private var backButton: some View {
        Button(action: returnToIdle) {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("Back")
                    .font(GargantuaFonts.label)
            }
            .foregroundStyle(GargantuaColors.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Return to idle")
    }

    private var refreshButton: some View {
        Button {
            Task { await refreshAll() }
        } label: {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                Text("Refresh")
                    .font(GargantuaFonts.label)
            }
            .foregroundStyle(GargantuaColors.accent)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
        .help("Re-check installed tools and reload previews (⌘R)")
        .accessibilityLabel("Refresh previews")
    }

    private var loadingView: some View {
        VStack(spacing: GargantuaSpacing.space4) {
            AccretionDiskView(activityRate: 18, size: 64, color: GargantuaColors.accent)
            Text("Checking installed tools…")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        executingOperationID: session.executingOperationID,
                        executionNotices: session.executionNotices,
                        dockerLifecycleActivity: availability.tool == .docker ? session.dockerLifecycleActivity : nil,
                        onRetry: {
                            Task { await reloadPreview(for: availability.tool) }
                        },
                        onRun: { operation, preview in
                            session.pendingExecution = ExecutionRequest(operation: operation, preview: preview)
                        },
                        onRetryOperation: { operation, preview in
                            session.pendingExecution = ExecutionRequest(operation: operation, preview: preview)
                        },
                        onStartDocker: { startDockerDaemon() },
                        onStopDocker: { stopDockerDaemon() }
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
