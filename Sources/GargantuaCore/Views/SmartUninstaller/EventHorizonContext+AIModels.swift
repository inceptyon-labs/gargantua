import Foundation

/// AI Models scan / cleanup flavor for `EventHorizonConsoleView`.
///
/// Lives in its own file so the AI Models view's surface stays out of
/// `EventHorizonConsoleView.swift`, which already covers Smart Uninstaller,
/// Deep Clean, and Dev Purge.
extension EventHorizonContext {
    public static func aiModels(
        phase: DeepCleanPhase,
        profileName: String
    ) -> EventHorizonContext {
        EventHorizonContext(
            header: "ENDURANCE · AI MODEL SURVEY",
            target: profileName,
            subtitle: aiModelsSubtitle(for: phase, profileName: profileName),
            subtitlePool: aiModelsSubtitlePool(for: phase, profileName: profileName),
            isInProgress: phase == .scanning || phase == .cleaning,
            isExecuting: phase == .cleaning,
            phaseKey: aiModelsPhaseKey(for: phase)
        )
    }

    private static func aiModelsSubtitle(for phase: DeepCleanPhase, profileName: String) -> String {
        switch phase {
        case .idle: return "Awaiting model survey parameters"
        case .scanning: return "Sweeping local model storage (\(profileName))"
        case .results: return "Inventory complete. Awaiting your call."
        case .cleaning: return "Releasing weights to the void"
        case .summary: return "Drives recovered. The models are gone."
        }
    }

    private static func aiModelsSubtitlePool(for phase: DeepCleanPhase, profileName: String) -> [String] {
        switch phase {
        case .scanning:
            return [
                "Sweeping local model storage (\(profileName))",
                "Probing Ollama blob constellations",
                "Charting LM Studio tensor fields",
                "Mapping orphan GGUF debris",
                "Cataloguing diffusion checkpoint shells",
                "Tracing PyTorch hub remnants",
                "Resolving safetensor accretion lanes",
                "Surveying Pinokio workspace residue",
                "Auditing ComfyUI weight strata",
                "Detecting stale ONNX anchors",
            ]
        case .cleaning:
            return [
                "Releasing weights to the void",
                "Tensor singularity ingestion active",
                "Model files crossing the horizon",
                "Spaghettifying inference cache",
                "Tidal compression of model blobs",
            ]
        default:
            return []
        }
    }

    private static func aiModelsPhaseKey(for phase: DeepCleanPhase) -> String {
        switch phase {
        case .idle: "aiModels.idle"
        case .scanning: "aiModels.scanning"
        case .results: "aiModels.results"
        case .cleaning: "aiModels.cleaning"
        case .summary: "aiModels.summary"
        }
    }
}
