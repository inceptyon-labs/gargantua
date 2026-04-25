import SwiftUI

/// Settings view with general preferences and AI model management.
///
/// Shows app settings (profile, retention, auto-scan) and an AI model section
/// with download progress, size info, and cancel/delete controls.
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
        ScrollView {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space6) {
                headerView
                modelSection
                CloudAISettingsSection()
                MCPTransportSettingsSection()
                updatesSection
                menuBarSection
                schedulingSection
                ScanRootsSettingsSection(
                    settings: settings,
                    persistence: persistence,
                    onSettingsChanged: { settings = $0 }
                )
                PathExclusionSettingsSection(persistence: persistence)
                generalSection
            }
            .padding(GargantuaSpacing.space6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GargantuaColors.void_)
        .task {
            settings = try? persistence.fetchSettings()
            availableProfiles = ((try? persistence.fetchProfiles()) ?? CleanupProfile.builtIn)
                .filter { !$0.categories.isEmpty }
            scheduledScanAgentStatus = ScheduledScanController().status()
            launchAtLoginStatus = LaunchAtLoginController().status()
            launchAtLoginEnabled = launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
        }
    }

    // MARK: - Header

    private var headerView: some View {
        Text("Settings")
            .font(GargantuaFonts.heading)
            .foregroundStyle(GargantuaColors.ink)
    }

    // MARK: - AI Model Section

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            sectionHeader("AI Model")

            VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                enginePreferenceRow

                Divider()
                    .overlay(GargantuaColors.border)

                // Model info row
                HStack(spacing: GargantuaSpacing.space3) {
                    Image(systemName: "cpu")
                        .font(.system(size: 20))
                        .foregroundStyle(GargantuaColors.accent)
                        .frame(width: 24, alignment: .center)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(downloadManager.modelInfo.name)
                            .font(GargantuaFonts.label)
                            .foregroundStyle(GargantuaColors.ink)

                        Text(modelStatusText)
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(modelStatusColor)
                    }

                    Spacer()

                    modelSizeLabel
                }

                if shouldShowMLXDownloadNotice {
                    HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(GargantuaColors.accent)
                            .frame(width: 16, alignment: .center)

                        Text("MLX needs the local model before it can be used. The app will use template explanations until the download is ready.")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(GargantuaSpacing.space3)
                    .background(GargantuaColors.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }

                // Progress bar (when downloading)
                if case .downloading(let progress, _) = downloadManager.state {
                    VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(GargantuaColors.surface3)

                                RoundedRectangle(cornerRadius: 3)
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

                // Error message
                if case .failed(let message) = downloadManager.state {
                    HStack(spacing: GargantuaSpacing.space2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(GargantuaColors.review)
                        Text(message)
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.review)
                            .lineLimit(2)
                    }
                }

                // Action buttons
                HStack(spacing: GargantuaSpacing.space3) {
                    switch downloadManager.state {
                    case .notDownloaded, .failed:
                        actionButton(
                            label: "Download Model",
                            icon: "arrow.down.circle.fill",
                            color: GargantuaColors.accent
                        ) {
                            downloadManager.startDownload()
                        }

                        Text("~\(downloadManager.formattedExpectedSize)")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink4)

                    case .downloading:
                        actionButton(
                            label: "Cancel",
                            icon: "xmark.circle.fill",
                            color: GargantuaColors.protected_
                        ) {
                            downloadManager.cancelDownload()
                        }

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

                        actionButton(
                            label: "Delete",
                            icon: "trash",
                            color: GargantuaColors.protected_
                        ) {
                            downloadManager.deleteModel()
                        }
                    }
                }
            }
            .padding(GargantuaSpacing.space4)
            .background(GargantuaColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
    }

    // MARK: - Scheduling Section

    private var schedulingSection: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            sectionHeader("Scheduling")

            VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                HStack(alignment: .center, spacing: GargantuaSpacing.space3) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 20))
                        .foregroundStyle(GargantuaColors.accent)
                        .frame(width: 24, alignment: .center)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Background Scans")
                            .font(GargantuaFonts.label)
                            .foregroundStyle(GargantuaColors.ink)

                        Text(scheduledScanStatusLine)
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(scheduledScanStatusColor)
                    }

                    Spacer(minLength: GargantuaSpacing.space3)

                    Toggle("Background Scans", isOn: scheduledScansEnabledBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
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
                    HStack(spacing: GargantuaSpacing.space3) {
                        Image(systemName: "terminal")
                            .font(.system(size: 16))
                            .foregroundStyle(GargantuaColors.ink3)
                            .frame(width: 24, alignment: .center)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cron")
                                .font(GargantuaFonts.label)
                                .foregroundStyle(GargantuaColors.ink)

                            Text("Five fields: minute hour day month weekday")
                                .font(GargantuaFonts.caption)
                                .foregroundStyle(customScheduleIsValid ? GargantuaColors.ink3 : GargantuaColors.review)
                        }

                        Spacer(minLength: GargantuaSpacing.space3)

                        TextField("0 9 * * *", text: customScheduleBinding)
                            .font(GargantuaFonts.monoData)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, GargantuaSpacing.space3)
                            .padding(.vertical, GargantuaSpacing.space2)
                            .background(GargantuaColors.surface3)
                            .overlay(
                                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                                    .stroke(customScheduleIsValid ? GargantuaColors.border : GargantuaColors.review, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                            .frame(width: 170)
                    }
                }

                schedulingPickerRow(
                    icon: "person.crop.circle",
                    title: "Profile",
                    detail: "Default is Light for low-impact background runs."
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
                    label: "Skip on Battery",
                    isOn: skipScheduledScansOnBatteryBinding
                )

                if let scheduledScanError {
                    HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(GargantuaColors.review)

                        Text(scheduledScanError)
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.review)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(GargantuaSpacing.space4)
            .background(GargantuaColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
    }

    // MARK: - Updates Section

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            sectionHeader("Updates")

            VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                HStack(spacing: GargantuaSpacing.space3) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(GargantuaColors.accent)
                        .frame(width: 24, alignment: .center)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(updateFeedDisplay)
                            .font(GargantuaFonts.label)
                            .foregroundStyle(GargantuaColors.ink)

                        Text(updateLastCheckDisplay)
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink3)
                    }

                    Spacer(minLength: GargantuaSpacing.space3)

                    actionButton(
                        label: "Check Now",
                        icon: "arrow.clockwise",
                        color: updateSettingsViewModel.canCheckForUpdates ? GargantuaColors.accent : GargantuaColors.ink4
                    ) {
                        updateSettingsViewModel.userCheckForUpdates()
                    }
                    .disabled(!updateSettingsViewModel.canCheckForUpdates)
                }

                Divider()
                    .overlay(GargantuaColors.border)

                HStack(alignment: .center, spacing: GargantuaSpacing.space3) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 16))
                        .foregroundStyle(GargantuaColors.accent)
                        .frame(width: 24, alignment: .center)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Channel")
                            .font(GargantuaFonts.label)
                            .foregroundStyle(GargantuaColors.ink)

                        Text(updateSettingsViewModel.channel.detail)
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink3)
                    }

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
                    label: "Automatic Checks",
                    isOn: Binding(
                        get: { updateSettingsViewModel.automaticallyChecksForUpdates },
                        set: { updateSettingsViewModel.userSetAutomaticallyChecksForUpdates($0) }
                    )
                )

                updateToggleRow(
                    icon: "arrow.down.circle",
                    label: "Automatic Downloads",
                    isOn: Binding(
                        get: { updateSettingsViewModel.automaticallyDownloadsUpdates },
                        set: { updateSettingsViewModel.userSetAutomaticallyDownloadsUpdates($0) }
                    )
                )
                .disabled(!updateSettingsViewModel.automaticallyChecksForUpdates || !updateSettingsViewModel.allowsAutomaticUpdates)
            }
            .padding(GargantuaSpacing.space4)
            .background(GargantuaColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
    }

    // MARK: - Menu Bar Section

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            sectionHeader("Menu Bar")

            VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                HStack(alignment: .center, spacing: GargantuaSpacing.space3) {
                    Image(systemName: "menubar.rectangle")
                        .font(.system(size: 20))
                        .foregroundStyle(GargantuaColors.accent)
                        .frame(width: 24, alignment: .center)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Menu Bar Widget")
                            .font(GargantuaFonts.label)
                            .foregroundStyle(GargantuaColors.ink)

                        Text(menuBarWidgetStatusLine)
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(menuBarWidgetStatusColor)
                    }

                    Spacer(minLength: GargantuaSpacing.space3)

                    Toggle("Menu Bar Widget", isOn: $menuBarWidgetEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                Divider()
                    .overlay(GargantuaColors.border)

                updateToggleRow(
                    icon: "power.circle",
                    label: "Launch at Login",
                    isOn: launchAtLoginBinding
                )

                HStack(spacing: GargantuaSpacing.space3) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13))
                        .foregroundStyle(GargantuaColors.ink3)
                        .frame(width: 24, alignment: .center)

                    Text(launchAtLoginStatusLine)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(launchAtLoginStatusColor)

                    Spacer()
                }

                if let launchAtLoginError {
                    HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(GargantuaColors.review)

                        Text(launchAtLoginError)
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.review)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(GargantuaSpacing.space4)
            .background(GargantuaColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
    }

    // MARK: - General Section

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            sectionHeader("General")

            VStack(spacing: 1) {
                settingsRow(
                    icon: "person.2",
                    label: "Active Profile",
                    value: settings?.activeProfileID ?? "developer"
                )

                settingsRow(
                    icon: "clock",
                    label: "Audit Retention",
                    value: "\(settings?.retentionDays ?? 90) days"
                )

                settingsRow(
                    icon: "arrow.triangle.2.circlepath",
                    label: "Scheduled Scans",
                    value: (settings?.autoScanEnabled ?? false) ? scheduledInterval.label : "Disabled"
                )

                if let lastScan = settings?.lastScanDate {
                    settingsRow(
                        icon: "calendar",
                        label: "Last Scan",
                        value: lastScan.formatted(date: .abbreviated, time: .shortened)
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(GargantuaFonts.label)
            .foregroundStyle(GargantuaColors.ink2)
    }

    private var enginePreferenceRow: some View {
        HStack(alignment: .center, spacing: GargantuaSpacing.space3) {
            Image(systemName: preferredAIEngine.systemImage)
                .font(.system(size: 16))
                .foregroundStyle(GargantuaColors.accent)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text("Engine")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Text(preferredAIEngine.settingsDescription)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }

            Spacer(minLength: GargantuaSpacing.space3)

            Picker("Engine", selection: $preferredAIEngineRawValue) {
                ForEach(AIEnginePreference.allCases) { preference in
                    Text(preference.label).tag(preference.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 180)
        }
    }

    private func settingsRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(GargantuaColors.ink3)
                .frame(width: 20, alignment: .center)

            Text(label)
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink)

            Spacer()

            Text(value)
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink2)
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
        .background(GargantuaColors.surface2)
    }

    private func updateToggleRow(icon: String, label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(GargantuaColors.ink3)
                .frame(width: 24, alignment: .center)

            Text(label)
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink)

            Spacer()

            Toggle(label, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
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
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(GargantuaColors.ink3)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Text(detail)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(2)
            }

            Spacer(minLength: GargantuaSpacing.space3)

            control()
        }
    }

    private func actionButton(label: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(label)
                    .font(GargantuaFonts.label)
            }
            .foregroundStyle(color)
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        }
        .buttonStyle(.plain)
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
        case .failed: GargantuaColors.review
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
            return GargantuaColors.review
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
        case .notRegistered, .notFound, .unavailable, .unknown: return GargantuaColors.review
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
