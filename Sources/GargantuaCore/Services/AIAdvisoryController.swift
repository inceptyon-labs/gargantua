import Foundation

/// Presentation state for the AI advisory sheet. Owned by
/// `AIAdvisoryController`; consumed by `AIAdvisorySheet`.
public enum AIAdvisoryPresentation: Sendable, Identifiable, Equatable {
    /// Request in flight — show a spinner.
    case loading
    /// Batch returned. May contain AI-sourced or YAML-sourced entries per item.
    case loaded([ScanResultAdvisory])
    /// Request failed — show the message and a retry.
    case failed(message: String)

    /// There's at most one advisory session at a time, so a constant id is
    /// fine: SwiftUI's `.sheet(item:)` re-opens only when `presentation`
    /// flips between nil and a value, not on case transitions.
    public var id: String { "advisory" }
}

/// Wraps `LocalAIService.advisory(for:rules:)` with UI presentation state so
/// any scan view can trigger an advisory without owning its own service or
/// re-implementing the loading/error plumbing. One controller per app — held
/// as a `@StateObject` on `MainContentView` and reached via a closure handed
/// to scan views.
///
/// Like `AIExplanationController`, this derives a minimal canonical rule from
/// each `ScanResult` at request time; the result already carries every field
/// the engine's prompt builder and the YAML fallback path read.
@MainActor
public final class AIAdvisoryController: ObservableObject {
    @Published public private(set) var presentation: AIAdvisoryPresentation?

    private let service: LocalAIService
    private var activeTask: Task<Void, Never>?
    private var lastRequestedResults: [ScanResult] = []

    public init(service: LocalAIService) {
        self.service = service
    }

    /// True while an advisory request is in flight.
    public var isBusy: Bool {
        if case .loading = presentation { return true }
        return false
    }

    /// Whether a downloaded model is available on disk.
    public var isModelAvailable: Bool {
        service.isModelAvailable
    }

    /// Kick off an advisory request for the supplied results. Non-review
    /// items are filtered out by `LocalAIService.advisory`, so callers can
    /// pass a full scan result array. Any in-flight request is cancelled
    /// and replaced; only the latest call wins.
    public func request(for results: [ScanResult]) {
        activeTask?.cancel()
        presentation = .loading
        lastRequestedResults = results
        let rules = Self.derivedRules(for: results)
        let service = self.service
        activeTask = Task { [weak self] in
            do {
                let advisories = try await service.advisory(for: results, rules: rules)
                try Task.checkCancellation()
                guard let self else { return }
                if case .loading = self.presentation {
                    self.presentation = .loaded(advisories)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                if case .loading = self.presentation {
                    self.presentation = .failed(message: error.localizedDescription)
                }
            }
        }
    }

    /// Re-run the last failed request.
    public func retry() {
        guard case .failed = presentation else { return }
        request(for: lastRequestedResults)
    }

    /// Clear presentation state (closes the sheet).
    public func dismiss() {
        activeTask?.cancel()
        activeTask = nil
        presentation = nil
    }

    /// Synthesize the `[ScanResult.id: ScanRule]` map the service expects.
    /// Same derived-rule trick as `AIExplanationController.derivedRule`:
    /// each result already carries the rule fields the engine reads, because
    /// adapters copy them at scan time.
    static func derivedRules(for results: [ScanResult]) -> [String: ScanRule] {
        var map: [String: ScanRule] = [:]
        map.reserveCapacity(results.count)
        for result in results {
            map[result.id] = ScanRule(
                id: result.category,
                name: result.name,
                paths: [result.path],
                safety: result.safety,
                confidence: result.confidence,
                explanation: result.explanation,
                source: result.source,
                regenerates: result.regenerates,
                regenerateCommand: result.regenerateCommand,
                category: result.category,
                tags: result.tags
            )
        }
        return map
    }
}
