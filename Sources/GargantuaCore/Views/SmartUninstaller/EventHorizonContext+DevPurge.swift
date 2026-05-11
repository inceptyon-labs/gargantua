import Foundation

extension EventHorizonContext {
    /// Build a context for Dev Artifact Purge.
    public static func devPurge(
        phase: DeepCleanPhase,
        profileName: String
    ) -> EventHorizonContext {
        EventHorizonContext(
            header: "ENDURANCE · DEV ARTIFACT PURGE",
            target: profileName,
            subtitle: devPurgeSubtitle(for: phase, profileName: profileName),
            subtitlePool: devPurgeSubtitlePool(for: phase, profileName: profileName),
            isInProgress: phase == .scanning || phase == .cleaning,
            isExecuting: phase == .cleaning,
            phaseKey: devPurgePhaseKey(for: phase)
        )
    }

    private static func devPurgeSubtitle(for phase: DeepCleanPhase, profileName: String) -> String {
        switch phase {
        case .idle: return "Awaiting mission parameters"
        case .scanning: return "Tracing dev artifact debris (\(profileName))"
        case .results: return "Plan locked. Awaiting authorization."
        case .cleaning: return "Crossing the event horizon"
        case .summary: return "Signal recovered. The build artifacts are gone."
        }
    }

    private static func devPurgeSubtitlePool(for phase: DeepCleanPhase, profileName: String) -> [String] {
        switch phase {
        case .scanning:
            return [
                "Tracing dev artifact debris (\(profileName))",
                "Mapping build artifact constellations",
                "Probing derived data singularity",
                "Scanning simulator cache topology",
                "Detecting stale index store fragments",
                "Measuring Swift package cache density",
                "Surveying archive residue fields",
                "Cataloguing incremental build debris",
                "Charting module map accretion layers",
                "Analyzing orphaned framework signatures",
            ]
        case .cleaning:
            return [
                "Crossing the event horizon",
                "Spaghettification sequence active",
                "Build artifacts absorbed",
                "Tidal compression underway",
                "Singularity ingestion in progress",
            ]
        default:
            return []
        }
    }

    private static func devPurgePhaseKey(for phase: DeepCleanPhase) -> String {
        switch phase {
        case .idle: "devPurge.idle"
        case .scanning: "devPurge.scanning"
        case .results: "devPurge.results"
        case .cleaning: "devPurge.cleaning"
        case .summary: "devPurge.summary"
        }
    }
}
