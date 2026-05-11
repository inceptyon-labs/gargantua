import Foundation
import SwiftUI

// MARK: - Container

/// Availability-gated read-only panel for tool-native developer cleanups.
///
/// Shows a panel per tool only when ``DeveloperToolPreviewAdapter/availability()``
/// reports it installed. For each installed tool, renders the read-only preview
/// from ``DeveloperToolPreviewAdapter/preview(_:)`` with reclaimable sizes when
/// the underlying tool reports them.
/// When nothing is installed, renders an empty state.
///
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
                supportedToolsStrip(availabilities: currentAvailabilities)

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

    var currentAvailabilities: [DeveloperToolAvailability] {
        switch session.phase {
        case .ready(let availabilities, _), .empty(let availabilities):
            availabilities
        case .idle, .loading:
            []
        }
    }
}
