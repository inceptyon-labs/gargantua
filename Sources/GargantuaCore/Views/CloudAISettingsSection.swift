import SwiftUI

struct CloudAISettingsSection: View {
    @State var configuration = CloudAIConfiguration()
    @State var apiKeyInput = ""
    @State var apiKeyStatus = "Not configured"
    @State var status: CloudAIStatus?
    @State var isShowingRevokeConfirm = false

    let configurationStore = CloudAIConfigurationStore()

    /// Keychain store for the currently selected provider.
    var activeKeyStore: any CloudAPIKeyStore {
        CloudAPIKeyStores.store(for: configuration)
    }

    private var isOpenAICompatible: Bool {
        configuration.provider == .openAICompatible
    }

    var body: some View {
        SettingsSectionContainer(
            "Cloud AI",
            subtitle: "Hosted reasoning over a public API. Anthropic, or any OpenAI-compatible endpoint "
                + "(OpenRouter, Groq, Ollama, LM Studio…). User-supplied key; off by default."
        ) {
            statusHeader

            if configuration.isEnabled {
                Divider()
                    .overlay(GargantuaColors.border)

                providerPicker

                if isOpenAICompatible {
                    baseURLRow
                    if configuration.usesInsecureRemoteEndpoint {
                        SettingsNoticeRow(
                            icon: "exclamationmark.triangle.fill",
                            message: "Plain HTTP to a non-local host: your API key and any file snippets would be sent "
                                + "unencrypted. Use HTTPS unless this is on your LAN.",
                            tone: .review
                        )
                    }
                    modelRow
                }

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
                if !isOpenAICompatible {
                    monthlyCapStepper
                }
                usageRows
            } else {
                Text("Enable to pick a provider and set the API key.")
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
                title: "Revoke \(configuration.provider.displayName) API key?",
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
