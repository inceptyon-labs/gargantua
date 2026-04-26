import SwiftUI

struct CloudAISettingsSection: View {
    @State private var configuration = CloudAIConfiguration()
    @State private var apiKeyInput = ""
    @State private var apiKeyStatus = "Not configured"
    @State private var status: CloudAIStatus?

    private let configurationStore = CloudAIConfigurationStore()
    private let keyStore: any CloudAPIKeyStore = KeychainCloudAPIKeyStore()

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            Text("Cloud AI")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink2)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
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
            .padding(GargantuaSpacing.space4)
            .background(GargantuaColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
        .task {
            configuration = configurationStore.load()
            await refreshStatus()
        }
    }

    private var statusHeader: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            Image(systemName: statusIcon)
                .font(.system(size: 18))
                .foregroundStyle(statusColor)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text("Tier 2 Claude API")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Text(statusText)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { configuration.isEnabled },
                set: {
                    configuration.isEnabled = $0
                    saveConfiguration()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }

    private var apiKeyRow: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "key")
                .font(.system(size: 14))
                .foregroundStyle(GargantuaColors.ink3)
                .frame(width: 20, alignment: .center)

            SecureField("Anthropic API key", text: $apiKeyInput)
                .textFieldStyle(.plain)
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink)
                .padding(.horizontal, GargantuaSpacing.space3)
                .padding(.vertical, GargantuaSpacing.space2)
                .background(GargantuaColors.surface3)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))

            cloudActionButton(
                label: "Save",
                icon: "checkmark.circle.fill",
                color: GargantuaColors.safe,
                action: saveAPIKey
            )

            cloudActionButton(
                label: "Revoke",
                icon: "trash",
                color: GargantuaColors.protected_,
                action: revokeAPIKey
            )
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
            Text("Allow explicit file-content previews")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink)
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
                Text("Monthly Cap")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Spacer()

                Text(formatCents(configuration.monthlySpendCapCents))
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)
            }
        }
    }

    private var usageRows: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            cloudSettingsRow(
                icon: "creditcard",
                label: "Cost to Date",
                value: formatCents(status?.spentCents ?? 0)
            )

            cloudSettingsRow(
                icon: "calendar",
                label: "Last Run",
                value: lastRunText
            )
        }
    }

    private func cloudActionButton(
        label: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
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

    private func cloudSettingsRow(icon: String, label: String, value: String) -> some View {
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
            return "Checking Tier 2 status..."
        }
        if !status.isEnabled {
            return "Off by default. Enable when you want cloud reasoning."
        }
        if !status.hasAPIKey {
            return "Enabled, waiting for a user-supplied Anthropic key."
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
