import Foundation
import SwiftUI

/// One per-tool card inside ``DeveloperToolsView``. Layout:
///
/// ```
/// [icon]  Tool name vX.Y     [status chip]      [reclaimable bytes]
/// [ command preview row ]
/// ── Cleanup actions ─────────────────────────────────────────────
/// [ ▶ Run name           safety chip                        Run ]
/// [ ▶ Run name           safety chip                        Run ]
/// ─────────────────────────────────────────────────────────────
/// [ ▶ Show what would be removed (12 items, 3.4 GB) ]    ← collapsed
/// ```
///
/// The actions block sits above the dry-run "would remove…" preview so users
/// don't have to scroll past dozens of homebrew bottle rows to find the Run
/// buttons. The preview list lives inside a `DisclosureGroup` collapsed by
/// default; the surrounding header carries the reclaimable summary so the
/// number is visible without expanding.
///
/// For Docker, when the daemon isn't running the preview/operations are
/// replaced by a single inline "Start Docker" CTA. When it is running, a
/// small "Stop" affordance sits next to the status chip.
struct DeveloperToolPanel: View {
    let availability: DeveloperToolAvailability
    let preview: DeveloperToolsView.PreviewState
    let executingOperationID: DeveloperToolCleanupOperation.ID?
    let executionNotices: [DeveloperToolCleanupOperation.ID: DeveloperToolsView.ExecutionNotice]
    let dockerLifecycleActivity: DeveloperToolsView.DockerLifecycleActivity?
    let onRetry: () -> Void
    let onRun: (DeveloperToolCleanupOperation, DeveloperToolPreview) -> Void
    let onRetryOperation: (DeveloperToolCleanupOperation, DeveloperToolPreview) -> Void
    let onStartDocker: () -> Void
    let onStopDocker: () -> Void

    @State private var isPreviewExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            toolHeader
            Rectangle()
                .fill(GargantuaColors.borderSoft)
                .frame(height: 1)

            switch preview {
            case .loading:
                HStack(spacing: GargantuaSpacing.space2) {
                    AccretionDiskView(activityRate: 12, size: 14, color: GargantuaColors.accent)
                    Text("Running preview…")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            case .loaded(let p):
                previewBody(p)
            case .daemonStopped(let tool):
                daemonStoppedBody(tool: tool)
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

    // MARK: - Header

    private var toolHeader: some View {
        HStack(alignment: .center, spacing: GargantuaSpacing.space2) {
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
            statusChip
            if availability.tool == .docker, case .loaded = preview {
                stopDockerButton
            }
            Spacer()
            if case .loaded(let p) = preview, p.reclaimableBytes > 0 {
                Text("\(Self.formatBytes(p.reclaimableBytes)) reclaimable")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink)
            }
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        let chip = chipState
        if let chip {
            HStack(spacing: GargantuaSpacing.space1) {
                Circle()
                    .fill(chip.color)
                    .frame(width: 6, height: 6)
                Text(chip.label)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
            }
            .padding(.horizontal, GargantuaSpacing.space2)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(chip.color.opacity(0.15))
            )
        }
    }

    private var stopDockerButton: some View {
        Button(action: onStopDocker) {
            HStack(spacing: GargantuaSpacing.space1) {
                if dockerLifecycleActivity == .stopping {
                    AccretionDiskView(activityRate: 12, size: 10, color: GargantuaColors.ink2)
                } else {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(dockerLifecycleActivity == .stopping ? "Stopping…" : "Stop")
                    .font(GargantuaFonts.caption)
            }
            .foregroundStyle(GargantuaColors.ink2)
            .padding(.horizontal, GargantuaSpacing.space2)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(GargantuaColors.surface3)
            )
            .overlay(
                Capsule().stroke(GargantuaColors.borderSoft, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(dockerLifecycleActivity != nil)
        .help("Quit Docker Desktop")
        .accessibilityLabel("Stop Docker daemon")
    }

    // MARK: - Loaded body

    private func previewBody(_ preview: DeveloperToolPreview) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            commandRow(preview.commandPreview)

            let operations = DeveloperToolsView.operations(for: preview)
            if !operations.isEmpty {
                operationList(operations, preview: preview)
            }

            if preview.items.isEmpty {
                Text("Nothing to clean up.")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink3)
            } else {
                previewDisclosure(preview)
            }
        }
    }

    @ViewBuilder
    private func previewDisclosure(_ preview: DeveloperToolPreview) -> some View {
        let count = preview.items.count
        let suffix: String = {
            if preview.reclaimableBytes > 0 {
                return ", \(Self.formatBytes(preview.reclaimableBytes))"
            }
            return ""
        }()
        // Custom expander instead of `DisclosureGroup` because the system
        // chevron on the void-dark background renders as near-invisible
        // dark gray. We draw the chevron explicitly in `ink2` so the user
        // can find the disclose affordance.
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isPreviewExpanded.toggle()
                }
            } label: {
                HStack(spacing: GargantuaSpacing.space2) {
                    Image(systemName: isPreviewExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(GargantuaColors.ink2)
                        .frame(width: 12, alignment: .center)
                    Text("Show what would be removed (\(count) item\(count == 1 ? "" : "s")\(suffix))")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink2)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(isPreviewExpanded ? "Hide" : "Show") what would be removed, \(count) items"
            )
            .accessibilityAddTraits(.isButton)

            if isPreviewExpanded {
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

    // MARK: - Daemon stopped / failure

    private func daemonStoppedBody(tool: DeveloperTool) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: "powersleep")
                    .foregroundStyle(GargantuaColors.review)
                Text("\(tool.displayName) is installed but the daemon isn't running.")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
            }

            Button(action: onStartDocker) {
                HStack(spacing: GargantuaSpacing.space2) {
                    if dockerLifecycleActivity == .starting {
                        AccretionDiskView(activityRate: 18, size: 14, color: .white)
                        Text("Starting Docker…")
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Start Docker")
                    }
                }
                .font(GargantuaFonts.label)
                .foregroundStyle(.white)
                .padding(.horizontal, GargantuaSpacing.space4)
                .padding(.vertical, GargantuaSpacing.space2)
                .background(
                    RoundedRectangle(cornerRadius: GargantuaRadius.small)
                        .fill(GargantuaColors.accent)
                )
            }
            .buttonStyle(.plain)
            .disabled(dockerLifecycleActivity != nil)
            .accessibilityLabel("Start Docker daemon")
        }
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

    // MARK: - Helpers

    private struct ChipState {
        let label: String
        let color: Color
    }

    /// Status chip presented next to the tool name. Homebrew has no daemon
    /// concept, so we omit it there. Docker shows Running / Starting…
    /// / Stopping… / Daemon stopped.
    private var chipState: ChipState? {
        guard availability.tool == .docker else { return nil }
        if let activity = dockerLifecycleActivity {
            switch activity {
            case .starting: return ChipState(label: "Starting…", color: GargantuaColors.review)
            case .stopping: return ChipState(label: "Stopping…", color: GargantuaColors.review)
            }
        }
        switch preview {
        case .loaded:
            return ChipState(label: "Running", color: GargantuaColors.safe)
        case .daemonStopped:
            return ChipState(label: "Daemon stopped", color: GargantuaColors.review)
        case .loading:
            return ChipState(label: "Checking…", color: GargantuaColors.ink3)
        case .failed:
            return ChipState(label: "Error", color: GargantuaColors.review)
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
