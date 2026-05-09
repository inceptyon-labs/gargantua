import GargantuaCore
import Foundation
import SwiftUI

// Root content view for the Gargantua window.
//
// Fills the entire window with `GargantuaColors.void_` so no system
// chrome is visible behind the transparent titlebar. Shows the permission
// request flow on first launch, then sidebar + content. Type body grows
// by one `@State` per top-level view; splitting along sidebar groups
// would scatter shared persistence/AI plumbing.
// swiftlint:disable:next type_body_length
struct MainContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(AIEnginePreference.userDefaultsKey) private var preferredAIEngineRawValue = AIEnginePreference.template.rawValue
    @State private var sidebarSelection: String? = "dashboard"
    @State private var persistence: PersistenceController?
    @State private var dashboardSession = DashboardSessionState()
    @State private var deepCleanSession = DeepCleanSessionState()
    @State private var smartUninstallerViewModel = SmartUninstallerView.makeDefaultViewModel()
    @State private var fileHealthState = FileHealthContainerState()
    @State private var duplicateFinderState = DuplicateFinderContainerState()
    @State private var duplicateFinderSelection: Set<String> = []
    @State private var diskExplorerState = DiskExplorerState()
    @State private var aiModelsSession = AIModelsState()
    @State private var devToolsSession = DeveloperToolsSessionState()
    @State private var activeAIEngineKind: AIEnginePreference

    // App-shared AI plumbing. One `ModelDownloadManager` so Settings' download
    // button + every scan view's "model available?" check observe the same
    // state; one `LocalAIService` so the engine lazy-load / 60-s idle-unload
    // lifecycle doesn't reset between screens; one `AIExplanationController`
    // so the presentation sheet can render at this top level regardless of
    // which scan view fired `onExplain`.
    @StateObject private var downloadManager: ModelDownloadManager
    @StateObject private var aiService: LocalAIService
    @StateObject private var aiExplanation: AIExplanationController
    @StateObject private var aiAdvisory: AIAdvisoryController
    @StateObject private var mcpStatusModel: MCPServerStatusViewModel
    private let updateSettingsViewModel: AppUpdateSettingsViewModel

    init(updateSettingsViewModel: AppUpdateSettingsViewModel) {
        let manager = ModelDownloadManager()
        let selectedEngine = AIInferenceEngineFactory.select(
            preference: AIEnginePreference.stored(),
            modelState: manager.state
        )
        self.updateSettingsViewModel = updateSettingsViewModel
        let service = LocalAIService(downloadManager: manager, engine: selectedEngine.engine)
        _activeAIEngineKind = State(initialValue: selectedEngine.kind)
        _downloadManager = StateObject(wrappedValue: manager)
        _aiService = StateObject(wrappedValue: service)
        _aiExplanation = StateObject(wrappedValue: AIExplanationController(service: service))
        _aiAdvisory = StateObject(wrappedValue: AIAdvisoryController(service: service))
        _mcpStatusModel = StateObject(wrappedValue: MCPServerStatusViewModel())
    }

    var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()

            if !hasCompletedOnboarding {
                PermissionRequestFlowView(isComplete: $hasCompletedOnboarding)
            } else {
                HStack(spacing: 0) {
                    SidebarView(selection: $sidebarSelection, mcpStatusModel: mcpStatusModel)

                    // Content area
                    VStack(spacing: 0) {
                        if !PermissionChecker.hasFullDiskAccess {
                            PermissionBannerView.fullDiskAccess
                                .padding(.horizontal, GargantuaSpacing.space4)
                                .padding(.top, GargantuaSpacing.space3)
                        }

                        Group {
                            switch sidebarSelection {
                            case "dashboard":
                                DashboardView(
                                    sidebarSelection: $sidebarSelection,
                                    session: dashboardSession,
                                    persistence: persistence
                                )
                            case "profiles":
                                if let persistence {
                                    ProfileContainerView(persistence: persistence)
                                } else {
                                    ProgressView()
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            case "deepClean":
                                DeepCleanView(
                                    profile: activeDeepCleanProfile,
                                    session: deepCleanSession,
                                    staleVersionPinnedPaths: pathExclusionPatterns,
                                    onExplain: explainHandler,
                                    onAdvisory: advisoryHandler,
                                    onResolveFilter: scanFilterHandler,
                                    onCleanupCompleted: dashboardCleanupHandler
                                )
                            case "smartUninstaller":
                                SmartUninstallerView(viewModel: smartUninstallerViewModel)
                            case "duplicateFinder":
                                // Trash callback is intentionally left nil until the
                                // Trust Layer / ConfirmationModalView flow for
                                // destructive duplicate-removal is in place.
                                DuplicateFinderContainerView(
                                    state: duplicateFinderState,
                                    scanRoots: resolvedScanRoots,
                                    selectedIDs: $duplicateFinderSelection,
                                    onExplain: explainHandler,
                                    persistence: persistence
                                )
                            case "fileHealth":
                                FileHealthContainerView(
                                    state: fileHealthState,
                                    scanRoots: resolvedScanRoots,
                                    profile: activeDeepCleanProfile,
                                    onExplain: explainHandler,
                                    onSuggestClusters: clusterSuggestionHandler
                                )
                            case "diskExplorer":
                                DiskExplorerView(state: diskExplorerState)
                            case "aiModels":
                                AIModelsView(
                                    profile: .aiModels,
                                    scanRoots: resolvedScanRoots,
                                    aiModelExcludedPaths: pathExclusionPatterns,
                                    session: aiModelsSession,
                                    onExplain: explainHandler,
                                    onAdvisory: advisoryHandler,
                                    onResolveFilter: scanFilterHandler
                                )
                            case "backgroundItems":
                                BackgroundItemsView(onExplain: explainHandler)
                            case "rules":
                                if let persistence {
                                    RuleViewerView(persistence: persistence)
                                } else {
                                    ProgressView()
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            case "devPurge":
                                DevArtifactScanView(
                                    profile: .devPurge,
                                    scanRoots: resolvedScanRoots,
                                    staleVersionPinnedPaths: pathExclusionPatterns,
                                    onExplain: explainHandler,
                                    onResolveFilter: scanFilterHandler,
                                    onCleanupCompleted: dashboardCleanupHandler
                                )
                            case "devTools":
                                DeveloperToolsView(session: devToolsSession)
                            case "agentSessions":
                                ClaudeCodeAgentView()
                            case "settings":
                                if let persistence {
                                    SettingsView(
                                        persistence: persistence,
                                        downloadManager: downloadManager,
                                        updateSettingsViewModel: updateSettingsViewModel
                                    )
                                } else {
                                    ProgressView()
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            default:
                                placeholderView
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .environment(\.cleanupNarrator, narrateHandler)
                .environment(\.activeAIEngineKind, activeAIEngineKind)
                .environment(\.preferredAIEngineKind, preferredAIEngine)
                .environment(\.aiEngineNeedsFirstWarmup, aiEngineNeedsFirstWarmup)
                .environment(\.openAIModelSettings, { sidebarSelection = "settings" })
                .onAppear {
                    initializePersistenceIfNeeded()
                    refreshAIEngineSelection()
                }
                .onChange(of: preferredAIEngineRawValue) { _, _ in
                    refreshAIEngineSelection()
                }
                .onChange(of: downloadManager.state) { _, _ in
                    refreshAIEngineSelection()
                }
                .sheet(item: Binding(
                    get: { aiExplanation.presentation },
                    set: { if $0 == nil { aiExplanation.dismiss() } }
                )) { _ in
                    AIExplanationSheet(
                        controller: aiExplanation,
                        onOpenSettings: { sidebarSelection = "settings" }
                    )
                }
                .sheet(item: Binding(
                    get: { aiAdvisory.presentation },
                    set: { if $0 == nil { aiAdvisory.dismiss() } }
                )) { _ in
                    AIAdvisorySheet(
                        controller: aiAdvisory,
                        onOpenSettings: { sidebarSelection = "settings" }
                    )
                }
            }
        }
    }

    /// True when local AI is selected but hasn't returned its first inference
    /// yet — the cue to surface "Compiling shaders for first use…" while
    /// the MLX backend JIT-compiles GPU kernels.
    private var aiEngineNeedsFirstWarmup: Bool {
        activeAIEngineKind == .mlx && !aiService.hasCompletedFirstMLXInference
    }

    /// The user's persisted toggle preference, decoupled from whatever the
    /// factory actually selected (MLX may have fallen back to Template if the
    /// model isn't downloaded). Used for honest CTA labeling.
    private var preferredAIEngine: AIEnginePreference {
        AIEnginePreference(rawValue: preferredAIEngineRawValue) ?? .template
    }

    /// Closure handed to scan views so their per-row Explain button can kick
    /// off an explanation without knowing about the controller.
    private var explainHandler: (ScanResult) -> Void {
        { result in aiExplanation.explain(result) }
    }

    /// Closure handed to scan views so their Review-Advisories toolbar
    /// button can fire a batch advisory without knowing the controller.
    private var advisoryHandler: ([ScanResult]) -> Void {
        { results in aiAdvisory.request(for: results) }
    }

    /// Closure handed to bucket-based scan views so their search field can
    /// resolve natural-language queries through the app's active local AI
    /// engine without owning AI lifecycle state.
    private var scanFilterHandler: (String) async -> ScanFilterSet? {
        { query in try? await aiService.scanFilter(for: query) }
    }

    /// Closure handed to File Health so its "Suggest" button can label and
    /// classify path-prefix clusters via the active local AI engine. Returns
    /// an empty array when the engine is template-only or the model isn't
    /// available — UI treats that as "no annotations" without erroring.
    private var clusterSuggestionHandler: FileHealthContainerView.ClusterSuggestionHandler {
        { summaries in await aiService.suggestClusters(summaries) }
    }

    /// Build the narrator closure injected via the `\.cleanupNarrator`
    /// environment value so every `CleanupSummaryView` in the tree can request
    /// an AI narrative without threading `LocalAIService` through each
    /// scan-view signature.
    private var narrateHandler: CleanupNarrator {
        { result in await aiService.narrate(cleanup: result) }
    }

    /// Closure handed to destination views (Deep Clean, Dev Purge) so they
    /// can shrink the dashboard's triage alerts immediately when a cleanup
    /// frees space. Without this the NEXT ACTIONS roadmap stays stuck on
    /// whichever destination was rank 1 at triage time, even after the user
    /// has already emptied it.
    private var dashboardCleanupHandler: (CleanupResult) -> Void {
        { result in dashboardSession.applyCleanupDelta(result) }
    }

    /// Initialize persistence once at app boot. The app cannot provide a
    /// trustworthy data UI without the store, so fail loudly instead of running
    /// with every persistence operation effectively disabled.
    private func initializePersistenceIfNeeded() {
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
    }

    /// Reconcile the long-lived AI service with the persisted preference and
    /// current model availability. This lets Settings changes take effect
    /// without replacing the controllers that already hold the service.
    private func refreshAIEngineSelection() {
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
    private var activeDeepCleanProfile: CleanupProfile {
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
    private var resolvedScanRoots: [URL]? {
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

    private var pathExclusionPatterns: Set<String> {
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

    private var placeholderView: some View {
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
