import SwiftUI

struct DashboardTier3AgentStatus: Sendable, Equatable {
    let configuration: ClaudeCodeAgentConfiguration
    let cliAvailable: Bool
    let resolvedCLIPath: String?

    var isReady: Bool {
        configuration.isEnabled && cliAvailable
    }
}

enum DashboardTier3AgentStatusProvider {
    static func snapshot(
        configurationStore: ClaudeCodeAgentConfigurationStore = ClaudeCodeAgentConfigurationStore(),
        cliResolver: ClaudeCodeCLIResolver = ClaudeCodeCLIResolver()
    ) -> DashboardTier3AgentStatus {
        let configuration = configurationStore.load()
        let resolvedCLI = try? cliResolver.resolve(configuration: configuration)
        return DashboardTier3AgentStatus(
            configuration: configuration,
            cliAvailable: resolvedCLI != nil,
            resolvedCLIPath: resolvedCLI?.path
        )
    }
}

struct DashboardTier3AgentStatusPresentation: Equatable {
    enum Tone: Equatable {
        case safe
        case review
        case muted

        var color: Color {
            switch self {
            case .safe: return GargantuaColors.safe
            case .review: return GargantuaColors.review
            case .muted: return GargantuaColors.ink4
            }
        }
    }

    let title: String
    let detail: String
    let modelSummary: String
    let modeSummary: String
    let actionLabel: String
    let actionSystemImage: String
    let tone: Tone
    let opensSettings: Bool

    static func make(from status: DashboardTier3AgentStatus?) -> DashboardTier3AgentStatusPresentation {
        guard let status else {
            return DashboardTier3AgentStatusPresentation(
                title: "Checking",
                detail: "Tier 3 agent status loading.",
                modelSummary: "Claude Code",
                modeSummary: "checking",
                actionLabel: "Settings",
                actionSystemImage: "gearshape",
                tone: .muted,
                opensSettings: true
            )
        }

        guard status.configuration.isEnabled else {
            return DashboardTier3AgentStatusPresentation(
                title: "Off",
                detail: "Claude Code Agent is disabled.",
                modelSummary: "Claude Code",
                modeSummary: "disabled",
                actionLabel: "Settings",
                actionSystemImage: "gearshape",
                tone: .muted,
                opensSettings: true
            )
        }

        guard status.cliAvailable else {
            return DashboardTier3AgentStatusPresentation(
                title: "Needs CLI",
                detail: "Enabled, but the claude executable is not available.",
                modelSummary: modelSummary(for: status.configuration),
                modeSummary: "CLI missing",
                actionLabel: "Settings",
                actionSystemImage: "gearshape",
                tone: .review,
                opensSettings: true
            )
        }

        return DashboardTier3AgentStatusPresentation(
            title: "Ready",
            detail: "Agent runs through Gargantua MCP with user approval gates.",
            modelSummary: modelSummary(for: status.configuration),
            modeSummary: status.configuration.allowDestructiveMCPTools ? "clean proposals" : "read-only tools",
            actionLabel: "Open Agent",
            actionSystemImage: "brain.head.profile",
            tone: .safe,
            opensSettings: false
        )
    }

    private static func modelSummary(for configuration: ClaudeCodeAgentConfiguration) -> String {
        let model = configuration.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? "CLI default" : model
    }
}

struct DashboardTier3AgentStatusCard: View {
    let status: DashboardTier3AgentStatus?
    let onOpenAgent: () -> Void
    let onOpenSettings: () -> Void

    private var presentation: DashboardTier3AgentStatusPresentation {
        DashboardTier3AgentStatusPresentation.make(from: status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            HStack(alignment: .center, spacing: GargantuaSpacing.space2) {
                Text("TIER 3 AGENT")
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(GargantuaColors.ink4)

                Circle()
                    .fill(presentation.tone.color)
                    .frame(width: 7, height: 7)
            }

            Text(presentation.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(GargantuaColors.ink)
                .lineLimit(1)

            Text(presentation.detail)
                .font(GargantuaFonts.caption)
                .foregroundStyle(presentation.tone == .review ? GargantuaColors.review : GargantuaColors.ink3)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: GargantuaSpacing.space2) {
                MCPStatusMeta(text: presentation.modelSummary, systemImage: "cpu")
                MCPStatusMeta(text: presentation.modeSummary, systemImage: "lock.shield")
            }

            Spacer(minLength: 0)

            Button(action: requestAction) {
                Label(presentation.actionLabel, systemImage: presentation.actionSystemImage)
                    .font(GargantuaFonts.caption)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(presentation.opensSettings ? GargantuaColors.ink : GargantuaColors.accent)
                    .padding(.horizontal, GargantuaSpacing.space3)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(presentation.opensSettings ? GargantuaColors.surface3 : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                    .overlay(
                        RoundedRectangle(cornerRadius: GargantuaRadius.small)
                            .stroke(presentation.opensSettings ? GargantuaColors.borderEm : Color.clear, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help(presentation.opensSettings ? "Open Tier 3 settings" : "Open Agent Run")
        }
        .padding(GargantuaSpacing.space4)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(GargantuaColors.surface1)
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(presentation.tone.color)
                .frame(width: 28, height: 2)
                .padding(.horizontal, GargantuaSpacing.space4)
        }
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
    }

    private func requestAction() {
        if presentation.opensSettings {
            onOpenSettings()
        } else {
            onOpenAgent()
        }
    }
}
