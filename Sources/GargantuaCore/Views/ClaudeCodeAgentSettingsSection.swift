import SwiftUI

struct ClaudeCodeAgentSettingsSection: View {
    @State private var configuration = ClaudeCodeAgentConfiguration()
    @State private var cliPathInput = ""
    @State private var statusMessage = "Not configured"
    @State private var statusTone = GargantuaColors.ink4

    private let store = ClaudeCodeAgentConfigurationStore()
    private let resolver = ClaudeCodeCLIResolver()

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

                maxTurnsStepper
                scheduledAuditToggle
                destructiveToggle
            }
            .padding(GargantuaSpacing.space4)
            .background(GargantuaColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
        .task {
            configuration = store.load()
            cliPathInput = configuration.cliPath
            detectCLI()
        }
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

                Text("Non-interactive sessions run through Gargantua MCP with read-only tools by default.")
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

    private var destructiveToggle: some View {
        Toggle(isOn: Binding(
            get: { configuration.allowDestructiveMCPTools },
            set: {
                configuration.allowDestructiveMCPTools = $0
                saveConfiguration()
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow MCP Clean Tool")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Text("Off keeps agent sessions read-only; detected clean attempts still appear as approval gates.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
        }
        .toggleStyle(.switch)
    }

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
