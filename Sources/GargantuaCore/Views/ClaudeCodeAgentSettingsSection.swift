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
        VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            Text("Claude Code Agent")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink2)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                statusHeader

                Divider()
                    .overlay(GargantuaColors.border)

                cliPathRow
                Text(statusMessage)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(statusTone)

                modelPickerRow
                maxTurnsStepper
                scheduledAuditToggle
            }
            .padding(GargantuaSpacing.space4)
            .background(GargantuaColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
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

                Button(action: { Task { await loadModels(forceRefresh: true) } }) {
                    Image(systemName: isRefreshingModels ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(GargantuaColors.accent)
                        .padding(.horizontal, GargantuaSpacing.space2)
                        .padding(.vertical, GargantuaSpacing.space1)
                        .background(GargantuaColors.accent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
                .disabled(isRefreshingModels)
                .help("Refresh from Anthropic /v1/models")
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
            "No API key configured — showing built-in fallback list."
        }
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
            Image(systemName: configuration.isEnabled ? "terminal.fill" : "terminal")
                .font(.system(size: 18))
                .foregroundStyle(configuration.isEnabled ? GargantuaColors.safe : GargantuaColors.ink4)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text("Tier 3 Claude Code")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Text("Non-interactive runs go through Gargantua MCP with read-only tools by default.")
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

    private var cliPathRow: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 14))
                .foregroundStyle(GargantuaColors.ink3)
                .frame(width: 20, alignment: .center)

            TextField("Auto-detect from PATH", text: $cliPathInput)
                .textFieldStyle(.plain)
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink)
                .padding(.horizontal, GargantuaSpacing.space3)
                .padding(.vertical, GargantuaSpacing.space2)
                .background(GargantuaColors.surface3)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                .onSubmit(saveCLIPath)

            agentSettingsButton(
                label: "Detect",
                icon: "location.magnifyingglass",
                color: GargantuaColors.accent,
                action: detectCLI
            )

            agentSettingsButton(
                label: "Save",
                icon: "checkmark.circle.fill",
                color: GargantuaColors.safe,
                action: saveCLIPath
            )
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
                Text("Max Turns")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Spacer()

                Text("\(configuration.maxTurns)")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)
            }
        }
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
            VStack(alignment: .leading, spacing: 2) {
                Text("Run Scheduled AI Audits")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Text("Completed scheduled scans can start a read-only Claude Code maintenance report.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
        }
        .toggleStyle(.switch)
    }

    private func agentSettingsButton(
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
            statusTone = configuration.isEnabled ? GargantuaColors.review : GargantuaColors.ink4
        }
    }
}
