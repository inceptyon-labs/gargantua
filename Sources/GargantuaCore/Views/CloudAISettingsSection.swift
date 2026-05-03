import SwiftUI

struct CloudAISettingsSection: View {
    @State private var configuration = CloudAIConfiguration()
    @State private var apiKeyInput = ""
    @State private var apiKeyStatus = "Not configured"
    @State private var status: CloudAIStatus?
    @State private var isShowingRevokeConfirm = false

    private let configurationStore = CloudAIConfigurationStore()
    private let keyStore: any CloudAPIKeyStore = KeychainCloudAPIKeyStore()

    var body: some View {
        SettingsSectionContainer(
            "Cloud AI (Anthropic)",
            subtitle: "Hosted Claude reasoning over the public Anthropic API. Requires a user-supplied key; off by default."
        ) {
            statusHeader

            Divider()
                .overlay(GargantuaColors.border)

            apiKeyRow

            Text(apiKeyStatus)
                .font(GargantuaFonts.caption)
                .foregroundStyle(statusColor)

            consentToggle
            monthlyCapStepper
            usageRows
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

    private var statusHeader: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: statusIcon, color: statusColor, size: 18)

            SettingsRowText(title: "Hosted Claude", detail: statusText)

            Spacer()

            Toggle("Enable cloud AI", isOn: Binding(
                get: { configuration.isEnabled },
                set: {
                    configuration.isEnabled = $0
                    saveConfiguration()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .help(configuration.isEnabled ? "Disable cloud AI" : "Enable cloud AI (requires API key)")
        }
    }

    private var apiKeyRow: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: "key", size: 14)

            SecureField("Anthropic API key", text: $apiKeyInput)
                .textFieldStyle(.plain)
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink)
                .padding(.horizontal, GargantuaSpacing.space3)
                .padding(.vertical, GargantuaSpacing.space2)
                .background(GargantuaColors.surface3)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))

            GargantuaButton(
                "Save",
                icon: "checkmark.circle.fill",
                tone: .ghost(GargantuaColors.safe),
                isDisabled: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                action: saveAPIKey
            )
            .help("Save key to Keychain")

            GargantuaButton(
                "Revoke",
                icon: "trash",
                tone: .ghost(GargantuaColors.protected_),
                isDisabled: status?.hasAPIKey != true,
                action: { isShowingRevokeConfirm = true }
            )
            .help("Delete the stored Anthropic key")
        }
    }

    private var consentToggle: some View {
        Toggle(isOn: Binding(
            get: { configuration.allowsFileContents },
            set: {
                configuration.allowsFileContents = $0
                saveConfiguration()
            }
        )) {
            SettingsRowText(
                title: "Allow file-content previews",
                detail: "When on, Gargantua may include short snippets of file contents in cloud requests."
            )
        }
        .toggleStyle(.switch)
    }

    private var monthlyCapStepper: some View {
        Stepper(
            value: Binding(
                get: { configuration.monthlySpendCapCents },
                set: {
                    configuration.monthlySpendCapCents = max(0, $0)
                    saveConfiguration()
                }
            ),
            in: 0 ... 100_000,
            step: 100
        ) {
            HStack {
                SettingsRowText(title: "Monthly cap", detail: nil)

                Spacer()

                Text(formatCents(configuration.monthlySpendCapCents))
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)
            }
        }
        .help("Hard ceiling on cloud spend per calendar month")
    }

    private var usageRows: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            cloudSettingsRow(
                icon: "creditcard",
                label: "Cost to date",
                value: formatCents(status?.spentCents ?? 0)
            )

            cloudSettingsRow(
                icon: "calendar",
                label: "Last run",
                value: lastRunText
            )
        }
    }

    private func cloudSettingsRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: icon, size: 14)

            Text(label)
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink)

            Spacer()

            Text(value)
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink2)
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(GargantuaColors.surface3)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }

    private func saveAPIKey() {
        do {
            try keyStore.save(apiKeyInput)
            apiKeyInput = ""
            apiKeyStatus = "API key stored in Keychain"
        } catch {
            apiKeyStatus = error.localizedDescription
        }
        Task { await refreshStatus() }
    }

    private func revokeAPIKey() {
        do {
            try keyStore.delete()
            apiKeyInput = ""
            apiKeyStatus = "API key revoked"
        } catch {
            apiKeyStatus = error.localizedDescription
        }
        Task { await refreshStatus() }
    }

    private func saveConfiguration() {
        configurationStore.save(configuration)
        Task { await refreshStatus() }
    }

    private func refreshStatus() async {
        status = await CloudAIStatusProvider.snapshot(
            configurationStore: configurationStore,
            keyStore: keyStore
        )
        if status?.hasAPIKey == true, apiKeyStatus == "Not configured" {
            apiKeyStatus = "API key stored in Keychain"
        }
    }

    private var statusText: String {
        guard let status else {
            return "Checking status…"
        }
        if !status.isEnabled {
            return "Off by default. Enable when you want cloud reasoning."
        }
        if !status.hasAPIKey {
            return "Enabled, waiting for an Anthropic API key."
        }
        return "\(formatCents(status.spentCents)) used of \(formatCents(status.monthlySpendCapCents)) this month."
    }

    private var statusIcon: String {
        if status?.isReady == true { return "cloud.fill" }
        if configuration.isEnabled { return "key.slash" }
        return "cloud"
    }

    private var statusColor: Color {
        if status?.isReady == true { return GargantuaColors.safe }
        if configuration.isEnabled { return GargantuaColors.review }
        return GargantuaColors.ink4
    }

    private var lastRunText: String {
        guard let lastRun = status?.lastRun else {
            return "Never"
        }
        return lastRun.formatted(date: .abbreviated, time: .shortened)
    }

    private func formatCents(_ cents: Int) -> String {
        let value = Decimal(cents) / Decimal(100)
        return value.formatted(.currency(code: "USD"))
    }
}
