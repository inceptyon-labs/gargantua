import SwiftUI

extension CloudAISettingsSection {

    // MARK: - Status header

    var statusHeader: some View {
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

    // MARK: - Provider + endpoint + model

    var providerPicker: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: "server.rack", size: 14)
            SettingsRowText(title: "Provider", detail: "Anthropic, or any OpenAI-compatible API.")
            Spacer()
            Menu {
                ForEach(CloudAIProvider.allCases) { provider in
                    Button(provider.displayName) { selectProvider(provider) }
                }
            } label: {
                HStack(spacing: GargantuaSpacing.space1) {
                    Text(configuration.provider.displayName)
                        .font(GargantuaFonts.label)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(GargantuaColors.ink4)
                }
                .foregroundStyle(GargantuaColors.ink)
                .padding(.horizontal, GargantuaSpacing.space3)
                .padding(.vertical, GargantuaSpacing.space2)
                .background(GargantuaColors.surface3)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    var baseURLRow: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: "link", size: 14)

            TextField("https://api.openai.com/v1", text: Binding(
                get: { configuration.openAIBaseURL },
                set: { configuration.openAIBaseURL = $0 }
            ))
            .textFieldStyle(.plain)
            .font(GargantuaFonts.monoData)
            .foregroundStyle(GargantuaColors.ink)
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(GargantuaColors.surface3)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            .onSubmit(saveConfiguration)

