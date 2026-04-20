import Foundation

/// Presentation state for the AI explanation sheet. Owned by
/// `AIExplanationController`; consumed by `AIExplanationSheet`.
public enum AIExplanationPresentation: Sendable, Identifiable {
    /// Request in flight — show a spinner and a cancel button.
    case loading(ScanResult)
    /// Model returned an explanation (either AI-generated or YAML fallback).
    case loaded(ScanResult, AIExplanation)
    /// Request failed — show the message and a retry.
    case failed(ScanResult, message: String)

    public var result: ScanResult {
        switch self {
        case .loading(let r), .loaded(let r, _), .failed(let r, _):
            return r
        }
    }

    /// Identity is the underlying result so SwiftUI's `.sheet(item:)` treats
    /// state transitions within the same request as the same sheet (no flicker
    /// between loading → loaded).
    public var id: String { result.id }
}

/// Wraps an `AIServiceProtocol` with UI presentation state so any scan view
/// can trigger an explanation without owning its own service instance or
/// re-implementing the loading/error plumbing. One controller per app — held
/// as a `@StateObject` on `MainContentView` and threaded down via
/// `.environmentObject`.
///
/// The controller also absorbs the asymmetry between `LocalAIService.explain`
/// (needs a `ScanRule`) and the scan UI (only has a `ScanResult`): it derives
/// a minimal canonical rule from the result's own fields. The result already
/// carries every field the prompt builder and fallback path read, because
/// adapters copy them from the matched YAML rule at scan time.
@MainActor
public final class AIExplanationController: ObservableObject {
    @Published public private(set) var presentation: AIExplanationPresentation?

    private let service: any AIServiceProtocol
    private var activeTask: Task<Void, Never>?

    public init(service: any AIServiceProtocol) {
        self.service = service
    }

    /// True while an explanation request is in flight. Useful for dimming
    /// the list or disabling the Explain button during generation.
    public var isBusy: Bool {
        if case .loading = presentation { return true }
        return false
    }

    /// Whether a downloaded model is available on disk. Forwarded from the
    /// underlying service so the sheet can surface a "Download model" CTA
    /// when the explanation fell back to the YAML rule.
    public var isModelAvailable: Bool {
        service.isModelAvailable
    }

    /// Kick off an explanation request. Any in-flight request is cancelled
    /// and replaced; only the latest call wins (e.g. user hovers two rows
    /// in quick succession).
    public func explain(_ result: ScanResult) {
        activeTask?.cancel()
        presentation = .loading(result)
        let rule = Self.derivedRule(from: result)
        let service = self.service
        activeTask = Task { [weak self] in
            do {
                let explanation = try await service.explain(result: result, rule: rule)
                try Task.checkCancellation()
                guard let self else { return }
                // Guard against a stale response overwriting a newer request.
                if self.presentation?.result.id == result.id {
                    self.presentation = .loaded(result, explanation)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                if self.presentation?.result.id == result.id {
                    self.presentation = .failed(result, message: error.localizedDescription)
                }
            }
        }
    }

    /// Re-run the last failed request.
    public func retry() {
        guard case .failed(let result, _) = presentation else { return }
        explain(result)
    }

    /// Clear presentation state (closes the sheet).
    public func dismiss() {
        activeTask?.cancel()
        activeTask = nil
        presentation = nil
    }

    /// Synthesize a `ScanRule` from a `ScanResult`. Every field the prompt
    /// builder (`MLXInferenceEngine.buildPrompt`) and the fallback path
    /// (`LocalAIService.explain` → `rule.explanation`) read is already on
    /// the result — the adapter layer copies them from the matched YAML rule
    /// at scan time. The synthesized rule is not persisted and not used for
    /// classification; it's purely a transport to the engine.
    static func derivedRule(from result: ScanResult) -> ScanRule {
        ScanRule(
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
}
