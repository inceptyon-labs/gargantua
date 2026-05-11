import AppKit
import SwiftUI

/// Post-clean summary showing freed space, item status, and undo option.
///
/// Displayed after a cleanup operation completes. Shows:
/// - Total items cleaned and bytes freed
/// - Optional AI-attributed narrative (via `\.cleanupNarrator`)
/// - Failed items (if partial failure)
/// - "Open Audit Trail" link
/// - "Reveal Trash" undo button when applicable
public struct CleanupSummaryView: View {
    let result: CleanupResult
    let outcomeAccent: Color?
    let onDismiss: () -> Void

    @State var sort: SummarySort = .size
    // Expanded by default so the list + sort picker are immediately visible.
    // Users can collapse to the compact card if they want.
    @State var succeededExpanded: Bool = true
    @State var narrative: CleanupNarrative?
    @State var didShowFirstWarmupAtStart: Bool = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.cleanupNarrator) var cleanupNarrator
    @Environment(\.aiEngineNeedsFirstWarmup) var needsFirstWarmup

    /// Sort options for the cleaned-item lists in the summary.
    public enum SummarySort: String, CaseIterable, Sendable {
        case name, size

        var label: String {
            switch self {
            case .name: "Name"
            case .size: "Size"
            }
        }
    }

    /// Outcome classification used to pick the header treatment and decide
    /// whether the success section is meaningful.
    enum SummaryOutcome: Sendable {
        case complete // all items succeeded
        case partial // some succeeded, some failed
        case failed // zero succeeded, >0 failed
    }

    /// Classify a result for header presentation. A result with no items at
    /// all is treated as `.complete` to preserve the "nothing failed" framing
    /// the view showed historically.
    static func outcome(for result: CleanupResult) -> SummaryOutcome {
        if result.failedItems.isEmpty {
            return .complete
        }
        return result.succeededItems.isEmpty ? .failed : .partial
    }

    public init(
        result: CleanupResult,
        outcomeAccent: Color? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.result = result
        self.outcomeAccent = outcomeAccent
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let outcomeAccent {
                Rectangle()
                    .fill(outcomeAccent)
                    .frame(height: 3)
                    .accessibilityHidden(true)
            }

            header

            let outcome = Self.outcome(for: result)

            if cleanupNarrator != nil {
                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)

                if let narrative {
                    CleanupNarrativeSection(narrative: narrative)
                } else {
                    narrativeLoadingSection
                }
            }

            if outcome != .failed {
                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)

                successSection
            }

            if !result.failedItems.isEmpty {
                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)

                failureSection
            }

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            footerActions
        }
        .background(GargantuaColors.surface2)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.border, lineWidth: 1)
        )
        .frame(maxWidth: 480)
        .task(id: result.completedAt) {
            guard let narrator = cleanupNarrator else { return }
            // Clear any prior-cleanup narrative before awaiting, and gate the
            // assignment on `Task.isCancelled` so a late response from a
            // cancelled task can never overwrite the next result's prose.
            narrative = nil
            // Snapshot the warmup state when the task starts so the JIT hint
            // doesn't flicker off mid-call as another sheet completes its
            // first MLX inference.
            didShowFirstWarmupAtStart = needsFirstWarmup
            let value = await narrator(result)
            if !Task.isCancelled { narrative = value }
        }
    }
}
