import SwiftUI

/// Settings view with general preferences and AI model management.
///
/// Five tabs (AI · Automation · Network · Storage · About) replace the long
/// flat scroll. Each tab owns one Surface-2 card per section and the page
/// anchors with a Display-tier header.
public struct SettingsView: View {
    let persistence: PersistenceController

    @AppStorage(AIEnginePreference.userDefaultsKey) private var preferredAIEngineRawValue = AIEnginePreference.template.rawValue
    @AppStorage(MenuBarPreferences.widgetEnabledKey) private var menuBarWidgetEnabled = MenuBarPreferences.defaultWidgetEnabled
    @AppStorage(MenuBarPreferences.launchAtLoginEnabledKey) private var launchAtLoginEnabled = MenuBarPreferences.defaultLaunchAtLoginEnabled

    /// App-shared download manager. When `init(persistence:)` is used without
    /// an explicit manager, the view owns its own `@StateObject` so standalone
    /// previews still work; when `MainContentView` injects one, the view
    /// observes the app-level instance and download state flows through to
    /// every other scan view that also observes it.
    @StateObject private var ownedManager: ModelDownloadManager
    @ObservedObject private var downloadManager: ModelDownloadManager
    @StateObject private var ownedUpdateSettingsViewModel: AppUpdateSettingsViewModel
    @ObservedObject private var updateSettingsViewModel: AppUpdateSettingsViewModel
    @State private var settings: PersistedSettings?
    @State private var availableProfiles: [CleanupProfile] = CleanupProfile.builtIn
    @State private var scheduledScanAgentStatus: ScheduledScanAgentStatus = .notRegistered
    @State private var scheduledScanError: String?
    @State private var launchAtLoginStatus: LaunchAtLoginStatus = .notRegistered
    @State private var launchAtLoginError: String?
    @State private var selectedTab: SettingsTab = .ai
    @State private var isShowingDeleteModelConfirm = false

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
                message: "Removes the downloaded model from disk. You can re-download anytime, but it will use bandwidth and storage again. This cannot be undone.",
                confirmLabel: "Delete model",
                onCancel: { isShowingDeleteModelConfirm = false },
                onConfirm: {
                    isShowingDeleteModelConfirm = false
                    downloadManager.deleteModel()
                }
            )
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            Text("Settings")
                .font(GargantuaFonts.display)
                .foregroundStyle(GargantuaColors.ink)

            Text(headerSubtitle)
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink3)
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
            PathExclusionSettingsSection(persistence: persistence)
            ProtectedRootsSettingsSection()
        case .about:
            updatesSection
            aboutSection
        }
    }
}

// MARK: - Sections, helpers, and bindings

extension SettingsView {

    // MARK: - AI Tab Intro

    fileprivate var aiTabIntro: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                Text("Active explanation engine")
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(GargantuaColors.ink3)

                Text(activeExplanationEngineLabel)
                    .font(GargantuaFonts.title)
                    .foregroundStyle(GargantuaColors.ink)

