import SwiftUI

extension ClaudeCodeAgentSettingsSection {
    var modelPickerRow: some View {
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
    var modelOptions: [ModelOption] {
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

    var modelStatusLine: String {
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

    func loadModels(forceRefresh: Bool) async {
        isRefreshingModels = true
        let result = await modelCatalog.loadModels(forceRefresh: forceRefresh)
        availableModels = result.models
        modelCatalogSource = result.source
        isRefreshingModels = false
    }

    func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
            .replacingOccurrences(of: "in ", with: "")
            .replacingOccurrences(of: " ago", with: "")
    }

    struct ModelOption: Identifiable, Equatable {
        let id: String
        let label: String
    }
}
