import SwiftUI

struct CloudAISettingsSection: View {
    @State var configuration = CloudAIConfiguration()
    @State var apiKeyInput = ""
    @State var apiKeyStatus = "Not configured"
    @State var status: CloudAIStatus?
    @State var isShowingRevokeConfirm = false

    let configurationStore = CloudAIConfigurationStore()
    let keyStore: any CloudAPIKeyStore = KeychainCloudAPIKeyStore()

    var body: some View {
        SettingsSectionContainer(
            "Cloud AI (Anthropic)",
            subtitle: "Hosted Claude reasoning over the public Anthropic API. Requires a user-supplied key; off by default."
        ) {
            statusHeader

            if configuration.isEnabled {
                Divider()
                    .overlay(GargantuaColors.border)

                apiKeyRow

                if !apiKeyStatus.isEmpty {
                    SettingsNoticeRow(
                        icon: apiKeyStatusIcon,
                        message: apiKeyStatus,
                        tone: apiKeyStatusTone
                    )
                }

                privacyDisclosure
                consentToggle
                monthlyCapStepper
                usageRows
            } else {
                Text("Enable to set the API key, monthly cap, and usage caps.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
        }
        .task {
            configuration = configurationStore.load()
            await refreshStatus()
        }
        .sheet(isPresented: $isShowingRevokeConfirm) {
            DestructiveConfirmSheet(
                title: "Revoke Anthropic API key?",
                message: "The key will be deleted from Keychain. Cloud AI will stop working until a new key is saved. This cannot be undone.",
                confirmLabel: "Revoke key",
                onCancel: { isShowingRevokeConfirm = false },
                onConfirm: {
                    isShowingRevokeConfirm = false
                    revokeAPIKey()
                }
            )
        }
    }
}
