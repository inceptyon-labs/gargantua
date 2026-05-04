import SwiftUI

struct ClaudeCodeAgentSettingsSection: View {
    @State private var configuration = ClaudeCodeAgentConfiguration()
    @State private var cliPathInput = ""
    @State private var statusMessage = "Not configured"
    @State private var statusTone = GargantuaColors.ink4
    @State private var availableModels: [AnthropicModel] = AnthropicModelCatalog.bakedInModels
    @State private var modelCatalogSource: AnthropicModelCatalogSource = .bakedIn
    @State private var isRefreshingModels = false

    private let store = ClaudeCodeAgentConfigurationStore()
    private let resolver = ClaudeCodeCLIResolver()
    private let modelCatalog = AnthropicModelCatalog()

    var body: some View {
        SettingsSectionContainer(
            "Claude Code Agent",
            subtitle: "Local Claude Code CLI for non-interactive maintenance runs. Tools are read-only by default."
        ) {
            statusHeader

            if configuration.isEnabled {
                Divider()
                    .overlay(GargantuaColors.border)

                cliPathRow
                if !statusMessage.isEmpty {
                    SettingsNoticeRow(
                        icon: statusNoticeIcon,
                        message: statusMessage,
                        tone: statusNoticeTone
                    )
                }

                toolGrantNotice
                modelPickerRow
                maxTurnsStepper
                scheduledAuditToggle
            } else {
                Text("Enable to set the CLI path, model, and run options.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
        }
        .task {
            configuration = store.load()
            cliPathInput = configuration.cliPath
            detectCLI()
            await loadModels(forceRefresh: false)
        }
    }

    private var modelPickerRow: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            HStack {
                Text("Model")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Spacer()

                Picker("Model", selection: Binding(
                    get: { configuration.selectedModel },
                    set: {
                        configuration.selectedModel = $0
                        saveConfiguration()
                    }
                )) {
                    ForEach(modelOptions) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)

                GargantuaIconButton(
                    icon: isRefreshingModels ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
                    help: "Refresh from Anthropic /v1/models",
                    color: GargantuaColors.accent,
                    isDisabled: isRefreshingModels,
                    action: { Task { await loadModels(forceRefresh: true) } }
                )
            }

            Text(modelStatusLine)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Combine the live/cached/baked list with the currently selected model
    /// so a user-chosen identifier the API doesn't return (custom alias,
    /// retired ID, model not yet rolled out to their account) doesn't vanish
    /// from the picker.
    private var modelOptions: [ModelOption] {
        var byID: [String: ModelOption] = [:]
        for model in availableModels {
            byID[model.id] = ModelOption(id: model.id, label: model.displayName ?? model.id)
        }
        let current = configuration.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty, byID[current] == nil {
            byID[current] = ModelOption(id: current, label: "\(current) (custom)")
        }
        return byID.values.sorted { $0.label < $1.label }
    }

    private var modelStatusLine: String {
        switch modelCatalogSource {
        case .live:
            "Showing the latest list from Anthropic /v1/models."
        case .cacheFresh(let writtenAt):
            "Cached \(relativeTime(writtenAt)) ago. Refresh to fetch the latest."
        case .cacheStale(let writtenAt):
            "Live fetch failed; showing cached list from \(relativeTime(writtenAt)) ago."
        case .bakedIn:
            "No API key configured. Showing built-in fallback list."
        }
    }

    private var toolGrantNotice: some View {
        SettingsNoticeRow(
            icon: "checkmark.shield",
            message: "Read-only by default. The agent can preview cleanups via the dry-run propose flow; nothing is deleted unless you confirm in the same review modal Deep Scan uses.",
            tone: .info
        )
    }

    private var statusNoticeIcon: String {
        switch statusNoticeTone {
        case .safe: return "checkmark.circle.fill"
        case .protected: return "xmark.octagon.fill"
        case .review: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    private var statusNoticeTone: SettingsNoticeRow.Tone {
        if statusTone == GargantuaColors.safe { return .safe }
        if statusTone == GargantuaColors.protected_ { return .protected }
        if statusTone == GargantuaColors.review { return .review }
        return .info
    }

    private func loadModels(forceRefresh: Bool) async {
        isRefreshingModels = true
        let result = await modelCatalog.loadModels(forceRefresh: forceRefresh)
        availableModels = result.models
        modelCatalogSource = result.source
        isRefreshingModels = false
    }

    private struct ModelOption: Identifiable, Equatable {
        let id: String
        let label: String
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
            .replacingOccurrences(of: "in ", with: "")
            .replacingOccurrences(of: " ago", with: "")
    }

    private var statusHeader: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(
                systemName: configuration.isEnabled ? "terminal.fill" : "terminal",
                color: configuration.isEnabled ? GargantuaColors.safe : GargantuaColors.ink4,
                size: 18
            )

            SettingsRowText(
                title: "Claude Code runner",
                detail: "Non-interactive runs flow through Gargantua MCP with read-only tools by default."
            )

            Spacer()

            Toggle("Enable Claude Code agent", isOn: Binding(
                get: { configuration.isEnabled },
                set: {
                    configuration.isEnabled = $0
                    saveConfiguration()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .help(configuration.isEnabled ? "Disable Claude Code agent" : "Enable Claude Code agent")
        }
    }

    private var cliPathRow: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: "point.3.connected.trianglepath.dotted", size: 14)

            TextField("Auto-detect from PATH", text: $cliPathInput)
                .textFieldStyle(.plain)
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink)
                .padding(.horizontal, GargantuaSpacing.space3)
                .padding(.vertical, GargantuaSpacing.space2)
                .background(GargantuaColors.surface3)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                .onSubmit(saveCLIPath)

            GargantuaButton(
                "Detect",
                icon: "location.magnifyingglass",
                tone: .ghost(GargantuaColors.accent),
                action: detectCLI
            )
            .help("Search PATH and standard install locations")

            GargantuaButton(
                "Save",
                icon: "checkmark.circle.fill",
                tone: .ghost(GargantuaColors.safe),
                action: saveCLIPath
            )
            .help("Save CLI path")
        }
    }

    private var maxTurnsStepper: some View {
        Stepper(
            value: Binding(
                get: { configuration.maxTurns },
                set: {
                    configuration.maxTurns = $0
                    saveConfiguration()
                }
            ),
            in: 1 ... 20,
            step: 1
        ) {
            HStack {
                Text("Max turns")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Spacer()

                Text("\(configuration.maxTurns)")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)
            }
        }
        .help("Maximum agent reasoning turns per session")
    }