                Text(activeExplanationEngineDetail)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(GargantuaSpacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GargantuaColors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.borderSoft, lineWidth: 1)
        )
    }

    private var activeExplanationEngineLabel: String {
        switch (preferredAIEngine, downloadManager.state) {
        case (.mlx, .downloaded): return "Local MLX"
        case (.mlx, _): return "Local MLX (not downloaded)"
        case (.template, _): return "Template (rule-based)"
        }
    }

    private var activeExplanationEngineDetail: String {
        switch (preferredAIEngine, downloadManager.state) {
        case (.mlx, .downloaded):
            if let size = downloadManager.formattedDownloadedSize {
                return "Powers in-app explanations. Ready, \(size) on disk."
            }
            return "Powers in-app explanations. Ready."
        case (.mlx, .downloading):
            return "Local model still downloading. Template explanations run until it lands."
        case (.mlx, .failed):
            return "Local model download failed. Template explanations run until it succeeds."
        case (.mlx, .notDownloaded):
            return "Local model not on disk yet. Template explanations run until you download it below."
        case (.template, _):
            return "Powers in-app explanations. Instant, no model required."
        }
    }

    // MARK: - AI Model Section

    fileprivate var modelSection: some View {
        SettingsSectionContainer(
            "Local AI Engine",
            subtitle: "Toggle between the rule-based template engine and a local MLX model."
        ) {
            enginePreferenceRow

            if useLocalAI {
                Divider()
                    .overlay(GargantuaColors.border)

                modelInfoRow

                if shouldShowMLXDownloadNotice {
                    SettingsNoticeRow(
                        icon: "arrow.down.circle",
                        message: "MLX needs the local model before it can be used. The app will use template explanations until the download is ready.",
                        tone: .info
                    )
                }

                if case .downloading(let progress, _) = downloadManager.state {
                    downloadProgressView(progress: progress)
                }

                if case .failed(let message) = downloadManager.state {
                    SettingsNoticeRow(
                        icon: "exclamationmark.triangle.fill",
                        message: message,
                        tone: .protected
                    )
                }

                modelActionRow
            }
        }
    }

    private var modelInfoRow: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: "cpu", size: 20)

            SettingsRowText(
                title: downloadManager.modelInfo.name,
                detail: modelStatusText,
                detailColor: modelStatusColor
            )

            Spacer()

            modelSizeLabel
        }
    }

    private func downloadProgressView(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: GargantuaRadius.small)
                        .fill(GargantuaColors.surface3)

                    RoundedRectangle(cornerRadius: GargantuaRadius.small)
                        .fill(GargantuaColors.accent)
                        .frame(width: max(4, geo.size.width * progress))
                }
            }
            .frame(height: 6)

            HStack {
                Text("\(Int(progress * 100))%")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)

                Spacer()

                if case .downloading(_, let bytesReceived) = downloadManager.state {
                    Text(ByteCountFormatter.string(fromByteCount: bytesReceived, countStyle: .file))
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }
        }
    }

    @ViewBuilder
    private var modelActionRow: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            switch downloadManager.state {
            case .notDownloaded, .failed:
                GargantuaButton(
                    "Download Model",
                    icon: "arrow.down.circle.fill",
                    tone: .primary,
                    action: { downloadManager.startDownload() }
                )
                .help("Fetch the local MLX model")

                Text("~\(downloadManager.formattedExpectedSize)")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink4)

            case .downloading:
                GargantuaButton(
                    "Cancel",
                    icon: "xmark.circle.fill",
                    tone: .ghost(GargantuaColors.protected_),
                    action: { downloadManager.cancelDownload() }
                )

            case .downloaded:
                HStack(spacing: GargantuaSpacing.space2) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(GargantuaColors.safe)
                    Text("Ready")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.safe)
                }

                Spacer()

                GargantuaButton(
                    "Delete",
                    icon: "trash",
                    tone: .ghost(GargantuaColors.protected_),
                    action: { isShowingDeleteModelConfirm = true }
                )
                .help("Remove the downloaded model from disk")
            }
        }
    }

    // MARK: - Scheduling Section

    fileprivate var schedulingSection: some View {
        SettingsSectionContainer(
            "Scheduling",
            subtitle: "Background scans run via launchd. Use the Light profile for low-impact runs."
        ) {
            HStack(alignment: .center, spacing: GargantuaSpacing.space3) {
                SettingsRowIcon(systemName: "calendar.badge.clock", size: 20)

                SettingsRowText(
                    title: "Background scans",
                    detail: scheduledScanStatusLine,
                    detailColor: scheduledScanStatusColor
                )

                Spacer(minLength: GargantuaSpacing.space3)

                Toggle("Background scans", isOn: scheduledScansEnabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help((settings?.autoScanEnabled ?? false) ? "Disable scheduled scans" : "Enable scheduled scans")
            }

            Divider()
                .overlay(GargantuaColors.border)

            schedulingPickerRow(
                icon: "clock",
                title: "Interval",
                detail: scheduledInterval.detail
            ) {
                Picker("Interval", selection: scheduledIntervalBinding) {
                    ForEach(ScheduledScanInterval.allCases) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            if scheduledInterval == .custom {
                customCronRow
            }

            schedulingPickerRow(
                icon: "person.crop.circle",
                title: "Profile",
                detail: "Cleanup profile applied to scheduled runs."
            ) {
                Picker("Profile", selection: scheduledProfileBinding) {
                    ForEach(availableProfiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }

            updateToggleRow(
                icon: "battery.50",
                label: "Skip on battery",
                detail: "Pause scheduled scans while running on battery power.",
                isOn: skipScheduledScansOnBatteryBinding
            )

            if let scheduledScanError {
                SettingsNoticeRow(
                    icon: "exclamationmark.triangle.fill",
                    message: scheduledScanError,
                    tone: .protected
                )
            }
        }
    }

    private var customCronRow: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: "terminal", size: 16)

            SettingsRowText(
                title: "Cron",
                detail: customScheduleIsValid
                    ? "Five fields: minute hour day month weekday."
                    : "Invalid cron. Five fields required: minute hour day month weekday.",
                detailColor: customScheduleIsValid ? GargantuaColors.ink3 : GargantuaColors.protected_
            )

            Spacer(minLength: GargantuaSpacing.space3)

            TextField("0 9 * * *", text: customScheduleBinding)
                .font(GargantuaFonts.monoData)
                .textFieldStyle(.plain)
                .padding(.horizontal, GargantuaSpacing.space3)
                .padding(.vertical, GargantuaSpacing.space2)
                .background(GargantuaColors.surface3)
                .overlay(
                    RoundedRectangle(cornerRadius: GargantuaRadius.small)
                        .stroke(customScheduleIsValid ? GargantuaColors.border : GargantuaColors.protected_, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                .frame(width: 170)
                .help("Standard 5-field cron expression")
        }
    }

    // MARK: - Updates Section

    fileprivate var updatesSection: some View {
        SettingsSectionContainer(
            "Updates",
            subtitle: "App updates are delivered through Sparkle."
        ) {
            HStack(spacing: GargantuaSpacing.space3) {
                SettingsRowIcon(systemName: "arrow.triangle.2.circlepath.circle", size: 20)

                SettingsRowText(title: updateFeedDisplay, detail: updateLastCheckDisplay)

                Spacer(minLength: GargantuaSpacing.space3)

                GargantuaButton(
                    "Check now",
                    icon: "arrow.clockwise",
                    tone: .ghost(GargantuaColors.accent),
                    isDisabled: !updateSettingsViewModel.canCheckForUpdates,
                    action: { updateSettingsViewModel.userCheckForUpdates() }
                )
                .help("Check the Sparkle feed for a newer release")
            }

            Divider()
                .overlay(GargantuaColors.border)

            HStack(alignment: .center, spacing: GargantuaSpacing.space3) {
                SettingsRowIcon(systemName: "antenna.radiowaves.left.and.right", size: 16)

                SettingsRowText(title: "Channel", detail: updateSettingsViewModel.channel.detail)

                Spacer(minLength: GargantuaSpacing.space3)

                Picker("Channel", selection: updateChannelBinding) {
                    ForEach(AppUpdateChannel.allCases) { channel in
                        Text(channel.label).tag(channel)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            updateToggleRow(
                icon: "clock.arrow.circlepath",
                label: "Automatic checks",
                detail: "Sparkle polls the feed in the background.",
                isOn: Binding(
                    get: { updateSettingsViewModel.automaticallyChecksForUpdates },
                    set: { updateSettingsViewModel.userSetAutomaticallyChecksForUpdates($0) }
                )
            )

            updateToggleRow(
                icon: "arrow.down.circle",
                label: "Automatic downloads",
                detail: "Pre-fetch new releases without prompting.",
                isOn: Binding(
                    get: { updateSettingsViewModel.automaticallyDownloadsUpdates },
                    set: { updateSettingsViewModel.userSetAutomaticallyDownloadsUpdates($0) }
                ),
                isDisabled: !updateSettingsViewModel.automaticallyChecksForUpdates || !updateSettingsViewModel.allowsAutomaticUpdates
            )
        }
    }

    // MARK: - Menu Bar Section

    fileprivate var menuBarSection: some View {
        SettingsSectionContainer(
            "Menu Bar",
            subtitle: "Glanceable Gargantua state from the menu bar."
        ) {
            HStack(alignment: .center, spacing: GargantuaSpacing.space3) {
                SettingsRowIcon(systemName: "menubar.rectangle", size: 20)

                SettingsRowText(
                    title: "Menu bar widget",
                    detail: menuBarWidgetStatusLine,
                    detailColor: menuBarWidgetStatusColor
                )

                Spacer(minLength: GargantuaSpacing.space3)

                Toggle("Menu bar widget", isOn: $menuBarWidgetEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help(menuBarWidgetEnabled ? "Hide menu bar widget" : "Show menu bar widget")
            }

            Divider()
                .overlay(GargantuaColors.border)

            updateToggleRow(
                icon: "power.circle",
                label: "Launch at login",
                detail: launchAtLoginStatusLine,
                detailColor: launchAtLoginStatusColor,
                isOn: launchAtLoginBinding
            )

            if let launchAtLoginError {
                SettingsNoticeRow(
                    icon: "exclamationmark.triangle.fill",
                    message: launchAtLoginError,
                    tone: .protected
                )
            }
        }
    }

    // MARK: - About Section

    fileprivate var aboutSection: some View {
        SettingsSectionContainer(
            "About",
            subtitle: "Version, status, and links."
        ) {
            SettingsValueRow(icon: "app.badge", label: "App", value: appVersionString, monoValue: true)
            SettingsValueRow(icon: "doc.text", label: "License", value: "AGPL-3.0", monoValue: false)
            SettingsValueRow(
                icon: "person.2",
                label: "Active profile",
                value: settings?.activeProfileID ?? "developer",
                monoValue: false
            )
            SettingsValueRow(
                icon: "clock",
                label: "Audit retention",
                value: "\(settings?.retentionDays ?? 90) days",
                monoValue: true
            )

            if let lastScan = settings?.lastScanDate {
                SettingsValueRow(
                    icon: "calendar",
                    label: "Last scan",
                    value: lastScan.formatted(date: .abbreviated, time: .shortened),
                    monoValue: true
                )
            }
        }
    }

    private var appVersionString: String {
        let bundle = Bundle.main
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: - Helpers

    private var enginePreferenceRow: some View {
        HStack(alignment: .center, spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(
                systemName: useLocalAI ? "sparkles" : "doc.text",
                size: 16
            )

            SettingsRowText(
                title: "Use local AI",
                detail: useLocalAI
                    ? "On. Generated locally; first run takes longer while shaders compile."
                    : "Off. Instant rule-based explanations from the YAML library."
            )

            Spacer(minLength: GargantuaSpacing.space3)

            Toggle("Use local AI", isOn: useLocalAIBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .help(useLocalAI ? "Switch to template engine" : "Switch to MLX local engine")
        }
    }

    /// Maps the persisted `AIEnginePreference` to the settings toggle.
    /// Off → Template (instant, rule-based). On → MLX (real local model).
    private var useLocalAI: Bool {
        preferredAIEngine == .mlx
    }

    private var useLocalAIBinding: Binding<Bool> {
        Binding(
            get: { useLocalAI },
            set: { isOn in
                preferredAIEngineRawValue = (isOn ? AIEnginePreference.mlx : .template).rawValue
            }
        )
    }

    private func updateToggleRow(
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

    private func schedulingPickerRow<Control: View>(
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: icon, size: 16)

            SettingsRowText(title: title, detail: detail)

            Spacer(minLength: GargantuaSpacing.space3)

            control()
        }
    }

    private var modelStatusText: String {
        switch downloadManager.state {
        case .notDownloaded: "Not downloaded"
        case .downloading: "Downloading…"
        case .downloaded: "Downloaded"
        case .failed: "Download failed"
        }
    }

    private var modelStatusColor: Color {
        switch downloadManager.state {
        case .notDownloaded: GargantuaColors.ink4
        case .downloading: GargantuaColors.accent
        case .downloaded: GargantuaColors.safe
        case .failed: GargantuaColors.protected_
        }
    }

    private var preferredAIEngine: AIEnginePreference {
        AIEnginePreference(rawValue: preferredAIEngineRawValue) ?? .template
    }

    private var shouldShowMLXDownloadNotice: Bool {
        guard preferredAIEngine == .mlx else { return false }
        if case .downloaded = downloadManager.state { return false }
        return true
    }

    private var updateChannelBinding: Binding<AppUpdateChannel> {
        Binding(
            get: { updateSettingsViewModel.channel },
            set: { updateSettingsViewModel.userSetChannel($0) }
        )
    }

    private var updateFeedDisplay: String {
        guard let host = updateSettingsViewModel.feedURL?.host, !host.isEmpty else {
            return "Sparkle"
        }
        return host
    }

    private var updateLastCheckDisplay: String {
        guard let date = updateSettingsViewModel.lastUpdateCheckDate else {
            return "No checks yet"
        }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var menuBarWidgetStatusLine: String {
        menuBarWidgetEnabled ? "Visible" : "Off"
    }

    private var menuBarWidgetStatusColor: Color {
        menuBarWidgetEnabled ? GargantuaColors.safe : GargantuaColors.ink4
    }

    private var launchAtLoginStatusLine: String {
        if !launchAtLoginEnabled && launchAtLoginStatus == .notRegistered {
            return "Off"
        }
        return launchAtLoginStatus.description
    }

    private var launchAtLoginStatusColor: Color {
        guard launchAtLoginEnabled else { return GargantuaColors.ink4 }
        switch launchAtLoginStatus {
        case .enabled:
            return GargantuaColors.safe
        case .requiresApproval:
            return GargantuaColors.review
        case .notRegistered, .notFound, .unavailable, .unknown:
            return GargantuaColors.protected_
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled },
            set: { enabled in
                updateLaunchAtLogin(enabled)
            }
        )
    }

    private var scheduledInterval: ScheduledScanInterval {
        ScheduledScanInterval(rawValue: settings?.scheduledScanIntervalRaw ?? "") ?? .daily
    }

    private var customScheduleIsValid: Bool {
        scheduledInterval != .custom
            || ScheduledScanCronExpression(settings?.scheduledScanCustomSchedule ?? "") != nil
    }

    private var scheduledScanStatusLine: String {
        if settings?.autoScanEnabled != true {
            return "Off"
        }
        return scheduledScanAgentStatus.description
    }

    private var scheduledScanStatusColor: Color {
        guard settings?.autoScanEnabled == true else { return GargantuaColors.ink4 }
        switch scheduledScanAgentStatus {
        case .enabled: return GargantuaColors.safe
        case .requiresApproval: return GargantuaColors.review
        case .notRegistered, .notFound, .unavailable, .unknown: return GargantuaColors.protected_
        }
    }

    private var scheduledScansEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings?.autoScanEnabled ?? false },
            set: { enabled in
                updateSchedulingSettings { settings in
                    settings.autoScanEnabled = enabled
                }
            }
        )
    }

    private var scheduledIntervalBinding: Binding<ScheduledScanInterval> {
        Binding(
            get: { scheduledInterval },
            set: { interval in
                updateSchedulingSettings { settings in
                    settings.scheduledScanIntervalRaw = interval.rawValue
                }
            }
        )
    }

    private var customScheduleBinding: Binding<String> {
        Binding(
            get: { settings?.scheduledScanCustomSchedule ?? "0 9 * * *" },
            set: { value in
                updateSchedulingSettings { settings in
                    settings.scheduledScanCustomSchedule = value
                }
            }
        )
    }

    private var scheduledProfileBinding: Binding<String> {
        Binding(
            get: { settings?.scheduledScanProfileID ?? "light" },
            set: { profileID in
                updateSchedulingSettings { settings in
                    settings.scheduledScanProfileID = profileID
                }
            }
        )
    }

    private var skipScheduledScansOnBatteryBinding: Binding<Bool> {
        Binding(
            get: { settings?.scheduledScanSkipWhenOnBattery ?? true },
            set: { skip in
                updateSchedulingSettings { settings in
                    settings.scheduledScanSkipWhenOnBattery = skip
                }
            }
        )
    }

    private func updateSchedulingSettings(_ update: (PersistedSettings) -> Void) {
        do {
            try persistence.updateSettings(update)
            let fetched = try persistence.fetchSettings()
            settings = fetched
            let configuration = ScheduledScanConfiguration(settings: fetched)
            if configuration.canSynchronizeLaunchAgent {
                scheduledScanAgentStatus = try ScheduledScanController().synchronize(configuration: configuration)
                scheduledScanError = nil
            } else {
                scheduledScanError = "Custom schedule is not valid."
            }
        } catch {
            scheduledScanError = error.localizedDescription
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        let previous = launchAtLoginEnabled
        launchAtLoginEnabled = enabled

        do {
            launchAtLoginStatus = try LaunchAtLoginController().synchronize(isEnabled: enabled)
            launchAtLoginError = nil
        } catch {
            launchAtLoginEnabled = previous
            launchAtLoginError = error.localizedDescription
        }
    }

    private var modelSizeLabel: some View {
        Group {
            if let size = downloadManager.formattedDownloadedSize {
                Text(size)
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)
            } else {
                Text(downloadManager.formattedExpectedSize)
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink4)
            }
        }
    }
}
