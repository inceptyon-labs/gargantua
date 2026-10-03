import Foundation
import GargantuaCore
import SwiftUI

/// Everything the window keeps for its lifetime: the AI plumbing and each
/// screen's session. `MainContentView` builds it once through `@StateObject`
/// rather than in its own `init`, which SwiftUI runs again on every
/// `GargantuaApp.body` evaluation (popover refresh, quick scan, snooze) and
/// which used to rebuild all of this, uninstall-rule parsing included, only to
/// throw it away. It publishes nothing, so holding it doesn't re-render the
/// root; the AI objects the root reacts to are observed in `AIRootModifier`.
@MainActor
final class WindowState: ObservableObject {
    // App-shared AI plumbing. One `ModelDownloadManager` so Settings' download
    // button + every scan view's "model available?" check observe the same
    // state; one `LocalAIService` so the engine lazy-load / 60-s idle-unload
    // lifecycle doesn't reset between screens; one `AIExplanationController`
    // so the presentation sheet can render at this top level regardless of
    // which scan view fired `onExplain`.
    let downloadManager: ModelDownloadManager
    let aiService: LocalAIService
    let initialAIEngineKind: AIEnginePreference
    let cloudAIService: CloudAIService
    let aiExplanation: AIExplanationController
    let aiAdvisory: AIAdvisoryController
    let mcpStatusModel = MCPServerStatusViewModel()
    let organizerSession: OrganizerSessionState

    let dashboardSession = DashboardSessionState()
    let deepCleanSession = DeepCleanSessionState()
    let smartUninstallerViewModel = SmartUninstallerView.makeDefaultViewModel()
    let fileHealthState = FileHealthContainerState()
    let duplicateFinderState = DuplicateFinderContainerState()
    let diskExplorerState = DiskExplorerState()
    let aiModelsSession = AIModelsState()
    let devToolsSession = DeveloperToolsSessionState()
    let devPurgeSession = DevArtifactSessionState()
    let backgroundItemsSession = BackgroundItemsSession()
    let processInventorySession = ProcessInventorySession()
    let agentRunControllers = AgentRunControllers()

    /// The sidebar pane on screen; memory-pressure relief leaves it alone.
    var visiblePane: String?
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    init() {
        let manager = ModelDownloadManager()
        let selectedEngine = AIInferenceEngineFactory.select(
            preference: AIEnginePreference.stored(),
            modelState: manager.state
        )
        let service = LocalAIService(downloadManager: manager, engine: selectedEngine.engine)
        downloadManager = manager
        aiService = service
        initialAIEngineKind = selectedEngine.kind

        // Cloud service is needed before the explanation controller so the
        // explanation router can route inline and deeper requests to the
        // engine assigned to each job (local / Cloud / Claude Code / Codex).
        let cloudAI = CloudAIService()
        cloudAIService = cloudAI
        let router = ExplanationRouter(local: service, cloud: cloudAI)
        aiExplanation = AIExplanationController(
            service: service,
            inlineExplain: { result, rule in
                try await router.explain(.inlineExplain, result: result, rule: rule)
            },
            deeperExplain: { result, rule in
                try await router.explain(.deeperExplain, result: result, rule: rule)
            },
            deeperAvailable: { router.isAvailable(.deeperExplain) }
        )
        // Advisories ("Review Advisories" / "Suspicious Triage") route through
        // the same engine-assignment matrix as inline explanations, so the user
        // can point them at the local model, Cloud, or a CLI agent.
        let advisoryRouter = AdvisoryRouter(local: service, cloud: cloudAI)
        aiAdvisory = AIAdvisoryController(
            service: service,
            advise: { results, rules, includeNonReview in
                try await advisoryRouter.advisory(
                    for: results,
                    rules: rules,
                    includeNonReview: includeNonReview
                )
            }
        )
        organizerSession = OrganizerSessionState(
            cloudService: cloudAI,
            mlxProposer: MLXOrganizerProposer(aiService: service)
        )
        watchMemoryPressure()
    }

