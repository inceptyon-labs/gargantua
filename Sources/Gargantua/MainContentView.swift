import Foundation
import GargantuaCore
import SwiftUI

// Root content view for the Gargantua window.
//
// Fills the entire window with `GargantuaColors.void_` so no system
// chrome is visible behind the transparent titlebar. Shows the permission
// request flow on first launch, then sidebar + content.
//
// AI-engine state, handler closures, and persistence resolution live in
// `MainContentView+Wiring`; stored properties are internal (not private) so
// that extension can reach them.
struct MainContentView: View {
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding = false
    @State var sidebarSelection: String? = "dashboard"
    /// Toggled by ⌘/ (via the Help-menu command) to show the shortcut cheat sheet.
    @State var showKeyboardCheatSheet = false
    /// Plist path the Process Inventory pane asked Background Items to
    /// pre-select. Set when the user clicks "Open source" on a launchd-backed
    /// process; the Background Items view consumes + clears it once it lands
    /// on the matching row.
    @State var pendingBackgroundItemPlistPath: String?
    @State var persistence: PersistenceController?
    @State var activationLinkModel = LicenseActivationLinkModel.shared
    @State var duplicateFinderSelection: Set<String> = []
    /// Settings the panes are built from, read from SwiftData when the window
    /// appears, on every navigation, and after "Add to Exclusions", instead of
    /// on every body evaluation. They only change in Settings and Profiles,
    /// which the user has to navigate away from to see the effect.
    @State var activeDeepCleanProfile: CleanupProfile = .deep
    @State var resolvedScanRoots: [URL]?
    @State var pathExclusionPatterns: Set<String> = []
    @StateObject var window: WindowState
    let updateSettingsViewModel: AppUpdateSettingsViewModel

