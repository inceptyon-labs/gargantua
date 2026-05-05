import SwiftUI

// MARK: - Health Score Range

/// Color range for the health score gauge.
public enum HealthScoreRange: Equatable {
    case healthy // 80-100
    case moderate // 50-79
    case poor // 0-49

    public init(score: Int) {
        let clamped = min(max(score, 0), 100)
        switch clamped {
        case 80 ... 100: self = .healthy
        case 50 ... 79: self = .moderate
        default: self = .poor
        }
    }

    public var color: Color {
        switch self {
        case .healthy: return GargantuaColors.safe
        case .moderate: return GargantuaColors.review
        case .poor: return GargantuaColors.protected_
        }
    }
}

// MARK: - Health Gauge View

/// Dual-ring gauge: outer arc shows disk usage, inner arc shows reclaim potential.
///
/// Both arcs span 270° with the gap at the bottom — the orbital signature
/// element from PRODUCT.md, driven by data the cleanup app actually moves.
public struct HealthGaugeView: View {
    /// Disk usage 0-1 (drives the outer ring; thresholded color).
    public let diskUsage: Double

    /// Reclaim potential 0-1 (drives the inner ring; appears only when > 0).
    public let reclaimableFraction: Double

    /// Diameter of the outer ring.
    public var size: CGFloat = 120

    /// Stroke width of each arc.
    public var lineWidth: CGFloat = 6

    public init(
        diskUsage: Double,
        reclaimableFraction: Double = 0,
        size: CGFloat = 120,
        lineWidth: CGFloat = 6
    ) {
        self.diskUsage = min(max(diskUsage, 0), 1)
        self.reclaimableFraction = min(max(reclaimableFraction, 0), 1)
        self.size = size
        self.lineWidth = lineWidth
    }

    private var diskColor: Color {
        if diskUsage > 0.9 { return GargantuaColors.protected_ }
        if diskUsage > 0.75 { return GargantuaColors.review }
        return GargantuaColors.safe
    }

    /// Arc spans 270° (¾ of a circle), gap at the bottom.
    private static let arcSpan: Double = 270
    private static let startAngle = Angle.degrees(135)

    /// Inner ring sits inside the outer with a small breathing gap.
    private var innerSize: CGFloat { size - lineWidth * 3 }

    public var body: some View {
        ZStack {
            arcShape(diameter: size, progress: 1.0)
                .stroke(GargantuaColors.surface3,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            arcShape(diameter: size, progress: diskUsage)
                .stroke(diskColor,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .animation(.linear(duration: 0.3), value: diskUsage)

            arcShape(diameter: innerSize, progress: 1.0)
                .stroke(GargantuaColors.borderSoft,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            if reclaimableFraction > 0 {
                arcShape(diameter: innerSize, progress: reclaimableFraction)
                    .stroke(GargantuaColors.accent,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .animation(.linear(duration: 0.3), value: reclaimableFraction)
            }

            VStack(spacing: 2) {
                Text("\(Int((diskUsage * 100).rounded()))%")
                    .font(GargantuaFonts.display)
                    .foregroundStyle(GargantuaColors.ink)
                    .contentTransition(.numericText())
                    .animation(.linear(duration: 0.3), value: diskUsage)

                Text("used")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)

                if reclaimableFraction > 0 {
                    Rectangle()
                        .fill(GargantuaColors.borderSoft)
                        .frame(width: 24, height: 1)
                        .padding(.vertical, 2)

                    Text("\(Int((reclaimableFraction * 100).rounded()))%")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(GargantuaColors.accent)
                        .contentTransition(.numericText())
                        .animation(.linear(duration: 0.3), value: reclaimableFraction)

                    Text("reclaim")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }
        }
        .frame(width: size, height: size)
    }

    private func arcShape(diameter: CGFloat, progress: Double) -> Path {
        Path { path in
            path.addArc(
                center: CGPoint(x: size / 2, y: size / 2),
                radius: (diameter - lineWidth) / 2,
                startAngle: Self.startAngle,
                endAngle: Angle.degrees(135 + Self.arcSpan * progress),
                clockwise: false
            )
        }
    }
}