            Menu {
                ForEach(Self.baseURLPresets, id: \.url) { preset in
                    Button(preset.label) {
                        configuration.openAIBaseURL = preset.url
                        saveConfiguration()
                    }
                }
            } label: {
                Image(systemName: "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Preset endpoints")

            GargantuaButton(
                "Save",
                icon: "checkmark.circle.fill",
                tone: .ghost(GargantuaColors.safe),
                action: saveConfiguration
            )
            .help("Save endpoint")
        }
    }

    var modelRow: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: "cpu", size: 14)

            TextField(configuration.provider.defaultModel, text: Binding(
                get: { configuration.model },
                set: { configuration.model = $0 }
            ))
            .textFieldStyle(.plain)
            .font(GargantuaFonts.monoData)
            .foregroundStyle(GargantuaColors.ink)
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(GargantuaColors.surface3)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            .onSubmit(saveConfiguration)

            GargantuaButton(
                "Save",
                icon: "checkmark.circle.fill",
                tone: .ghost(GargantuaColors.safe),
                action: saveConfiguration
            )
            .help("Save model")
        }
    }

    static var baseURLPresets: [(label: String, url: String)] {
        [
            ("OpenAI", "https://api.openai.com/v1"),
            ("OpenRouter", "https://openrouter.ai/api/v1"),
            ("Groq", "https://api.groq.com/openai/v1"),
            ("Together", "https://api.together.xyz/v1"),
            ("Ollama (local)", "http://localhost:11434/v1"),
            ("LM Studio (local)", "http://localhost:1234/v1"),
        ]
    }

    // MARK: - API key row

    var apiKeyRow: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: "key", size: 14)

            SecureField(apiKeyPlaceholder, text: $apiKeyInput)
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
            .help("Delete the stored \(configuration.provider.displayName) key")
        }
    }

    var apiKeyPlaceholder: String {
        switch configuration.provider {
        case .anthropic: "Anthropic API key"
        case .openAICompatible: "API key (leave blank for local servers)"
        }
    }

    // MARK: - Privacy disclosure

    var privacyDisclosure: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            SettingsSubsectionHeader("Where your data goes")

            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                disclosureLine("Stored in macOS Keychain. Never written to disk in plaintext.")
                disclosureLine(endpointDisclosure)
                disclosureLine("Always sent: file paths, sizes, classifications, confidence scores.")
                disclosureLine("Sent only with the toggle below: short snippets of file contents (4 KB max, redacted for tokens and keys).")
            }
        }
        .padding(GargantuaSpacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GargantuaColors.surface3)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }

    func disclosureLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
            Text("·")
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink3)

            Text(text)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Consent + cap + usage

    var consentToggle: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: "doc.text.magnifyingglass", size: 16)

            SettingsRowText(
                title: "Allow file-content previews",
                detail: "When on, Gargantua may include short snippets of file contents in cloud requests."
            )

            Spacer(minLength: GargantuaSpacing.space3)

            Toggle("Allow file-content previews", isOn: Binding(
                get: { configuration.allowsFileContents },
                set: {
                    configuration.allowsFileContents = $0
                    saveConfiguration()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }

    var monthlyCapStepper: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: "dollarsign.circle", size: 16)

            SettingsRowText(title: "Monthly cap", detail: "Hard ceiling on cloud spend per calendar month.")

            Spacer(minLength: GargantuaSpacing.space3)

            Text(formatCents(configuration.monthlySpendCapCents))
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink2)

            Stepper(
                "Monthly cap",
                value: Binding(
                    get: { configuration.monthlySpendCapCents },
                    set: {
                        configuration.monthlySpendCapCents = max(0, $0)
                        saveConfiguration()
                    }
                ),
                in: 0 ... 100_000,
                step: 100
            )
            .labelsHidden()
        }
    }

    var usageRows: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            SettingsValueRow(
                icon: "creditcard",
                label: "Cost to date",
                value: formatCents(status?.spentCents ?? 0),
                background: GargantuaColors.surface3
            )

            SettingsValueRow(
                icon: "calendar",
                label: "Last run",
                value: lastRunText,
                monoValue: false,
                background: GargantuaColors.surface3
            )
        }
    }

    // MARK: - Status display helpers

    var apiKeyStatusIcon: String {
        switch apiKeyStatusTone {
        case .safe: return "checkmark.circle.fill"
        case .protected: return "xmark.octagon.fill"
        case .review: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    var apiKeyStatusTone: SettingsNoticeRow.Tone {
        if status?.hasAPIKey == true { return .safe }
        if apiKeyStatus == "Not configured" { return .info }
        if apiKeyStatus.contains("revoked") { return .info }
        if apiKeyStatus.contains("Keychain") || apiKeyStatus.contains("stored") { return .safe }
        return .protected
    }

    /// Endpoint line for the privacy disclosure, reflecting the active provider.
    var endpointDisclosure: String {
        switch configuration.provider {
        case .anthropic:
            return "Endpoint: api.anthropic.com over TLS. Nothing else."
        case .openAICompatible:
            let host = configuration.resolvedOpenAIBaseURL?.host ?? "your configured endpoint"
            return "Endpoint: \(host) (whatever you set above). Billing + privacy are governed by that provider."
        }
    }

    var statusText: String {
        guard let status else {
            return "Checking status…"
        }
        if !status.isEnabled {
            return "Off by default. Enable when you want cloud reasoning."
        }
        if configuration.provider == .openAICompatible {
            return "OpenAI-compatible · \(configuration.model) · billed by your provider."
        }
        if !status.hasAPIKey {
            return "Enabled, waiting for an Anthropic API key."
        }
        return "\(formatCents(status.spentCents)) used of \(formatCents(status.monthlySpendCapCents)) this month."
    }

    /// Ready to run: enabled, and — for Anthropic — a key on file. OpenAI-
    /// compatible local servers need no key, so enabled is enough there.
    var providerIsReady: Bool {
        guard configuration.isEnabled else { return false }
        if configuration.provider == .openAICompatible { return true }
        return status?.hasAPIKey == true
    }

    var statusIcon: String {
        if providerIsReady { return "cloud.fill" }
        if configuration.isEnabled { return "key.slash" }
        return "cloud"
    }

    var statusColor: Color {
        if providerIsReady { return GargantuaColors.safe }
        if configuration.isEnabled { return GargantuaColors.review }
        return GargantuaColors.ink4
    }

    var lastRunText: String {
        guard let lastRun = status?.lastRun else {
            return "Never"
        }
        return lastRun.formatted(date: .abbreviated, time: .shortened)
    }

    func formatCents(_ cents: Int) -> String {
        let value = Decimal(cents) / Decimal(100)
        return value.formatted(.currency(code: "USD"))
    }

    // MARK: - Actions

    func saveAPIKey() {
        do {
            try activeKeyStore.save(apiKeyInput)
            apiKeyInput = ""
            apiKeyStatus = "API key stored in Keychain"
        } catch {
            apiKeyStatus = error.localizedDescription
        }
        Task { await refreshStatus() }
    }

    func revokeAPIKey() {
        do {
            try activeKeyStore.delete()
            apiKeyInput = ""
            apiKeyStatus = "API key revoked"
        } catch {
            apiKeyStatus = error.localizedDescription
        }
        Task { await refreshStatus() }
    }

    /// Switches provider, defaulting the model/endpoint for the new provider
    /// when they haven't been customized, then refreshes key status (each
    /// provider keeps its own key, so the status reflects the new one).
    func selectProvider(_ provider: CloudAIProvider) {
        guard provider != configuration.provider else { return }
        configuration.provider = provider
        if provider == .openAICompatible, configuration.openAIBaseURL.isEmpty {
            configuration.openAIBaseURL = provider.defaultBaseURL
        }
        configuration.model = provider.defaultModel
        apiKeyInput = ""
        apiKeyStatus = "Not configured"
        saveConfiguration()
    }

    func saveConfiguration() {
        configurationStore.save(configuration)
        Task { await refreshStatus() }
    }

    func refreshStatus() async {
        status = await CloudAIStatusProvider.snapshot(
            configurationStore: configurationStore,
            keyStore: activeKeyStore
        )
        if status?.hasAPIKey == true, apiKeyStatus == "Not configured" {
            apiKeyStatus = "API key stored in Keychain"
        } else if status?.hasAPIKey == false, apiKeyStatus == "API key stored in Keychain" {
            // A key belongs to the endpoint it was saved for; a new base URL
            // starts without one.
            apiKeyStatus = "Not configured"
        }
    }
}
