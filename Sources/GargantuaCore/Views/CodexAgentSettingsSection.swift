import SwiftUI

/// Settings section that mirrors Claude Code Agent's UX for the Codex
/// CLI. Simpler than its sibling: Codex is invoked one-shot via
/// `codex exec`, so there's no MCP config, no allowed-tools matrix, no
/// max-turn budget. Just a toggle, CLI path, and optional model.
struct CodexAgentSettingsSection: View {
    @State var configuration = CodexAgentConfiguration()
    @State private var cliPathInput = ""
    @State private var statusMessage = "Not configured"
    @State private var statusTone = GargantuaColors.ink4

    let store = CodexAgentConfigurationStore()
    private let resolver = CodexCLIResolver()

    var body: some View {
        SettingsSectionContainer(
            "Codex Agent",
            subtitle: "OpenAI Codex CLI for one-shot prompts (used by the File Organizer's Codex backend)."
        ) {
            statusHeader

            if configuration.isEnabled {
                Divider().overlay(GargantuaColors.border)

                cliPathRow
                if !statusMessage.isEmpty {
                    SettingsNoticeRow(
                        icon: statusNoticeIcon,
                        message: statusMessage,
                        tone: statusNoticeTone
                    )
                }
                modelPickerRow
            } else {
                Text("Enable to set the CLI path and model.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
        }
        .task {
            configuration = store.load()
            cliPathInput = configuration.cliPath
            detectCLI()
        }
    }

    // MARK: - Status header

    private var statusHeader: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(
                systemName: configuration.isEnabled ? "terminal.fill" : "terminal",
                color: configuration.isEnabled ? GargantuaColors.safe : GargantuaColors.ink4,
                size: 18
            )

            SettingsRowText(
                title: "Codex runner",
                detail: "Sends a one-shot prompt via `codex exec`. Sandbox locked to read-only."
            )

            Spacer()

            Toggle("Enable Codex agent", isOn: Binding(
                get: { configuration.isEnabled },
                set: {
                    configuration.isEnabled = $0
                    saveConfiguration()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .help(configuration.isEnabled ? "Disable Codex agent" : "Enable Codex agent")
        }
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

    // MARK: - CLI path row

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
            .help("Search PATH for the codex executable")

            GargantuaButton(
                "Save",
                icon: "checkmark.circle.fill",
                tone: .ghost(GargantuaColors.safe),
                action: saveCLIPath
            )
            .help("Save CLI path")
        }
    }

    // MARK: - Actions

    private func saveCLIPath() {
        configuration.cliPath = cliPathInput
        saveConfiguration()
        detectCLI()
    }

    func saveConfiguration() {
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
            statusMessage = "Codex CLI ready at \(detected.path)"
            statusTone = GargantuaColors.safe
        } catch {
            statusMessage = error.localizedDescription
            statusTone = configuration.isEnabled ? GargantuaColors.protected_ : GargantuaColors.ink4
        }
    }
}