    init(updateSettingsViewModel: AppUpdateSettingsViewModel) {
        self.updateSettingsViewModel = updateSettingsViewModel
        _window = StateObject(wrappedValue: WindowState())
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
                                    persistence: persistence,
                                    openPane: { openFromDashboard($0) }
                                )
                            case "profiles":
                                if let persistence {
                                    ProfileContainerView(persistence: persistence)
                                } else {
                                    persistenceLoadingView
                                }
                            case "deepClean":
                                DeepCleanView(
                                    profile: activeDeepCleanProfile,
                                    session: deepCleanSession,
                                    staleVersionPinnedPaths: pathExclusionPatterns,
                                    onExplain: explainHandler,
                                    onAdvisory: advisoryHandler,
                                    onResolveFilter: scanFilterHandler,
                                    onCleanupCompleted: dashboardCleanupHandler,
                                    onAddToExclusions: persistence == nil ? nil : { addToExclusions($0) }
                                )
                            case "smartUninstaller":
                                SmartUninstallerView(viewModel: smartUninstallerViewModel)
                            case "duplicateFinder":
                                DuplicateFinderContainerView(
                                    state: duplicateFinderState,
                                    scanRoots: resolvedScanRoots,
                                    selectedIDs: $duplicateFinderSelection,
                                    onExplain: explainHandler,
                                    persistence: persistence,
                                    onCleanupCompleted: dashboardCleanupHandler
                                )
                            case "fileOrganizer":
                                FileOrganizerView(session: organizerSession)
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
                                BackgroundItemsView(
                                    session: backgroundItemsSession,
                                    onExplain: explainHandler,
                                    onTriage: triageHandler,
                                    preSelectedPlistPath: $pendingBackgroundItemPlistPath
                                )
                            case "processInventory":
                                ProcessInventoryView(
                                    session: processInventorySession,
                                    onExplain: explainHandler,
                                    onTriage: triageHandler,
                                    onNavigateToBackgroundItems: { plistPath in
                                        pendingBackgroundItemPlistPath = plistPath
                                        sidebarSelection = "backgroundItems"
                                    }
                                )
                            case "rules":
                                if let persistence {
                                    RuleViewerView(
                                        persistence: persistence,
                                        updateSettingsViewModel: updateSettingsViewModel
                                    )
                                } else {
                                    persistenceLoadingView
                                }
                            case "devPurge":
                                DevArtifactScanView(
                                    profile: .devPurge,
                                    session: devPurgeSession,
                                    scanRoots: resolvedScanRoots,
                                    staleVersionPinnedPaths: pathExclusionPatterns,
                                    onExplain: explainHandler,
                                    onAdvisory: advisoryHandler,
                                    onResolveFilter: scanFilterHandler,
                                    onCleanupCompleted: dashboardCleanupHandler,
                                    onOpenDeveloperTools: { sidebarSelection = "devTools" }
                                )
                            case "devTools":
                                DeveloperToolsView(session: devToolsSession)
                            case "agentSessions":
                                switch AIEngineAssignments.engine(for: .maintenance) {
                                case .codex:
                                    CodexAgentView(controller: agentRunControllers.codex)
                                default:
                                    ClaudeCodeAgentView(controller: agentRunControllers.claude)
                                }
                            case "settings":
                                if let persistence {
                                    SettingsView(
                                        persistence: persistence,
                                        downloadManager: downloadManager,
                                        updateSettingsViewModel: updateSettingsViewModel
                                    )
                                } else {
                                    persistenceLoadingView
                                }
                            default:
                                placeholderView
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .environment(\.cleanupNarrator, narrateHandler)
                .environment(\.openAIModelSettings, { sidebarSelection = "settings" })
                .environment(\.openLicenseSettings, {
                    SettingsView.selectLicenseTab()
                    sidebarSelection = "settings"
                })
                .modifier(AIRootModifier(window: window, onOpenSettings: { sidebarSelection = "settings" }))
                .onAppear {
                    initializePersistenceIfNeeded()
                    refreshPersistedSettings()
                    window.visiblePane = sidebarSelection
                }
                .onChange(of: sidebarSelection) { _, pane in
                    refreshPersistedSettings()
                    window.visiblePane = pane
                }
            }
        }
        .overlay {
            if showKeyboardCheatSheet {
                KeyboardShortcutsCheatSheet(isPresented: $showKeyboardCheatSheet)
            }
        }
        // A `gargantua://activate` link from the purchase email brings the app
        // forward, so it has to say what happened — success or failure.
        .alert(
            activationOutcome?.succeeded == true ? "License activated" : "Activation failed",
            isPresented: Binding(
                get: { activationOutcome != nil },
                set: { if !$0 { LicenseActivationLinkModel.shared.dismiss() } }
            )
        ) {
            Button("OK") { LicenseActivationLinkModel.shared.dismiss() }
        } message: {
            Text(activationOutcome?.message ?? "")
        }
        .alert(
            "Replace this Mac's license?",
            isPresented: Binding(
                get: { activationLinkModel.pendingReplacement != nil },
                set: { if !$0 { activationLinkModel.keepCurrentLicense() } }
            ),
            presenting: activationLinkModel.pendingReplacement
        ) { _ in
            Button("Replace License", role: .destructive) { activationLinkModel.replaceLicense() }
            Button("Keep Current", role: .cancel) { activationLinkModel.keepCurrentLicense() }
        } message: { pending in
            Text(
                "This Mac is activated for \(pending.currentLicensee). An activation link asked to use a different "
                    + "license key here; replacing releases the current activation."
            )
        }
        .focusedSceneValue(\.keyboardCheatSheet, $showKeyboardCheatSheet)
    }

    private var activationOutcome: LicenseActivationLinkModel.Outcome? {
        activationLinkModel.outcome
    }

    /// Placeholder for the destinations that cannot render until SwiftData
    /// finishes loading. Uses the project spinner rather than a bare
    /// `ProgressView`, which is effectively invisible on the void background —
    /// an empty black pane reads as a hang, not as loading. Extracted so a
    /// fourth persistence-gated destination cannot reintroduce the bare one.
    private var persistenceLoadingView: some View {
        AccretionDiskView(activityRate: 18, size: 48, color: GargantuaColors.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Loading")
    }
}
