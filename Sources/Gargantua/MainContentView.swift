import GargantuaCore
import SwiftUI

/// Root content view for the Gargantua window.
///
/// Fills the entire window with ``GargantuaColors/void_`` so no system
/// chrome is visible behind the transparent titlebar.
/// Shows the permission request flow on first launch, then sidebar + content.
struct MainContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var sidebarSelection: String? = "dashboard"
    @State private var persistence: PersistenceController?
    @State private var deepCleanSession = DeepCleanSessionState()
    @State private var smartUninstallerViewModel = SmartUninstallerView.makeDefaultViewModel()
    @State private var duplicateFinderSelection: Set<String> = []

    // App-shared AI plumbing. One `ModelDownloadManager` so Settings' download
    // button + every scan view's "model available?" check observe the same
    // state; one `LocalAIService` so the engine lazy-load / 60-s idle-unload
    // lifecycle doesn't reset between screens; one `AIExplanationController`
    // so the presentation sheet can render at this top level regardless of
    // which scan view fired `onExplain`.
    @StateObject private var downloadManager: ModelDownloadManager
    @StateObject private var aiService: LocalAIService
    @StateObject private var aiExplanation: AIExplanationController

    init() {
        let manager = ModelDownloadManager()
        let service = LocalAIService(downloadManager: manager, engine: MLXInferenceEngine())
        _downloadManager = StateObject(wrappedValue: manager)
        _aiService = StateObject(wrappedValue: service)
        _aiExplanation = StateObject(wrappedValue: AIExplanationController(service: service))
    }

    var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()

            if !hasCompletedOnboarding {
                PermissionRequestFlowView(isComplete: $hasCompletedOnboarding)
            } else {
                HStack(spacing: 0) {
                    SidebarView(selection: $sidebarSelection)

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
                                DashboardView(sidebarSelection: $sidebarSelection)
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
                                    onExplain: explainHandler
                                )
                            case "smartUninstaller":
                                SmartUninstallerView(viewModel: smartUninstallerViewModel)
                            case "duplicateFinder":
                                // Trash callback is intentionally left nil until the
                                // Trust Layer / ConfirmationModalView flow for
                                // destructive duplicate-removal is in place.
                                DuplicateFinderContainerView(
                                    scanRoots: resolvedScanRoots,
                                    selectedIDs: $duplicateFinderSelection,
                                    onExplain: explainHandler
                                )
                            case "fileHealth":
                                FileHealthContainerView(
                                    scanRoots: resolvedScanRoots,
                                    profile: activeDeepCleanProfile,
                                    onExplain: explainHandler
                                )
                            case "diskExplorer":
                                DiskExplorerView()
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
                                    onExplain: explainHandler
                                )
                            case "devTools":
                                DeveloperToolsView()
                            case "settings":
                                if let persistence {
                                    SettingsView(
                                        persistence: persistence,
                                        downloadManager: downloadManager
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
                .onAppear {
                    if persistence == nil {
                        persistence = try? PersistenceController()
                        try? persistence?.bootstrap()
                    }
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
            }
        }
    }

    /// Closure handed to scan views so their per-row Explain button can kick
    /// off an explanation without knowing about the controller.
    private var explainHandler: (ScanResult) -> Void {
        { result in aiExplanation.explain(result) }
    }

    /// Resolve the cleanup profile to use for Deep Clean.
    ///
    /// Reads `activeProfileID` from persisted settings and looks the profile up
    /// in persisted profiles first, then built-ins. Falls back to `.deep` when
    /// persistence isn't ready yet or the stored ID doesn't match anything so
    /// Deep Clean always has a safe, broad default.
    private var activeDeepCleanProfile: CleanupProfile {
        guard let persistence,
              let settings = try? persistence.fetchSettings()
        else { return .deep }

        let persisted = (try? persistence.fetchProfiles()) ?? []
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
        guard let persistence,
              let stored = try? persistence.fetchSettings().scanRoots
        else { return nil }

        let urls = ScanRootSettings.resolvedURLs(from: stored)
        return urls.isEmpty ? nil : urls
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
