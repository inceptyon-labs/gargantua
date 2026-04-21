import Foundation

/// User-selectable local AI backend.
public enum AIEnginePreference: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Deterministic, metadata-backed explanations.
    case template
    /// MLX Swift-backed local model inference.
    case mlx

    public static let userDefaultsKey = "preferredAIEngine"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .template: "Template"
        case .mlx: "MLX"
        }
    }

    public var settingsDescription: String {
        switch self {
        case .template: "Deterministic rule-backed explanations"
        case .mlx: "Local model inference when the model is ready"
        }
    }

    public var systemImage: String {
        switch self {
        case .template: "doc.text"
        case .mlx: "cpu"
        }
    }

    public static func stored(in defaults: UserDefaults = .standard) -> AIEnginePreference {
        guard let rawValue = defaults.string(forKey: userDefaultsKey),
              let preference = AIEnginePreference(rawValue: rawValue)
        else {
            return .template
        }
        return preference
    }

    public func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.userDefaultsKey)
    }
}

/// Concrete engine selected for the current preference and model state.
@MainActor
public struct SelectedAIInferenceEngine {
    public let kind: AIEnginePreference
    public let engine: AIInferenceEngine
    public let isFallback: Bool
}

/// Resolves the user's preferred backend into an engine that can run now.
@MainActor
public enum AIInferenceEngineFactory {
    public static func select(
        preference: AIEnginePreference,
        modelState: ModelState
    ) -> SelectedAIInferenceEngine {
        switch preference {
        case .template:
            return SelectedAIInferenceEngine(
                kind: .template,
                engine: TemplateInferenceEngine(),
                isFallback: false
            )

        case .mlx:
            if mlxModelIsUsable(modelState) {
                return SelectedAIInferenceEngine(
                    kind: .mlx,
                    engine: MLXInferenceEngine(),
                    isFallback: false
                )
            }
            return SelectedAIInferenceEngine(
                kind: .template,
                engine: TemplateInferenceEngine(),
                isFallback: true
            )
        }
    }

    private static func mlxModelIsUsable(_ modelState: ModelState) -> Bool {
        guard case .downloaded(let path, _) = modelState else {
            return false
        }

        do {
            let directory = try MLXInferenceEngine.resolveModelDirectory(path)
            try MLXInferenceEngine.validateModelDirectory(directory)
            return true
        } catch {
            return false
        }
    }
}
