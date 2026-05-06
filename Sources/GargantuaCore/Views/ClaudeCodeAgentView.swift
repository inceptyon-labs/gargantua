import SwiftUI

public struct ClaudeCodeAgentView: View {
    @StateObject private var controller: ClaudeCodeAgentSessionController
    @State private var selectedTemplate: ClaudeCodeAgentPromptTemplate = .investigateSpace
    @State private var userContext = ""
    @State private var rawTranscriptExpanded = false
    @State private var runDetailsExpanded = false
    @State private var didCopyPrompt = false
    @State private var helpSheetPresented = false
    private let configurationStore: ClaudeCodeAgentConfigurationStore

    @MainActor
    public init(
        controller: ClaudeCodeAgentSessionController? = nil,
        configurationStore: ClaudeCodeAgentConfigurationStore = ClaudeCodeAgentConfigurationStore()
    ) {
        self._controller = StateObject(wrappedValue: controller ?? ClaudeCodeAgentSessionController())
        self.configurationStore = configurationStore
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space5) {
                promptSection
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
                    ClaudeCodeAgentApprovalGateSection(
                        gates: controller.approvalGates,
                        onApprove: { gate in controller.approve(gate) },
                        onDeny: { gate in controller.deny(gate) }
                    )

                    ClaudeCodeAgentTranscriptView(
                        controller: controller,
                        rawTranscriptExpanded: $rawTranscriptExpanded,
                        onRerunWithMoreTurns: rerunWithMoreTurns
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(GargantuaSpacing.space5)
        }
        .background(GargantuaColors.void_)
        .sheet(isPresented: $helpSheetPresented) {
            ClaudeCodeAgentHelpView()
        }
        .overlay(alignment: .center) {
            ClaudeCodeAgentPendingApprovalOverlay(
                pending: controller.pendingApproval,
                lastAssistantText: controller.lastAssistantText,
                onAcknowledgeUnresolved: {
                    Task { await controller.confirmPendingApproval() }
                },
                onConfirm: { method in
                    Task { await controller.confirmPendingApproval(method: method) }
                },
                onCancel: { controller.cancelPendingApproval() }
            )
        }
        .overlay(alignment: .center) {
            if controller.isCleaning {
                CleanupProgressOverlay(
                    progress: controller.cleaningProgress,
                    total: controller.cleaningTotal
                )
                .transition(.opacity)
            }
        }
    }

    private var header: some View {
        PageHeaderView(
            title: "Agent Run",
            subtitle: "Hand control to Claude Code. Confirm each destructive turn.",
            subtitleStyle: .voice
        ) {
            HStack(spacing: GargantuaSpacing.space3) {
                Button {
                    helpSheetPresented = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(GargantuaColors.ink3)
                }
                .buttonStyle(.plain)
                .help("When to use Agent Run vs Deep Scan, with example prompts")
                .accessibilityLabel("When to use Agent Run")

                if let result = controller.terminalResult {
                    SessionMetricsChip(result: result)
                }
            }
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            Text("PROMPT")
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(GargantuaColors.ink2)

            ClaudeCodeAgentPromptPanel(
                controller: controller,
                selectedTemplate: $selectedTemplate,
                userContext: $userContext,
                runDetailsExpanded: $runDetailsExpanded,
                didCopyPrompt: $didCopyPrompt,
                configurationStore: configurationStore,
                onStart: startSession
            )
        }
    }

    private func startSession() {
        controller.start(template: selectedTemplate, userContext: userContext)
    }

    /// Bump the persisted maxTurns ceiling (capped at 20 by the configuration
    /// initializer) and re-fire the last prompt. We add 5 each click; users
    /// who bump out of the cap need to raise the ceiling in Settings.
    private func rerunWithMoreTurns() {
        var configuration = configurationStore.load()
        configuration.maxTurns += 5
        configurationStore.save(configuration)
        controller.restart()
    }
}
