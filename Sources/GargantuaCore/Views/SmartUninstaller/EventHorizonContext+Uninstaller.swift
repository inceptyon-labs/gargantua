import Foundation

extension EventHorizonContext {
    /// Build a context from a `SmartUninstallerPhase`. Keeps the original
    /// uninstall copy so existing screens render identically.
    public static func uninstaller(phase: SmartUninstallerPhase) -> EventHorizonContext {
        EventHorizonContext(
            header: "ENDURANCE · UNINSTALL SEQUENCE",
            target: uninstallTarget(for: phase),
            subtitle: uninstallSubtitle(for: phase),
            subtitlePool: uninstallSubtitlePool(for: phase),
            isInProgress: uninstallInProgress(for: phase),
            isExecuting: uninstallExecuting(for: phase),
            phaseKey: uninstallPhaseKey(for: phase)
        )
    }

    private static func uninstallTarget(for phase: SmartUninstallerPhase) -> String {
        switch phase {
        case .idle, .loadingApps:
            return "/Applications · Launch Services"
        case .pickingApp:
            return "—"
        case .scanning(let app):
            return app.displayName ?? app.name
        case .reviewingPlan(let plan):
            return plan.app.displayName ?? plan.app.name
        case .executing(let plan):
            return plan.app.displayName ?? plan.app.name
        case .summary(let plan, _):
            return plan.app.displayName ?? plan.app.name
        case .batchScanning(let completed, let total):
            return "BATCH \(completed)/\(total)"
        case .batchExecuting(let completed, let total):
            return "BATCH \(completed)/\(total)"
        case .batchSummary(let results):
            return "BATCH \(results.count) apps"
        case .failed:
            return "—"
        }
    }

    private static func uninstallSubtitle(for phase: SmartUninstallerPhase) -> String {
        switch phase {
        case .idle, .loadingApps:
            return "Surveying nearby star systems"
        case .pickingApp:
            return "Awaiting mission parameters"
        case .scanning(let app):
            return "Tracing gravitational echoes from \(app.displayName ?? app.name)"
        case .reviewingPlan:
            return "Plan locked. Awaiting authorization."
        case .executing:
            return "Crossing the event horizon"
        case .summary(let plan, _):
            let name = plan.app.displayName ?? plan.app.name
            return "Signal recovered. \(name) has passed into Gargantua."
        case .batchScanning:
            return "Tracing gravitational echoes across the batch"
        case .batchExecuting:
            return "Crossing the event horizon"
        case .batchSummary:
            return "Signal recovered. Batch artifacts have passed into Gargantua."
        case .failed:
            return "Signal lost in the accretion disk."
        }
    }

    private static func uninstallSubtitlePool(for phase: SmartUninstallerPhase) -> [String] {
        switch phase {
        case .scanning(let app):
            let name = app.displayName ?? app.name
            return [
                "Tracing gravitational echoes from \(name)",
                "Mapping \(name)'s orbital debris field",
                "Cataloguing artifact mass across support constellation",
                "Scanning container boundary topology",
                "Measuring sandbox curvature anomalies",
                "Probing preference manifold geometry",
                "Surveying cache residue in deep orbit",
                "Calibrating removal trajectory",
                "Detecting stray framework signatures",
                "Charting plugin accretion layers",
            ]
        case .batchScanning:
            return [
                "Tracing gravitational echoes across the batch",
                "Mapping multi-app debris fields",
                "Cataloguing artifact mass across targets",
                "Scanning container boundary topology",
                "Calibrating batch removal trajectories",
                "Surveying cache residue in deep orbit",
                "Probing preference manifold geometry",
                "Charting plugin accretion layers",
            ]
        case .executing, .batchExecuting:
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

    private static func uninstallInProgress(for phase: SmartUninstallerPhase) -> Bool {
        switch phase {
        case .loadingApps, .scanning, .executing, .batchScanning, .batchExecuting: true
        default: false
        }
    }

    private static func uninstallExecuting(for phase: SmartUninstallerPhase) -> Bool {
        switch phase {
        case .executing, .batchExecuting: true
        default: false
        }
    }

    private static func uninstallPhaseKey(for phase: SmartUninstallerPhase) -> String {
        uninstallBatchPhaseKey(for: phase) ?? uninstallSinglePhaseKey(for: phase)
    }

    private static func uninstallBatchPhaseKey(for phase: SmartUninstallerPhase) -> String? {
        switch phase {
        case .batchScanning: "batchScanning"
        case .batchExecuting: "batchExecuting"
        case .batchSummary: "batchSummary"
        default: nil
        }
    }

    private static func uninstallSinglePhaseKey(for phase: SmartUninstallerPhase) -> String {
        switch phase {
        case .idle: "idle"
        case .loadingApps: "loadingApps"
        case .pickingApp: "pickingApp"
        case .scanning: "scanning"
        case .reviewingPlan: "reviewingPlan"
        case .executing: "executing"
        case .summary: "summary"
        case .failed: "failed"
        default: "unknown"
        }
    }
}
