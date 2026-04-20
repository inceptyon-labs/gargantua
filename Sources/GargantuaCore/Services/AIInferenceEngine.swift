import Foundation

/// An inference engine produces explanation text from structured scan inputs.
///
/// This is the boundary between `LocalAIService` (lifecycle, fallback, idle
/// unload) and the underlying inference backend (MLX Swift, `mlx-lm`
/// subprocess, or a deterministic template). `LocalAIService` owns the
/// engine and tells it when to load, unload, and generate; the engine owns
/// the model weights and the prompting strategy.
///
/// Conformers must be safe to call on the main actor and should release
/// any held memory from `unload()`.
@MainActor
public protocol AIInferenceEngine: AnyObject, Sendable {
    /// Whether the engine is currently holding model state in memory.
    var isLoaded: Bool { get }

    /// Approximate memory held by the engine, in bytes. Zero when unloaded.
    var memoryUsage: Int64 { get }

    /// Load model weights from disk into memory.
    ///
    /// - Parameters:
    ///   - modelPath: Absolute path to the on-disk model file.
    ///   - modelSize: Size of the model file in bytes (pre-validated by caller).
    func load(modelPath: String, modelSize: Int64) async throws

    /// Release all model state from memory.
    func unload()

    /// Generate explanation text for a scan result using the loaded model.
    ///
    /// Engines that rely on model weights require `isLoaded == true`;
    /// `LocalAIService` ensures the engine is loaded before calling.
    /// Engines that don't need weights (e.g., deterministic templates)
    /// may generate without being loaded.
    func generate(for result: ScanResult, rule: ScanRule) async throws -> String

    /// Produce a structured advisory for a review-tier scan result.
    ///
    /// The default implementation wraps `generate(for:rule:)` and carries
    /// the result's existing safety through as the suggestion, which suits
    /// engines that don't yet reason about alternative classifications
    /// (e.g., `TemplateInferenceEngine`). Real model backends can override
    /// to parse a structured response from the model and surface an actual
    /// alternative `SafetyLevel`.
    ///
    /// `LocalAIService.advisory(for:rules:)` is responsible for the safety
    /// invariant — the engine never mutates `ScanResult.safety`. The
    /// `suggestedSafety` field is advisory-only.
    func advisory(for result: ScanResult, rule: ScanRule) async throws -> ScanResultAdvisory
}

public extension AIInferenceEngine {
    func advisory(for result: ScanResult, rule: ScanRule) async throws -> ScanResultAdvisory {
        let text = try await generate(for: result, rule: rule)
        return ScanResultAdvisory(
            resultId: result.id,
            rationale: text,
            suggestedSafety: result.safety,
            source: .ai
        )
    }
}

/// Errors specific to inference engines. `LocalAIService` wraps these in
/// `AIServiceError.loadFailed` when surfacing to callers.
public enum AIInferenceEngineError: Error, LocalizedError {
    /// The engine is a stub and has no real inference implementation yet.
    case notImplemented(engine: String)

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let engine):
            return "\(engine) inference is not yet available."
        }
    }
}
