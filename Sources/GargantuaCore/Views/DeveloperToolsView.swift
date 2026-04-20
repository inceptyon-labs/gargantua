import Foundation
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.gargantua.core", category: "DeveloperToolsView")

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

    private let availabilityProvider: AvailabilityProvider
    private let previewProvider: PreviewProvider

    @State private var phase: Phase = .loading

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

    public init(
        availabilityProvider: @escaping AvailabilityProvider = { DeveloperToolPreviewAdapter().availability() },
        previewProvider: @escaping PreviewProvider = { try DeveloperToolPreviewAdapter().preview($0) }
    ) {
        self.availabilityProvider = availabilityProvider
        self.previewProvider = previewProvider
    }

    /// Build the initial phase from availability results, seeding installed tools
    /// with `.loading` so the UI can show spinners while previews resolve.
    ///
    /// When no tools report installed, short-circuit to `.empty` so the UI can
    /// render the "nothing detected" state without ever entering the results
    /// layout.
    static func deriveInitialPhase(availabilities: [DeveloperToolAvailability]) -> Phase {
        let installed = availabilities.filter(\.isInstalled)
        if installed.isEmpty {
            return .empty(availabilities: availabilities)
        }
        var previews: [DeveloperTool: PreviewState] = [:]
        for item in installed {
            previews[item.tool] = .loading
        }
        return .ready(availabilities: availabilities, previews: previews)
    }

    /// Fold a new per-tool preview result into the phase.
    ///
    /// A preview completion on an `.empty` or `.loading` phase is ignored — the
    /// view has moved on (empty state) or hasn't resolved availabilities yet and
    /// the completion doesn't fit either model.
    static func applyPreviewResult(
        tool: DeveloperTool,
        result: Result<DeveloperToolPreview, Error>,
        to phase: Phase
    ) -> Phase {
        guard case .ready(let availabilities, var previews) = phase else {
            return phase
        }
        switch result {
        case .success(let preview):
            previews[tool] = .loaded(preview)
        case .failure(let error):
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            previews[tool] = .failed(message)
        }
        return .ready(availabilities: availabilities, previews: previews)
    }

    public var body: some View {
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
                        onRetry: {
                            Task { await reloadPreview(for: availability.tool) }
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

    // MARK: Orchestration

    private func load() async {
        let availabilities = availabilityProvider()
        let initial = Self.deriveInitialPhase(availabilities: availabilities)
        await MainActor.run { phase = initial }

        guard case .ready = initial else { return }
        let installed = availabilities.filter(\.isInstalled).map(\.tool)
        for tool in installed {
            await loadPreview(for: tool)
        }
    }

    private func loadPreview(for tool: DeveloperTool) async {
        let result: Result<DeveloperToolPreview, Error>
        do {
            let preview = try previewProvider(tool)
            result = .success(preview)
        } catch {
            logger.error("Preview for \(tool.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            result = .failure(error)
        }
        await MainActor.run {
            phase = Self.applyPreviewResult(tool: tool, result: result, to: phase)
        }
    }

    private func reloadPreview(for tool: DeveloperTool) async {
        await MainActor.run {
            if case .ready(let availabilities, var previews) = phase {
                previews[tool] = .loading
                phase = .ready(availabilities: availabilities, previews: previews)
            }
        }
        await loadPreview(for: tool)
    }
}

// MARK: - Per-tool panel

private struct DeveloperToolPanel: View {
    let availability: DeveloperToolAvailability
    let preview: DeveloperToolsView.PreviewState
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            toolHeader
            Rectangle()
                .fill(GargantuaColors.borderSoft)
                .frame(height: 1)

            switch preview {
            case .loading:
                HStack(spacing: GargantuaSpacing.space2) {
                    ProgressView().controlSize(.small)
                    Text("Running preview…")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            case .loaded(let p):
                previewBody(p)
            case .failed(let message):
                failureBody(message: message)
            }
        }
        .padding(GargantuaSpacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .fill(GargantuaColors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.border, lineWidth: 1)
        )
    }

    private var toolHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space2) {
            Image(systemName: icon(for: availability.tool))
                .foregroundStyle(GargantuaColors.ink2)
                .frame(width: 18, alignment: .center)
            Text(availability.tool.displayName)
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)
            if let version = availability.version {
                Text(version)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(1)
            }
            Spacer()
            if case .loaded(let p) = preview, p.reclaimableBytes > 0 {
                Text("\(Self.formatBytes(p.reclaimableBytes)) reclaimable")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink)
            }
        }
    }

    private func previewBody(_ preview: DeveloperToolPreview) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            commandRow(preview.commandPreview)

            if preview.items.isEmpty {
                Text("Nothing to clean up.")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink3)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(preview.items) { item in
                        previewRow(item)
                        if item.id != preview.items.last?.id {
                            Rectangle()
                                .fill(GargantuaColors.borderSoft)
                                .frame(height: 1)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: GargantuaRadius.small)
                        .fill(GargantuaColors.surface1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: GargantuaRadius.small)
                        .stroke(GargantuaColors.borderSoft, lineWidth: 1)
                )
            }
        }
    }

    private func commandRow(_ command: [String]) -> some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "terminal")
                .foregroundStyle(GargantuaColors.ink4)
            Text(command.joined(separator: " "))
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(GargantuaColors.ink3)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .fill(GargantuaColors.surface3)
        )
    }

    private func previewRow(_ item: DeveloperToolPreviewItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space3) {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                Text(item.title)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = item.detail {
                    Text(detail)
                        .font(GargantuaFonts.monoPath)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: GargantuaSpacing.space3)
            if let bytes = item.reclaimableBytes {
                Text(Self.formatBytes(bytes))
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)
            } else {
                Text("—")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink4)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
    }

    private func failureBody(message: String) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(GargantuaColors.review)
                Text("Preview failed")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
            }
            Text(message)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .lineLimit(5)
                .multilineTextAlignment(.leading)

            Button {
                onRetry()
            } label: {
                Text("Try again")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                    .padding(.horizontal, GargantuaSpacing.space3)
                    .padding(.vertical, GargantuaSpacing.space1)
                    .background(
                        RoundedRectangle(cornerRadius: GargantuaRadius.small)
                            .fill(GargantuaColors.surface3)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private func icon(for tool: DeveloperTool) -> String {
        switch tool {
        case .homebrew: "mug"
        case .docker: "shippingbox"
        }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
