import Foundation
import GargantuaCore
import SwiftUI

// AI-engine state, handler closures handed to scan views, and persistence
// resolution for MainContentView. Split out of the root view so the type body
// stays under the length policy; stored properties are internal (not private)
// so this extension can reach them.
extension MainContentView {
    /// True when local AI is selected but hasn't returned its first inference
    /// yet — the cue to surface "Compiling shaders for first use…" while
    /// the MLX backend JIT-compiles GPU kernels.
    var aiEngineNeedsFirstWarmup: Bool {
        activeAIEngineKind == .mlx && !aiService.hasCompletedFirstMLXInference
    }

    /// The user's persisted toggle preference, decoupled from whatever the
    /// factory actually selected (MLX may have fallen back to Template if the
    /// model isn't downloaded). Used for honest CTA labeling.
    var preferredAIEngine: AIEnginePreference {
        AIEnginePreference(rawValue: preferredAIEngineRawValue) ?? .template
    }

    /// Closure handed to scan views so their per-row Explain button can kick
    /// off an explanation without knowing about the controller.
    var explainHandler: (ScanResult) -> Void {
        { result in aiExplanation.explain(result) }
    }

    /// Closure handed to scan views so their Review-Advisories toolbar
    /// button can fire a batch advisory without knowing the controller.
    var advisoryHandler: ([ScanResult]) -> Void {
        { results in aiAdvisory.request(for: results) }
    }

    /// Closure handed to live-system panes so their triage button can analyze
    /// a small ranked candidate set instead of every review-tier row.
    var triageHandler: ([ScanResult]) -> Void {
        { results in aiAdvisory.request(for: results, includeNonReview: true) }
    }

    /// Closure handed to bucket-based scan views so their search field can
    /// resolve natural-language queries through the app's active local AI
    /// engine without owning AI lifecycle state.
    var scanFilterHandler: (String) async -> ScanFilterSet? {
        { query in try? await aiService.scanFilter(for: query) }
    }

    /// Closure handed to File Health so its "Suggest" button can label and
    /// classify path-prefix clusters via the active local AI engine. Returns
    /// an empty array when the engine is template-only or the model isn't
    /// available — UI treats that as "no annotations" without erroring.
    var clusterSuggestionHandler: FileHealthContainerView.ClusterSuggestionHandler {
        { summaries in await aiService.suggestClusters(summaries) }
    }

    /// Build the narrator closure injected via the `\.cleanupNarrator`
    /// environment value so every `CleanupSummaryView` in the tree can request
    /// an AI narrative without threading `LocalAIService` through each
    /// scan-view signature.
    var narrateHandler: CleanupNarrator {
        { result in await aiService.narrate(cleanup: result) }
    }

    /// Closure handed to destination views (Deep Clean, Dev Purge) so they
    /// can shrink the dashboard's triage alerts immediately when a cleanup
    /// frees space. Without this the NEXT ACTIONS roadmap stays stuck on
    /// whichever destination was rank 1 at triage time, even after the user
    /// has already emptied it.
    var dashboardCleanupHandler: (CleanupResult) -> Void {
        { result in dashboardSession.applyCleanupDelta(result) }
    }

    /// Initialize persistence once at app boot. The app cannot provide a
    /// trustworthy data UI without the store, so fail loudly instead of running
    /// with every persistence operation effectively disabled.
    func initializePersistenceIfNeeded() {
        guard persistence == nil else { return }

        let controller: PersistenceController
        do {
            controller = try PersistenceController()
            try controller.bootstrap()
        } catch {
            FileHandle.standardError.write(Data("persistence init failed: \(error)\n".utf8))
            fatalError("Persistence layer failed to initialize: \(error.localizedDescription)")
        }

        persistence = controller

        // Apply the "Audit retention" window once per launch; Settings → About
        // re-runs it when the user changes the window.
        let retentionDays = (try? controller.fetchSettings().retentionDays) ?? 90
        AuditRetention.purgeInBackground(retentionDays: retentionDays)
    }

    /// Reconcile the long-lived AI service with the persisted preference and
    /// current model availability. This lets Settings changes take effect
    /// without replacing the controllers that already hold the service.
    func refreshAIEngineSelection() {
        let preference = AIEnginePreference(rawValue: preferredAIEngineRawValue) ?? .template
        let selectedEngine = AIInferenceEngineFactory.select(
            preference: preference,
            modelState: downloadManager.state
        )
        guard selectedEngine.kind != activeAIEngineKind else { return }

        aiService.configureEngine(selectedEngine.engine)
        activeAIEngineKind = selectedEngine.kind
    }

    /// Resolve the cleanup profile to use for Deep Clean.
    ///
    /// Reads `activeProfileID` from persisted settings and looks the profile up
    /// in persisted profiles first, then built-ins. Falls back to `.deep` when
    /// persistence isn't ready yet or the stored ID doesn't match anything so
    /// Deep Clean always has a safe, broad default.
    var activeDeepCleanProfile: CleanupProfile {
        guard let persistence else { return .deep }

        let settings: PersistedSettings
        do {
            settings = try persistence.fetchSettings()
        } catch {
            PersistenceDiagnostics.logFallback(
                "fetchSettings activeDeepCleanProfile",
                fallback: ".deep",
                error: error
            )
            return .deep
        }

        let persisted: [CleanupProfile]
        do {
            persisted = try persistence.fetchProfiles()
        } catch {
            PersistenceDiagnostics.logFallback(
                "fetchProfiles activeDeepCleanProfile",
                fallback: "built-in profiles only",
                error: error
            )
            persisted = []
        }

        return CleanupProfile.resolve(
            activeProfileID: settings.activeProfileID,
            persisted: persisted,
            fallback: .deep
        )
    }

    /// Resolve the scan roots for Dev Purge from persisted settings, falling back
    /// to auto-detected defaults when no override is stored or persistence isn't
    /// ready yet.
    ///
    /// Stored entries are trimmed and tilde-expanded; anything empty, a bare `/`,
    /// or a bare `~` is dropped to prevent accidentally widening scan scope to
    /// the whole filesystem or home directory.
    var resolvedScanRoots: [URL]? {
        guard let persistence else { return nil }

        let stored: [String]
        do {
            stored = try persistence.fetchSettings().scanRoots
        } catch {
            PersistenceDiagnostics.logFallback(
                "fetchSettings scanRoots",
                fallback: "auto-detected scan roots",
                error: error
            )
            return nil
        }

        let urls = ScanRootSettings.resolvedURLs(from: stored)
        return urls.isEmpty ? nil : urls
    }

    var pathExclusionPatterns: Set<String> {
        guard let persistence else { return [] }
        do {
            return Set(try persistence.fetchExclusionEntries().map(\.pattern))
        } catch {
            PersistenceDiagnostics.logFallback(
                "fetchExclusionEntries stale version pins",
                fallback: "no stale-version pins",
                error: error
            )
            return []
        }
    }

    var placeholderView: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 32))
                .foregroundStyle(GargantuaColors.ink4)
            Text("Coming Soon")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
