import Foundation

extension EventHorizonContext {
    /// Build a context from a `DeepCleanPhase` + profile name. Mirrors the
    /// uninstaller's vocabulary so the two surfaces feel the same.
    public static func deepClean(
        phase: DeepCleanPhase,
        profileName: String
    ) -> EventHorizonContext {
        EventHorizonContext(
            header: "ENDURANCE · DEEP CLEAN SWEEP",
            target: profileName,
            subtitle: deepCleanSubtitle(for: phase, profileName: profileName),
            subtitlePool: deepCleanSubtitlePool(for: phase, profileName: profileName),
            isInProgress: phase == .scanning || phase == .cleaning,
            isExecuting: phase == .cleaning,
            phaseKey: deepCleanPhaseKey(for: phase)
        )
    }

    private static func deepCleanSubtitle(for phase: DeepCleanPhase, profileName: String) -> String {
        switch phase {
        case .idle: return "Awaiting mission parameters"
        case .scanning: return "Tracing gravitational echoes from \(profileName)"
        case .results: return "Plan locked. Awaiting authorization."
        case .cleaning: return "Crossing the event horizon"
        case .summary: return "Signal recovered. Gargantua has consumed the cache."
        }
    }

    private static func deepCleanSubtitlePool(for phase: DeepCleanPhase, profileName: String) -> [String] {
        switch phase {
        case .scanning:
            return [
                "Tracing gravitational echoes from \(profileName)",
                "Mapping accretion disk topology",
                "Calibrating tidal force sensors",
                "Surveying event horizon boundary layers",
                "Probing for reclaimable mass",
                "Measuring spacetime debris density",
                "Detecting substellar cache fields",
                "Charting the gravitational lens",
                "Analyzing residual quantum foam",
                "Sweeping the accretion corridor",
                "Cataloguing orbital cache debris",
                "Scanning for entropy accumulation",
            ]
        case .cleaning:
            return [
                "Crossing the event horizon",
                "Spaghettification sequence active",
                "Matter absorption nominal",
                "Tidal compression underway",
                "Singularity ingestion in progress",
                "No signal can escape",
            ]
        default:
            return []
        }
    }

    private static func deepCleanPhaseKey(for phase: DeepCleanPhase) -> String {
        switch phase {
        case .idle: "deepClean.idle"
        case .scanning: "deepClean.scanning"
        case .results: "deepClean.results"
        case .cleaning: "deepClean.cleaning"
        case .summary: "deepClean.summary"
        }
    }
}
