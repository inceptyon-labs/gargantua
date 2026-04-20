import Foundation

/// An advisory note produced by the AI layer about a scan result.
///
/// Advisories are purely informational — they never mutate `ScanResult.safety`
/// or any persisted record. PRD §2.5 and §6.2 are explicit that AI output is
/// advisory-only; the YAML rule is the single source of truth for
/// classification. `suggestedSafety` is the AI's opinion and is surfaced to
/// the user only if they explicitly ask for it.
public struct ScanResultAdvisory: Sendable, Equatable {
    /// The id of the `ScanResult` this advisory refers to.
    public let resultId: String

    /// Short human-readable rationale explaining why the user might want to
    /// reconsider this item. Drawn from the inference engine (or the YAML
    /// rule text on engine failure).
    public let rationale: String

    /// The AI's *suggested* alternative safety level. Presented to the user
    /// for review; never applied to the underlying `ScanResult`. Defaults to
    /// the result's current safety when the engine has no specific opinion.
    public let suggestedSafety: SafetyLevel

    /// Whether the rationale came from the AI engine or a YAML rule fallback.
    public let source: ExplanationSource

    public init(
        resultId: String,
        rationale: String,
        suggestedSafety: SafetyLevel,
        source: ExplanationSource
    ) {
        self.resultId = resultId
        self.rationale = rationale
        self.suggestedSafety = suggestedSafety
        self.source = source
    }
}
