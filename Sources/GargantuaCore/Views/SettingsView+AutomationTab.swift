import SwiftUI

extension SettingsView {
    // MARK: - Scheduling Section

    var schedulingSection: some View {
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

    // MARK: - Menu Bar Section

    var menuBarSection: some View {
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

    // MARK: - Helpers

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
}
