import SwiftUI

extension CodexAgentSettingsSection {
    var modelPickerRow: some View {
        HStack {
            Text("Model")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink)

            Spacer()

            Picker("Model", selection: Binding(
                get: { configuration.selectedModel },
                set: { newValue in
                    configuration.selectedModel = newValue
                    saveConfiguration()
                }
            )) {
                ForEach(modelOptions) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280)
        }
    }

    /// Combine the baked-in tier list with the currently selected model
    /// so a custom value the catalog doesn't know about still appears as
    /// the active option instead of silently switching back to default.
    var modelOptions: [ModelOption] {
        var options: [ModelOption] = [
            ModelOption(id: "", label: "Default (let codex pick)"),
        ]
        var seen: Set<String> = [""]
        for model in CodexModelCatalog.bakedInModels {
            guard seen.insert(model.id).inserted else { continue }
            options.append(ModelOption(id: model.id, label: model.displayName))
        }
        let current = configuration.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty, !seen.contains(current) {
            options.append(ModelOption(id: current, label: "\(current) (custom)"))
        }
        return options
    }

    struct ModelOption: Identifiable, Equatable {
        let id: String
        let label: String
    }
}
