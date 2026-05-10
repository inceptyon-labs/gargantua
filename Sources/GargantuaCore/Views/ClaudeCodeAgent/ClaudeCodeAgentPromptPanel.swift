import SwiftUI

struct ClaudeCodeAgentPromptPanel: View {
    @ObservedObject var controller: ClaudeCodeAgentSessionController
    @Binding var selectedTemplate: ClaudeCodeAgentPromptTemplate
    @Binding var userContext: String
    @Binding var runDetailsExpanded: Bool
    @Binding var didCopyPrompt: Bool
    let configurationStore: ClaudeCodeAgentConfigurationStore
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            disclaimerCard

            ClaudeCodeAgentPresetPicker(
                selectedTemplate: $selectedTemplate,
                userContext: $userContext
            )

            promptInput
            ClaudeCodeAgentRunDetailsDisclosure(
                isExpanded: $runDetailsExpanded,
                didCopyPrompt: $didCopyPrompt,
                selectedTemplate: selectedTemplate,
                userContext: userContext,
                configurationStore: configurationStore,
                sessionsRootPath: controller.sessionsRoot.path
            )
            actionRow
            statusCard
        }
        .padding(GargantuaSpacing.space4)
        .background(GargantuaColors.surface1)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
    }

    private var promptInput: some View {
        TextField(
            selectedTemplate.placeholder,
            text: $userContext,
            axis: .vertical
        )
        .font(GargantuaFonts.body)
        .foregroundStyle(GargantuaColors.ink)
        .textFieldStyle(.plain)
        .lineLimit(3 ... 12)
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space3)
        .background(GargantuaColors.surface3)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .stroke(GargantuaColors.borderSoft, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }

    /// Compact one-line disclaimer above the preset picker. Combines both
    /// clauses from `ClaudeCodeAgentHelpContent` (lead-in and Deep-Scan
    /// fallback) so the full framing stays present without consuming the
    /// ~80pt the previous two-paragraph card took. Detail copy lives in the
    /// `?` help sheet, which is one click away in the header.
    private var disclaimerCard: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(GargantuaColors.ink3)
                .padding(.top, 1)

            (
                Text(ClaudeCodeAgentHelpContent.disclaimerLeadIn).bold()
                    + Text(" — ")
                    + Text(ClaudeCodeAgentHelpContent.disclaimerFallback).foregroundColor(GargantuaColors.ink3)
                    + Text(".")
            )
            .font(GargantuaFonts.caption)
            .foregroundStyle(GargantuaColors.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GargantuaColors.surface2)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .stroke(GargantuaColors.borderSoft, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }

    @ViewBuilder
    private var statusCard: some View {
        if !controller.status.isIdle {
            HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
                Image(systemName: statusIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(statusTone)
                    .frame(width: 20, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.status.label)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)

                    Text(statusDetail)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(GargantuaSpacing.space3)
            .background(GargantuaColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        }
    }

    private var actionRow: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Button(action: onStart) {
                Label("Start run", systemImage: "play.fill")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(.white)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(controller.status.isRunning ? GargantuaColors.ink4 : GargantuaColors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(controller.status.isRunning)

            Button(action: controller.cancel) {
                Label("Cancel", systemImage: "stop.fill")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.protected_)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(GargantuaColors.protected_.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
            .disabled(!controller.status.isRunning)
            .opacity(controller.status.isRunning ? 1 : 0.65)

            Spacer()

            Text("⌘↩")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
        }
    }

    private var statusIcon: String {
        switch controller.status {
        case .idle: "circle"
        case .running: "play.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    private var statusTone: Color {
        switch controller.status {
        case .idle: GargantuaColors.ink2
        case .running: GargantuaColors.accent
        case .completed: GargantuaColors.safe
        case .failed, .cancelled: GargantuaColors.review
        }
    }

    private var statusDetail: String {
        switch controller.status {
        case .idle:
            "Choose a prompt preset and start a run."
        case .running:
            "Claude Code is connected to the generated Gargantua MCP config."
        case .completed:
            "Run finished. Review the transcript and audit log."
        case .failed(let message):
            message
        case .cancelled:
            "The active Claude Code process was terminated."
        }
    }
}
