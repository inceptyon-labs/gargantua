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

    @State var isPreviewExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolHeader
            Rectangle()
                .fill(GargantuaColors.borderSoft)
                .frame(height: 1)

            Group {
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .fill(GargantuaColors.surface2)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.border, lineWidth: 1)
        )
    }

    struct ChipState {
        let label: String
        let color: Color
    }

    /// Status chip presented next to the tool name. Homebrew has no daemon
    /// concept, so we omit it there. Docker shows Running / Starting…
    /// / Stopping… / Daemon stopped.
    var chipState: ChipState? {
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

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
