import SwiftUI

struct SessionMetricsChip: View {
    let result: ClaudeCodeStreamTerminalResult

    var body: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            if let turns = result.numTurns {
                metric(label: "turns", value: "\(turns)")
            }
            if let durationMs = result.durationMs {
                metric(label: "time", value: formatDuration(ms: durationMs))
            }
            if let cost = result.totalCostUsd {
                metric(label: "cost", value: formatCost(cost))
            }
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, 4)
        .background(GargantuaColors.surface2)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }

    private func metric(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
            Text(value)
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink)
        }
    }

    private func formatDuration(ms: Int) -> String {
        let seconds = Double(ms) / 1000.0
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds / 60)
        let remaining = Int(seconds.truncatingRemainder(dividingBy: 60))
        return "\(minutes)m \(remaining)s"
    }

    private func formatCost(_ cost: Double) -> String {
        // Sub-cent runs round to "<$0.01" so users don't see ambiguous "$0.00".
        if cost < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", cost)
    }
}