    /// Each pane keeps its last scan for the window's lifetime, and a few of
    /// them can hold thousands of results (or hundreds of MiB of fclones and
    /// czkawka output). When the system warns of memory pressure, drop the
    /// results of panes that are off screen and only showing results; a scan
    /// or cleanup in flight, and a cleanup summary, are kept.
    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.releaseHiddenResults() }
        }
        source.resume()
        memoryPressureSource = source
    }

    func releaseHiddenResults() {
        if visiblePane != "deepClean", deepCleanSession.phase == .results {
            deepCleanSession.clearResults()
        }
        if visiblePane != "devPurge", devPurgeSession.phase == .results {
            devPurgeSession.returnToIdle()
        }
        if visiblePane != "aiModels", aiModelsSession.phase == .results {
            aiModelsSession.clearResults()
        }
        if visiblePane != "fileHealth", fileHealthState.phase == .results {
            fileHealthState.clearResults()
        }
        if visiblePane != "duplicateFinder" {
            duplicateFinderState.releaseResults()
        }
        if visiblePane != "diskExplorer", diskExplorerState.phase == .results {
            diskExplorerState.exitToIdle()
        }
    }
}

/// The root's AI-driven parts: the engine environment values, re-selecting
/// the engine when the preference or the model changes, and the explanation
/// and advisory sheets. These objects are observed here rather than in
/// `MainContentView`, so an AI state change re-runs this modifier, not the
/// whole window's body.
struct AIRootModifier: ViewModifier {
    @ObservedObject var downloadManager: ModelDownloadManager
    @ObservedObject var aiService: LocalAIService
    @ObservedObject var aiExplanation: AIExplanationController
    @ObservedObject var aiAdvisory: AIAdvisoryController
    let onOpenSettings: () -> Void

    @AppStorage(AIEnginePreference.userDefaultsKey) private var preferredAIEngineRawValue = AIEnginePreference.template.rawValue
    @State private var activeAIEngineKind: AIEnginePreference

    init(window: WindowState, onOpenSettings: @escaping () -> Void) {
        downloadManager = window.downloadManager
        aiService = window.aiService
        aiExplanation = window.aiExplanation
        aiAdvisory = window.aiAdvisory
        self.onOpenSettings = onOpenSettings
        _activeAIEngineKind = State(initialValue: window.initialAIEngineKind)
    }

    /// The user's persisted toggle preference, decoupled from whatever the
    /// factory actually selected (MLX may have fallen back to Template if the
    /// model isn't downloaded). Used for honest CTA labeling.
    private var preferredAIEngine: AIEnginePreference {
        AIEnginePreference(rawValue: preferredAIEngineRawValue) ?? .template
    }

    /// True when local AI is selected but hasn't returned its first inference
    /// yet — the cue to surface "Compiling shaders for first use…" while
    /// the MLX backend JIT-compiles GPU kernels.
    private var aiEngineNeedsFirstWarmup: Bool {
        activeAIEngineKind == .mlx && !aiService.hasCompletedFirstMLXInference
    }

    func body(content: Content) -> some View {
        content
            .environment(\.activeAIEngineKind, activeAIEngineKind)
            .environment(\.preferredAIEngineKind, preferredAIEngine)
            .environment(\.aiEngineNeedsFirstWarmup, aiEngineNeedsFirstWarmup)
            .onAppear { refreshAIEngineSelection() }
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
                AIExplanationSheet(controller: aiExplanation, onOpenSettings: onOpenSettings)
            }
            .sheet(item: Binding(
                get: { aiAdvisory.presentation },
                set: { if $0 == nil { aiAdvisory.dismiss() } }
            )) { _ in
                AIAdvisorySheet(controller: aiAdvisory, onOpenSettings: onOpenSettings)
            }
    }

    /// Reconcile the long-lived AI service with the persisted preference and
    /// current model availability. This lets Settings changes take effect
    /// without replacing the controllers that already hold the service.
    private func refreshAIEngineSelection() {
        let selectedEngine = AIInferenceEngineFactory.select(
            preference: preferredAIEngine,
            modelState: downloadManager.state
        )
        guard selectedEngine.kind != activeAIEngineKind else { return }

        aiService.configureEngine(selectedEngine.engine)
        activeAIEngineKind = selectedEngine.kind
    }
}
