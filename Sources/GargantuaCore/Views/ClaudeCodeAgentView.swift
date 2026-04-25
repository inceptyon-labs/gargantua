import SwiftUI

public struct ClaudeCodeAgentView: View {
    @StateObject private var controller: ClaudeCodeAgentSessionController
    @State private var selectedTemplate: ClaudeCodeAgentPromptTemplate = .investigateSpace
    @State private var userContext = ""

    @MainActor
    public init(controller: ClaudeCodeAgentSessionController? = nil) {
        self._controller = StateObject(wrappedValue: controller ?? ClaudeCodeAgentSessionController())
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            HStack(alignment: .top, spacing: GargantuaSpacing.space5) {
                controlPanel
                    .frame(width: 340)

                VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
                    approvalGateSection
                    transcriptSection
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(GargantuaSpacing.space4)
        }
        .background(GargantuaColors.void_)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(GargantuaColors.accent)

                Text("Agent Sessions")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)
            }

            Text("Run Claude Code against Gargantua MCP with a live transcript and explicit destructive-step gates.")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space4)
    }

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                Text("PROMPT")
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(GargantuaColors.ink4)

                Picker("Prompt", selection: $selectedTemplate) {
                    ForEach(ClaudeCodeAgentPromptTemplate.allCases) { template in
                        Label(template.title, systemImage: template.icon)
                            .tag(template)
                    }
                }
                .pickerStyle(.segmented)

                TextEditor(text: $userContext)
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink)
                    .scrollContentBackground(.hidden)
                    .padding(GargantuaSpacing.space2)
                    .frame(minHeight: 140)
                    .background(GargantuaColors.surface3)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                    .overlay(alignment: .topLeading) {
                        if userContext.isEmpty {
                            Text(selectedTemplate.placeholder)
                                .font(GargantuaFonts.body)
                                .foregroundStyle(GargantuaColors.ink4)
                                .padding(GargantuaSpacing.space3)
                                .allowsHitTesting(false)
                        }
                    }
            }

            HStack(spacing: GargantuaSpacing.space3) {
                Button(action: startSession) {
                    Label("Start", systemImage: "play.fill")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(.white)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(controller.status.isRunning ? GargantuaColors.ink4 : GargantuaColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
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
                .opacity(controller.status.isRunning ? 1 : 0.5)
            }

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

    private var statusCard: some View {
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
                    .foregroundStyle(GargantuaColors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(GargantuaSpacing.space3)
        .background(GargantuaColors.surface2)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }

    @ViewBuilder
    private var approvalGateSection: some View {
        let gates = controller.approvalGates
        if !gates.isEmpty {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                Text("PENDING GATES")
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(GargantuaColors.ink4)

                ForEach(gates) { gate in
                    ApprovalGateRow(
                        gate: gate,
                        onApprove: { controller.approve(gate) },
                        onDeny: { controller.deny(gate) }
                    )
                }
            }
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            Text("TRANSCRIPT")
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(GargantuaColors.ink4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
                        if controller.events.isEmpty {
                            Text("No session transcript yet.")
                                .font(GargantuaFonts.body)
                                .foregroundStyle(GargantuaColors.ink4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(GargantuaSpacing.space4)
                        } else {
                            ForEach(controller.events) { event in
                                TranscriptEventRow(event: event)
                                    .id(event.id)
                            }
                        }
                    }
                    .padding(GargantuaSpacing.space3)
                }
                .background(GargantuaColors.surface1)
                .overlay(
                    RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                        .stroke(GargantuaColors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
                .onChange(of: controller.events.last?.id) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private func startSession() {
        controller.start(template: selectedTemplate, userContext: userContext)
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
        case .idle: GargantuaColors.ink4
        case .running: GargantuaColors.accent
        case .completed: GargantuaColors.safe
        case .failed, .cancelled: GargantuaColors.review
        }
    }

    private var statusDetail: String {
        switch controller.status {
        case .idle:
            "Choose a prompt preset and start a session."
        case .running:
            "Claude Code is connected to the generated Gargantua MCP config."
        case .completed:
            "Session finished. Review the transcript and audit log."
        case .failed(let message):
            message
        case .cancelled:
            "The active Claude Code process was terminated."
        }
    }
}

private struct ApprovalGateRow: View {
    let gate: ClaudeCodeAgentApprovalGate
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tone)
                    .frame(width: 20, alignment: .center)

                VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                    Text(gate.summary)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)

                    Text(gate.rawTranscript)
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(3)
                }

                Spacer()
            }

            HStack(spacing: GargantuaSpacing.space2) {
                Button(action: onApprove) {
                    Label("Approve", systemImage: "checkmark.circle.fill")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.safe)
                        .padding(.horizontal, GargantuaSpacing.space3)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(GargantuaColors.safe.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
                .disabled(gate.status != .pending)

                Button(action: onDeny) {
                    Label("Deny", systemImage: "xmark.circle.fill")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.protected_)
                        .padding(.horizontal, GargantuaSpacing.space3)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(GargantuaColors.protected_.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
                .disabled(gate.status != .pending)

                Text(gate.status.rawValue.capitalized)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
        }
        .padding(GargantuaSpacing.space4)
        .background(GargantuaColors.surface1)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(tone.opacity(0.65), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
    }

    private var icon: String {
        switch gate.status {
        case .pending: "hand.raised.fill"
        case .approved: "checkmark.shield.fill"
        case .denied: "xmark.shield.fill"
        }
    }

    private var tone: Color {
        switch gate.status {
        case .pending: GargantuaColors.review
        case .approved: GargantuaColors.safe
        case .denied: GargantuaColors.protected_
        }
    }
}

private struct TranscriptEventRow: View {
    let event: ClaudeCodeAgentTranscriptEvent

    var body: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            Text(event.stream.rawValue.uppercased())
                .font(GargantuaFonts.monoData)
                .foregroundStyle(tone)
                .frame(width: 58, alignment: .leading)

            Text(event.message.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(event.stream == .system ? GargantuaFonts.body : GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, GargantuaSpacing.space1)
    }

    private var tone: Color {
        switch event.stream {
        case .system: GargantuaColors.accent
        case .stdout: GargantuaColors.ink3
        case .stderr: GargantuaColors.review
        case .audit: GargantuaColors.safe
        }
    }
}
