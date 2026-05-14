import SwiftUI

/// Settings section for the AI file organizer's backend choice. Sits
/// inside the AI tab between the Cloud AI section and the agent section.
///
/// The picker writes through `@AppStorage` so the choice is read by
/// `OrganizerBackendPreference.stored(in:)` from anywhere — view models,
/// CLI tools, MCP entry points. When no Anthropic key is configured the
/// Cloud row is shown disabled with a hint pointing at the section above.
struct FileOrganizerSettingsSection: View {
    @AppStorage(OrganizerBackendPreference.userDefaultsKey)
    private var rawPreference = OrganizerBackendPreference.local.rawValue

    @State private var cloudReady = false
    private let configurationStore = CloudAIConfigurationStore()
    private let keyStore: any CloudAPIKeyStore = KeychainCloudAPIKeyStore()

    var body: some View {
        SettingsSectionContainer(
            "AI File Organizer",
            subtitle: "Choose how the Organize tab in Deep Clean generates groupings."
        ) {
            ForEach(OrganizerBackendPreference.allCases) { option in
                row(for: option)
                if option != OrganizerBackendPreference.allCases.last {
                    Divider().overlay(GargantuaColors.border)
                }
            }

            if !cloudReady, selectedPreference == .local {
                SettingsNoticeRow(
                    icon: "info.circle",
                    message: "Cloud AI is not configured — On-device is used until you add an Anthropic key above.",
                    tone: .info
                )
            }
        }
        .task { refreshCloudReadiness() }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(for option: OrganizerBackendPreference) -> some View {
        let isSelected = selectedPreference == option
        let isCloudGated = option == .cloud && !cloudReady

        HStack(spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: option.systemImage, size: 20)

            SettingsRowText(
                title: option.label,
                detail: detail(for: option, isCloudGated: isCloudGated)
            )

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(GargantuaColors.accent)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isCloudGated else { return }
            rawPreference = option.rawValue
        }
        .opacity(isCloudGated ? 0.5 : 1.0)
    }

    private func detail(for option: OrganizerBackendPreference, isCloudGated: Bool) -> String {
        if isCloudGated {
            return "Requires an Anthropic key in the Cloud AI section above."
        }
        return option.settingsDescription
    }

    // MARK: - State

    private var selectedPreference: OrganizerBackendPreference {
        OrganizerBackendPreference(rawValue: rawPreference) ?? .local
    }

    private func refreshCloudReadiness() {
        let configEnabled = configurationStore.load().isEnabled
        let hasKey = (try? keyStore.hasKey()) ?? false
        cloudReady = configEnabled && hasKey
        // Auto-downgrade to local if the user previously selected cloud
        // but the key is gone — silent rather than throwing a UI error
        // when the user opens Settings.
        if !cloudReady, selectedPreference == .cloud {
            rawPreference = OrganizerBackendPreference.local.rawValue
        }
    }
}
