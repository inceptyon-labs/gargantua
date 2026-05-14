import SwiftUI

/// Settings view with general preferences and AI model management.
///
/// Five tabs (AI · Automation · Network · Storage · About) replace the long
/// flat scroll. Each tab owns one Surface-2 card per section and the page
/// anchors with a Display-tier header.
public struct SettingsView: View {
    let persistence: PersistenceController

    @AppStorage(AIEnginePreference.userDefaultsKey) var preferredAIEngineRawValue = AIEnginePreference.template.rawValue
    @AppStorage(MenuBarPreferences.widgetEnabledKey) var menuBarWidgetEnabled = MenuBarPreferences.defaultWidgetEnabled
    @AppStorage(MenuBarPreferences.launchAtLoginEnabledKey) var launchAtLoginEnabled = MenuBarPreferences.defaultLaunchAtLoginEnabled

    /// App-shared download manager. When `init(persistence:)` is used without
    /// an explicit manager, the view owns its own `@StateObject` so standalone
    /// previews still work; when `MainContentView` injects one, the view
    /// observes the app-level instance and download state flows through to
    /// every other scan view that also observes it.
    @StateObject private var ownedManager: ModelDownloadManager
    @ObservedObject var downloadManager: ModelDownloadManager
    @StateObject private var ownedUpdateSettingsViewModel: AppUpdateSettingsViewModel
    @ObservedObject var updateSettingsViewModel: AppUpdateSettingsViewModel
    @State var settings: PersistedSettings?
    @State var availableProfiles: [CleanupProfile] = CleanupProfile.builtIn
    @State var scheduledScanAgentStatus: ScheduledScanAgentStatus = .notRegistered
    @State var scheduledScanError: String?
    @State var launchAtLoginStatus: LaunchAtLoginStatus = .notRegistered
    @State var launchAtLoginError: String?
    @State private var selectedTab: SettingsTab = .ai
    @State var isShowingDeleteModelConfirm = false

    public init(persistence: PersistenceController) {
        let manager = ModelDownloadManager()
        let updateSettingsViewModel = AppUpdateSettingsViewModel()
        self.persistence = persistence
        self._ownedManager = StateObject(wrappedValue: manager)
        self._downloadManager = ObservedObject(wrappedValue: manager)
        self._ownedUpdateSettingsViewModel = StateObject(wrappedValue: updateSettingsViewModel)
        self._updateSettingsViewModel = ObservedObject(wrappedValue: updateSettingsViewModel)
    }

    public init(
        persistence: PersistenceController,
        downloadManager: ModelDownloadManager,
        updateSettingsViewModel: AppUpdateSettingsViewModel
    ) {
        self.persistence = persistence
        // `@StateObject` still needs a default; unused when the caller injects,
        // but it has to exist for the property wrapper to initialize cleanly.
        self._ownedManager = StateObject(wrappedValue: downloadManager)
        self._downloadManager = ObservedObject(wrappedValue: downloadManager)
        self._ownedUpdateSettingsViewModel = StateObject(wrappedValue: updateSettingsViewModel)
        self._updateSettingsViewModel = ObservedObject(wrappedValue: updateSettingsViewModel)
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
                headerView
                SettingsTabBar(selection: $selectedTab)
            }
            .padding(.horizontal, GargantuaSpacing.space6)
            .padding(.top, GargantuaSpacing.space6)
            .padding(.bottom, GargantuaSpacing.space4)

            ScrollView {
                VStack(alignment: .leading, spacing: GargantuaSpacing.space5) {
                    tabContent
                }
                .padding(.horizontal, GargantuaSpacing.space6)
                .padding(.bottom, GargantuaSpacing.space6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GargantuaColors.void_)
        .task {
            do {
                settings = try persistence.fetchSettings()
            } catch {
                PersistenceDiagnostics.logFailure("fetchSettings", error: error)
            }

            do {
                availableProfiles = try persistence.fetchProfiles()
                    .filter { !$0.categories.isEmpty }
            } catch {
                PersistenceDiagnostics.logFailure("fetchProfiles", error: error)
                availableProfiles = CleanupProfile.builtIn.filter { !$0.categories.isEmpty }
            }
            scheduledScanAgentStatus = ScheduledScanController().status()
            launchAtLoginStatus = LaunchAtLoginController().status()
            launchAtLoginEnabled = launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
        }
        .sheet(isPresented: $isShowingDeleteModelConfirm) {
            DestructiveConfirmSheet(
                title: "Delete the local AI model?",
                message: """
                Removes the downloaded model from disk. You can re-download anytime, but it will \
                use bandwidth and storage again. This cannot be undone.
                """,
                confirmLabel: "Delete model",
                onCancel: { isShowingDeleteModelConfirm = false },
                onConfirm: {
                    isShowingDeleteModelConfirm = false
                    downloadManager.deleteModel()
                }
            )
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            Text("Settings")
                .font(GargantuaFonts.display)
                .foregroundStyle(GargantuaColors.ink)

            Text(headerSubtitle)
                .font(GargantuaFonts.body.italic())
                .foregroundStyle(GargantuaColors.ink2)
        }
    }

    private var headerSubtitle: String {
        switch selectedTab {
        case .ai: "Engines, providers, and agent runtimes."
        case .automation: "Scheduled scans and menu bar visibility."
        case .network: "MCP transport for external clients."
        case .storage: "Scan roots, exclusions, and protected paths."
        case .about: "Updates and version information."
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .ai:
            aiTabIntro
            modelSection
            CloudAISettingsSection()
            FileOrganizerSettingsSection()
            ClaudeCodeAgentSettingsSection()
        case .automation:
            schedulingSection
            menuBarSection
        case .network:
            MCPTransportSettingsSection()
        case .storage:
            ScanRootsSettingsSection(
                settings: settings,
                persistence: persistence,
                onSettingsChanged: { settings = $0 }
            )
            PersonalScopeSettingsSection(persistence: persistence)
            PathExclusionSettingsSection(persistence: persistence)
            ProtectedRootsSettingsSection()
        case .about:
            updatesSection
            aboutSection
        }
    }

    /// Shared toggle row used by both Automation and About tabs.
    func updateToggleRow(
        icon: String,
        label: String,
        detail: String? = nil,
        detailColor: Color = GargantuaColors.ink3,
        isOn: Binding<Bool>,
        isDisabled: Bool = false
    ) -> some View {
        HStack(spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: icon, size: 16)

            SettingsRowText(title: label, detail: detail, detailColor: detailColor)

            Spacer()

            Toggle(label, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(isDisabled)
                .help(isOn.wrappedValue ? "Disable \(label.lowercased())" : "Enable \(label.lowercased())")
        }
        .padding(.vertical, GargantuaSpacing.space1)
    }
}
