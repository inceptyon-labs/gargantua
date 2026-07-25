import AppKit
import GargantuaLicensing
import OSLog
import SwiftUI

private let summaryLogger = Logger(subsystem: "com.gargantua.core", category: "CleanupSummary")

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
    /// True when the caller's audit write threw. The summary advertises a
    /// "View Audit Trail" affordance, so a cleanup whose record never reached
    /// disk has to say so — otherwise the product's traceability guarantee
    /// silently does not hold for exactly this operation.
    let auditWriteFailed: Bool
    /// Optional "Why?" handler for failed rows — routes the item into the same
    /// explanation sheet the scan lists use. Nil hides the affordance.
    let onExplain: ((ScanResult) -> Void)?
    /// Called with the retry result after "Retry failed items" so the parent
    /// scan list prunes items that were recovered. Nil leaves the parent as-is.
    let onRetried: ((CleanupResult) -> Void)?
    let onDismiss: () -> Void

    @State var sort: SummarySort = .size
    // Expanded by default so the list + sort picker are immediately visible.
    // Users can collapse to the compact card if they want.
    @State var succeededExpanded: Bool = true
    @State var narrative: CleanupNarrative?
    @State var didShowFirstWarmupAtStart: Bool = false
    /// Result after an in-place "Retry failed items" re-run; `nil` until the
    /// user retries. All sections render `shown`, so the summary updates live.
    @State var liveResult: CleanupResult?
    @State var isRetrying: Bool = false
    @State private var blockedReason: BlockReason?
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
        auditWriteFailed: Bool = false,
        onExplain: ((ScanResult) -> Void)? = nil,
        onRetried: ((CleanupResult) -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.result = result
        self.outcomeAccent = outcomeAccent
        self.auditWriteFailed = auditWriteFailed
        self.onExplain = onExplain
        self.onRetried = onRetried
        self.onDismiss = onDismiss
    }

    /// The result the summary renders — the live (retried) one if present,
    /// otherwise the original.
    var shown: CleanupResult { liveResult ?? result }

    /// Overlay retry outcomes onto the current item results by id. A cancelled
    /// `CleanupEngine.clean` returns fewer results than it was given, so this
    /// keeps every original item and updates only the ones the retry re-ran —
    /// no item can silently vanish from the summary.
    static func mergeRetry(into current: [CleanupItemResult], retry: [CleanupItemResult]) -> [CleanupItemResult] {
        var byID = Dictionary(current.map { ($0.item.id, $0) }, uniquingKeysWith: { _, new in new })
        for outcome in retry { byID[outcome.item.id] = outcome }
        return current.map { byID[$0.item.id] ?? $0 }
    }

    /// Re-attempts just the failed items through the privileged helper (e.g.
    /// after the user approved it or quit a blocking app) and merges the
    /// outcome back in, so recovered items move to the success list without a
    /// full rescan.
    @MainActor
    func retryFailed() async {
        let failed = shown.failedItems.map(\.item)
        guard !failed.isEmpty, !isRetrying else { return }
        // Claim the retry synchronously (before the async gate) so a double-tap
        // can't launch two privileged re-runs; `defer` releases it on every path.
        isRetrying = true
        defer { isRetrying = false }
        // Retry re-runs the privileged helper against the failed items, so it is
        // itself a destructive action — front it with the license gate.
        let authorization: DestructiveActionAuthorization
        switch await LicenseGate.shared.authorize(.cleanupRetry) {
        case .failure(let reason):
            blockedReason = reason
            return
        case .success(let granted):
            authorization = granted
        }

        let engine = CleanupEngine(privilegedHelper: XPCPrivilegedUninstallHelper())
        let retry = await engine.clean(
            failed, method: shown.cleanupMethod, observer: nil, authorization: authorization
        )

        // Same audit trail as the original clean — every destructive attempt is
        // recorded, including a retry.
        do {
            try AuditWriter().record(result: retry)
        } catch {
            summaryLogger.warning("Failed to write retry audit entry: \(error.localizedDescription)")
        }

        let merged = Self.mergeRetry(into: shown.itemResults, retry: retry.itemResults)
        liveResult = CleanupResult(itemResults: merged, cleanupMethod: shown.cleanupMethod)

        // Tell the parent which items are now gone so its scan list isn't stale.
        if !retry.succeededItems.isEmpty {
            onRetried?(retry)
        }
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

            let outcome = Self.outcome(for: shown)

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

            if !shown.failedItems.isEmpty {
                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)

                failureSection
            }

            if auditWriteFailed {
                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)

                auditWriteFailureRow
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
        .destructiveActionGate(reason: $blockedReason)
    }
}