    // The previous "Allow MCP Clean Tool" toggle was removed. With the
    // dry-run-propose flow, every interactive session gives the agent the
    // `clean` tool — its `dry_run: true` calls short-circuit server-side and
    // surface as the same review modal Deep Scan uses, with the actual
    // deletion run by the host's `CleanupEngine`. The `allowDestructiveMCPTools`
    // field on the persisted configuration is retained for back-compat with
    // older stored JSON but is no longer read by the runner.

    private var scheduledAuditToggle: some View {
        Toggle(isOn: Binding(
            get: { configuration.runAfterScheduledScans },
            set: {
                configuration.runAfterScheduledScans = $0
                saveConfiguration()
            }
        )) {
            SettingsRowText(
                title: "Run scheduled audits",
                detail: "Completed scheduled scans can start a read-only Claude Code maintenance report."
            )
        }
        .toggleStyle(.switch)
    }

    private func saveCLIPath() {
        configuration.cliPath = cliPathInput
        saveConfiguration()
        detectCLI()
    }

    private func saveConfiguration() {
        store.save(configuration)
    }

    private func detectCLI() {
        do {
            let detected = try resolver.resolve(configuration: configuration)
            if cliPathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cliPathInput = detected.path
                configuration.cliPath = detected.path
                saveConfiguration()
            }
            statusMessage = "Claude Code CLI ready at \(detected.path)"
            statusTone = GargantuaColors.safe
        } catch {
            statusMessage = error.localizedDescription
            statusTone = configuration.isEnabled ? GargantuaColors.protected_ : GargantuaColors.ink4
        }
    }
}
