import Foundation

/// The result of applying safety overrides to a scan result.
public struct ClassifiedResult: Sendable {
    /// The final safety level (may differ from the rule's base level).
    public let safety: SafetyLevel
    /// The final confidence score.
    public let confidence: Int
    /// The final explanation (may include override suffix).
    public let explanation: String
    /// Whether an override was applied.
    public let wasOverridden: Bool

    public init(safety: SafetyLevel, confidence: Int, explanation: String, wasOverridden: Bool = false) {
        self.safety = safety
        self.confidence = confidence
        self.explanation = explanation
        self.wasOverridden = wasOverridden
    }
}

/// Applies profile-aware safety overrides to scan results.
///
/// Given a scan result's metadata and the active cleanup profile, evaluates
/// safety overrides from the rule definition and returns the effective
/// classification. Overrides can only reclassify items — they never change
/// the base rule, only the runtime classification.
public struct SafetyClassifier: Sendable {
    private let evaluator = ConditionEvaluator()

    public init() {}

    /// Classify a scan result by applying applicable safety overrides.
    ///
    /// Override precedence: the first matching override wins (evaluated in order).
    /// An override matches when:
    /// 1. Its `profiles` array is empty (applies to all profiles) OR contains the active profile's ID
    /// 2. Its `condition` evaluates to true against the item's metadata
    ///
    /// - Parameters:
    ///   - result: The scan result to classify.
    ///   - rule: The scan rule that matched this result (provides base safety + overrides).
    ///   - profile: The active cleanup profile.
    ///   - now: Reference date for age calculations (defaults to current date).
    /// - Returns: The classified result with potentially overridden safety level.
    public func classify(
        result: ScanResult,
        rule: ScanRule,
        profile: CleanupProfile,
        now: Date = Date()
    ) -> ClassifiedResult {
        // Check rule-level overrides first, then profile-level
        let allOverrides = rule.safetyOverrides + profile.safetyOverrides
        if let matched = allOverrides.first(where: { matches(override: $0, profileID: profile.id, lastAccessed: result.lastAccessed, now: now) }) {
            return applyOverride(matched, baseSafety: rule.safety, baseConfidence: rule.confidence, baseExplanation: rule.explanation)
        }

        // No override matched — use base classification
        return ClassifiedResult(
            safety: rule.safety,
            confidence: rule.confidence,
            explanation: rule.explanation
        )
    }

    /// Classify a batch of scan results.
    public func classify(
        results: [(result: ScanResult, rule: ScanRule)],
        profile: CleanupProfile,
        now: Date = Date()
    ) -> [ClassifiedResult] {
        results.map { classify(result: $0.result, rule: $0.rule, profile: profile, now: now) }
    }
}

// MARK: - Private

private extension SafetyClassifier {

    func matches(override: SafetyOverride, profileID: String, lastAccessed: Date?, now: Date) -> Bool {
        // Check profile scope
        if !override.profiles.isEmpty && !override.profiles.contains(profileID) {
            return false
        }

        // Evaluate condition
        return evaluator.evaluate(condition: override.condition, lastAccessed: lastAccessed, now: now)
    }

    func applyOverride(
        _ override: SafetyOverride,
        baseSafety: SafetyLevel,
        baseConfidence: Int,
        baseExplanation: String
    ) -> ClassifiedResult {
        let confidence = override.confidence ?? baseConfidence

        var explanation = baseExplanation
        if let suffix = override.explanationSuffix {
            explanation = "\(baseExplanation) \(suffix)"
        }

        return ClassifiedResult(
            safety: override.safety,
            confidence: confidence,
            explanation: explanation,
            wasOverridden: true
        )
    }
}
