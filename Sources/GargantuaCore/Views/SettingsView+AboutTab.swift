import SwiftUI

extension SettingsView {
    // MARK: - Updates Section

    var updatesSection: some View {
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

    // MARK: - About Section

    var aboutSection: some View {
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

    // MARK: - Helpers

    private var appVersionString: String {
        let bundle = Bundle.main
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
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
}
