import SwiftUI

// MARK: - Confidence Orbit

/// A circular progress indicator showing scan confidence as a thin arc.
///
/// The confidence orbit is the signature design element, inspired by Gargantua's
/// orbital rings. It displays as a thin circular arc from 0° to (confidence * 3.6)°,
/// scaled to fit a 24x24 size. The color matches the item's safety level.
struct ConfidenceOrbit: View {
    let confidence: Int
    let safety: SafetyLevel

    private let size: CGFloat = 24
    private let lineWidth: CGFloat = 1.5

    public var body: some View {
        ZStack(alignment: .center) {
            // Subtle background circle (very faint)
            Circle()
                .stroke(safetyColor.opacity(0.2), lineWidth: lineWidth)

            // Confidence arc — rotated so 0% starts at top and sweeps clockwise
            Circle()
                .trim(from: 0, to: Double(confidence) / 100)
                .stroke(safetyColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
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

            // Explain button (revealed on hover)
            if isHovered, onExplain != nil {
                Button(action: onExplain ?? {}) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(GargantuaColors.accent)
                }
                .buttonStyle(.plain)
                .help("Show explanation")
            } else if onExplain != nil {
                // Placeholder space to prevent layout shift
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.clear)
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
