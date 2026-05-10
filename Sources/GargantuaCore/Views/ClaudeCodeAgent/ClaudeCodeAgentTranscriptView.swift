import SwiftUI

struct ClaudeCodeAgentTranscriptView: View {
    @ObservedObject var controller: ClaudeCodeAgentSessionController
    @Binding var rawTranscriptExpanded: Bool
    let onRerunWithMoreTurns: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                Text("AGENT ACTIVITY")
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(GargantuaColors.ink2)

                Text("Parsed tool calls, assistant messages, and final result.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }

            parsedActivityCard
            maxTurnsRecoveryCard
            rawTranscriptDisclosure
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var parsedActivityCard: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
                    if controller.streamEvents.isEmpty {
                        transcriptEmptyState
                    } else {
                        ForEach(Array(controller.streamEvents.enumerated()), id: \.offset) { index, event in
                            ParsedActivityRow(event: event, isCurrent: isLatestActiveEvent(index))
                                .id(index)
                        }
                    }
                }
                .padding(GargantuaSpacing.space3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .background(GargantuaColors.surface1)
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                    .stroke(GargantuaColors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
            .onChange(of: controller.streamEvents.count) { _, count in
                guard count > 0 else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
    }

    /// Highlight the most recent in-flight event (latest tool_use that hasn't
    /// resolved into a tool_result yet) while the session is still running.
    /// On terminal events we drop the highlight so completed sessions don't
    /// look like they're still working.
    private func isLatestActiveEvent(_ index: Int) -> Bool {
        guard controller.status.isRunning,
              index == controller.streamEvents.count - 1 else { return false }
        switch controller.streamEvents[index] {
        case .toolUse, .assistantText, .sessionInit: return true
        default: return false
        }
    }

    @ViewBuilder
    private var maxTurnsRecoveryCard: some View {
        if let result = controller.terminalResult, result.kind == .maxTurns {
            MaxTurnsRecoveryCard(
                result: result,
                onRerun: onRerunWithMoreTurns
            )
        }
    }

    private var rawTranscriptDisclosure: some View {
        DisclosureGroup(isExpanded: $rawTranscriptExpanded) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                    ForEach(controller.events) { event in
                        TranscriptEventRow(event: event)
                            .id(event.id)
                    }
                }
                .padding(GargantuaSpacing.space2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .background(GargantuaColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        } label: {
            HStack(spacing: GargantuaSpacing.space2) {
                Text("Raw transcript")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
                Text("\(controller.events.count) lines")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink4)
            }
        }
        .disclosureGroupStyle(.automatic)
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(GargantuaColors.surface1)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .stroke(GargantuaColors.borderSoft, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }

    private var transcriptEmptyState: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            Image(systemName: "terminal")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(GargantuaColors.ink3)

            Text(controller.status.isRunning ? "Connecting to Claude Code…" : "Waiting for a run.")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink2)

            Text(controller.status.isRunning
                ? "The model is starting up. Tool calls and assistant messages will appear here as the run progresses."
                : "Compose a prompt on the left and press **Start run**. Tool calls, assistant messages, and the final result will appear here.")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(GargantuaSpacing.space5)
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

private struct ParsedActivityRow: View {
    let event: ClaudeCodeStreamEvent
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            iconColumn
            content
            Spacer(minLength: 0)
        }
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space3)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }

    @ViewBuilder
    private var iconColumn: some View {
        if isCurrent, case .toolUse = event {
            AccretionDiskView(activityRate: 30, size: 14)
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone)
                .frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch event {
        case .sessionInit(let model, let mcpServers):
            VStack(alignment: .leading, spacing: 2) {
                Text("Connected")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                Text(initSubtitle(model: model, mcpServers: mcpServers))
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
        case .assistantText(let text):
            Text(text)
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .toolUse(let name, let inputSummary, _):
            VStack(alignment: .leading, spacing: 2) {
                Text(toolDisplayName(name))
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                if !inputSummary.isEmpty {
                    Text(inputSummary)
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        case .toolResult(_, let isError, let summary, _):
            VStack(alignment: .leading, spacing: 2) {
                Text(isError ? "Tool error" : "Tool result")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(isError ? GargantuaColors.review : GargantuaColors.ink2)
                if !summary.isEmpty {
                    Text(summary)
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        case .terminal(let result):
            terminalContent(result: result)
        case .unknown(let type):
            Text("Event: \(type)")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink4)
        }
    }

    @ViewBuilder
    private func terminalContent(result: ClaudeCodeStreamTerminalResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(terminalHeading(result.kind))
                .font(GargantuaFonts.label)
                .foregroundStyle(terminalTone(result.kind))
            if let text = result.resultText, !text.isEmpty {
                Text(text)
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if !result.errors.isEmpty {
                Text(result.errors.joined(separator: " · "))
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var icon: String {
        switch event {
        case .sessionInit: "bolt.horizontal.circle.fill"
        case .assistantText: "text.bubble.fill"
        case .toolUse: "wrench.and.screwdriver.fill"
        case .toolResult(_, let isError, _, _): isError ? "exclamationmark.triangle.fill" : "arrow.uturn.left.circle.fill"
        case .terminal(let result):
            switch result.kind {
            case .success: "checkmark.seal.fill"
            case .maxTurns: "hourglass.bottomhalf.filled"
            case .otherError: "exclamationmark.triangle.fill"
            }
        case .unknown: "questionmark.circle"
        }
    }

    private var tone: Color {
        switch event {
        case .sessionInit: GargantuaColors.accent
        case .assistantText: GargantuaColors.ink2
        case .toolUse: GargantuaColors.accent
        case .toolResult(_, let isError, _, _): isError ? GargantuaColors.review : GargantuaColors.safe
        case .terminal(let result):
            switch result.kind {
            case .success: GargantuaColors.safe
            case .maxTurns, .otherError: GargantuaColors.review
            }
        case .unknown: GargantuaColors.ink4
        }
    }

    private var rowBackground: Color {
        isCurrent ? GargantuaColors.surface2 : Color.clear
    }

    private func initSubtitle(model: String?, mcpServers: [String]) -> String {
        var parts: [String] = []
        if let model { parts.append(model) }
        if !mcpServers.isEmpty { parts.append("MCP: \(mcpServers.joined(separator: ", "))") }
        return parts.isEmpty ? "Run started" : parts.joined(separator: " · ")
    }

    /// Strip the `mcp__<server>__` prefix Claude Code adds to MCP tool names so
    /// `mcp__gargantua__scan` reads as just `scan` in the row.
    private func toolDisplayName(_ raw: String) -> String {
        let parts = raw.split(separator: "_").map(String.init)
        if raw.hasPrefix("mcp__"),
           let last = parts.last, !last.isEmpty {
            return "Tool: \(last)"
        }
        return "Tool: \(raw)"
    }

    private func terminalHeading(_ kind: ClaudeCodeStreamTerminalResult.Kind) -> String {
        switch kind {
        case .success: "Run complete"
        case .maxTurns: "Reached turn limit"
        case .otherError: "Run failed"
        }
    }

    private func terminalTone(_ kind: ClaudeCodeStreamTerminalResult.Kind) -> Color {
        switch kind {
        case .success: GargantuaColors.safe
        case .maxTurns, .otherError: GargantuaColors.review
        }
    }
}

private struct MaxTurnsRecoveryCard: View {
    let result: ClaudeCodeStreamTerminalResult
    let onRerun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
                Image(systemName: "hourglass.bottomhalf.filled")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(GargantuaColors.review)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                    Text("Hit the turn limit")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                    Text(recoveryMessage)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: GargantuaSpacing.space2) {
                Button(action: onRerun) {
                    Label("Re-run with +5 turns", systemImage: "arrow.clockwise")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(.white)
                        .padding(.horizontal, GargantuaSpacing.space3)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(GargantuaColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)

                if let cost = result.totalCostUsd, cost > 0 {
                    Text("This run cost \(String(format: "$%.2f", cost))")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }
        }
        .padding(GargantuaSpacing.space4)
        .background(GargantuaColors.surface1)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.review.opacity(0.6), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
    }

    private var recoveryMessage: String {
        "Claude used all \(result.numTurns ?? 0) allowed turns before finishing. " +
            "Re-running raises the budget by 5 turns and replays the same prompt."
    }
}
