import SwiftUI

// MARK: - Confidence Orbit

/// Confidence indicator drawn as ascending signal-strength bars (like a
/// cell-signal icon). Five vertical bars step up in height left-to-right;
/// bars at or below the confidence bucket light up in the safety color,
/// the rest stay faint. Buckets: 0–19→1, 20–39→2, 40–59→3, 60–79→4, 80+→5.
struct ConfidenceOrbit: View {
    let confidence: Int
    let safety: SafetyLevel

    private let barCount = 5
    private let barWidth: CGFloat = 3
    private let barGap: CGFloat = 1.5
    private let frameHeight: CGFloat = 24
    private let minBarHeight: CGFloat = 6
    private let maxBarHeight: CGFloat = 20

    public var body: some View {
        HStack(alignment: .bottom, spacing: barGap) {
            ForEach(0 ..< barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < litBarCount ? safetyColor : safetyColor.opacity(0.18))
                    .frame(width: barWidth, height: barHeight(at: index))
            }
        }
        .frame(height: frameHeight, alignment: .bottom)
        .accessibilityLabel("Confidence \(confidence) percent")
    }

    private var litBarCount: Int {
        let clamped = max(0, min(100, confidence))
        return min(barCount, max(1, clamped / 20 + 1))
    }

    private func barHeight(at index: Int) -> CGFloat {
        guard barCount > 1 else { return maxBarHeight }
        let step = (maxBarHeight - minBarHeight) / CGFloat(barCount - 1)
        return minBarHeight + step * CGFloat(index)
    }

    private var safetyColor: Color {
        switch safety {
        case .safe: GargantuaColors.safe
        case .review: GargantuaColors.review
        case .protected_: GargantuaColors.protected_
        }
    }
}

// MARK: - Dense Scan Item Row

/// A compact row displaying all critical scan result data: confidence orbit, checkbox,
/// name, explanation, file path, and size. Optimized for density with hover interactions.
///
/// Layout (left to right):
/// - Confidence orbit (24x24)
/// - Checkbox (16x16)
/// - Content block:
///   - Name (13px, 500 weight) on first line
///   - Explanation (13px, 400 weight) below or on same line (if space permits)
///   - File path (11px mono, truncated with ellipsis) below name
/// - Size (12px mono, right-aligned, tabular numbers)
/// - Hover: "?" explain button (conditionally shown)
///
/// Background is tinted by safety level. Select/deselect on click anywhere.
public struct DenseScanItemRow: View {
    let item: ScanResult
    let isSelected: Bool
    let isFocused: Bool
    let onToggleSelection: () -> Void
    let onExplain: (() -> Void)?

    @State private var isHovered = false
    @Environment(\.activeAIEngineKind) private var activeAIEngineKind

    public var body: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            // Confidence orbit
            ConfidenceOrbit(confidence: item.confidence, safety: item.safety)

            // Checkbox
            Button(action: onToggleSelection) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(
                            isSelected ? safetyColor : GargantuaColors.borderEm,
                            lineWidth: 1.5
                        )
                        .frame(width: 16, height: 16)
                        .background(
                            isSelected ? safetyColor : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)

            // Content block: name + explanation on first line if room, else stacked
            VStack(alignment: .leading, spacing: 2) {
                // Name + explanation on same line if space permits
                HStack(spacing: GargantuaSpacing.space1) {
                    Text(item.name)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                        .lineLimit(1)

                    if !item.explanation.isEmpty {
                        Text(item.explanation)
                            .font(GargantuaFonts.body)
                            .foregroundStyle(GargantuaColors.ink2)
                            .lineLimit(1)
                    }
                }

                // File path below
                Text(item.path)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Size (monospace, right-aligned, tabular)
            Text(AlertItem.formatBytes(item.size))
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink)
                .lineLimit(1)

            // Explain button (revealed on hover). Glyph mirrors the active
            // engine: sparkles when MLX is on (real generated output), the
            // plain question mark when the rule-based template is in play.
            if isHovered, onExplain != nil {
                Button(action: onExplain ?? {}) {
                    Image(systemName: explainGlyph)
                        .font(.system(size: 14))
                        .foregroundStyle(GargantuaColors.accent)
                }
                .buttonStyle(.plain)
                .help(explainHelpText)
                .accessibilityLabel(explainHelpText)
            } else if onExplain != nil {
                // Placeholder space to prevent layout shift; hidden from a11y.
                Image(systemName: explainGlyph)
                    .font(.system(size: 14))
                    .foregroundStyle(.clear)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space3)
        .background(safetyDimColor)
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .stroke(GargantuaColors.borderFocus, lineWidth: 2)
                .padding(1)
                .opacity(isFocused ? 1 : 0)
        )
        .onTapGesture(perform: onToggleSelection)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var safetyColor: Color {
        switch item.safety {
        case .safe: GargantuaColors.safe
        case .review: GargantuaColors.review
        case .protected_: GargantuaColors.protected_
        }
    }

    private var explainGlyph: String {
        switch activeAIEngineKind {
        case .mlx: return "sparkles"
        case .template: return "questionmark.circle.fill"
        }
    }

    private var explainHelpText: String {
        switch activeAIEngineKind {
        case .mlx: return "Show AI explanation"
        case .template: return "Show rule-based explanation"
        }
    }

    private var safetyDimColor: Color {
        switch item.safety {
        case .safe: GargantuaColors.safe.opacity(0.12)
        case .review: GargantuaColors.review.opacity(0.12)
        case .protected_: GargantuaColors.protected_.opacity(0.12)
        }
    }
}

// MARK: - Preview

#if DEBUG
    #Preview {
        VStack(spacing: 0) {
            DenseScanItemRow(
                item: ScanResult(
                    id: "cache_001",
                    name: "Chrome Browser Cache",
                    path: "/Users/jason/Library/Caches/Google/Chrome/Default/Cache/Data_001",
                    size: 2_147_483_648,
                    safety: .safe,
                    confidence: 98,
                    explanation: "Browser cache files. Regenerated automatically.",
                    source: SourceAttribution(name: "Google Chrome", bundleID: "com.google.Chrome"),
                    category: "browser_cache"
                ),
                isSelected: false,
                isFocused: false,
                onToggleSelection: {},
                onExplain: {}
            )

            Rectangle()
                .fill(GargantuaColors.borderSoft)
                .frame(height: 1)

            DenseScanItemRow(
                item: ScanResult(
                    id: "node_001",
                    name: "node_modules (Project A)",
                    path: "/Users/jason/Development/project-a/node_modules",
                    size: 1_048_576_000,
                    safety: .review,
                    confidence: 87,
                    explanation: "Node.js dependencies. Can be reinstalled.",
                    source: SourceAttribution(name: "npm", bundleID: nil),
                    category: "dev_artifacts"
                ),
                isSelected: true,
                isFocused: true,
                onToggleSelection: {},
                onExplain: {}
            )

            Rectangle()
                .fill(GargantuaColors.borderSoft)
                .frame(height: 1)

            DenseScanItemRow(
                item: ScanResult(
                    id: "protected_001",
                    name: "Xcode Derived Data",
                    path: "/Users/jason/Library/Developer/Xcode/DerivedData",
                    size: 5_368_709_120,
                    safety: .protected_,
                    confidence: 72,
                    explanation: "Build cache. Deletion may require full rebuild.",
                    source: SourceAttribution(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
                    category: "dev_cache"
                ),
                isSelected: false,
                isFocused: false,
                onToggleSelection: {},
                onExplain: {}
            )
        }
        .background(GargantuaColors.void_)
        .padding(GargantuaSpacing.space4)
    }
#endif
