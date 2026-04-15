import SwiftUI

// MARK: - Health Score Range

/// Color range for the health score gauge.
public enum HealthScoreRange: Equatable {
    case healthy  // 80-100
    case moderate // 50-79
    case poor     // 0-49

    public init(score: Int) {
        let clamped = min(max(score, 0), 100)
        switch clamped {
        case 80...100: self = .healthy
        case 50...79:  self = .moderate
        default:       self = .poor
        }
    }

    public var color: Color {
        switch self {
        case .healthy:  return GargantuaColors.safe
        case .moderate: return GargantuaColors.review
        case .poor:     return GargantuaColors.protected_
        }
    }
}

// MARK: - Health Gauge View

/// Circular arc gauge displaying a 0-100 health score.
///
/// The gauge renders as a 270° arc with the gap at the bottom,
/// consistent with the confidence orbit aesthetic. The score number
/// sits prominently in the center with a "Health" caption below.
public struct HealthGaugeView: View {
    /// Current health score (clamped to 0-100).
    public let score: Int

    /// Diameter of the gauge.
    public var size: CGFloat = 120

    /// Line width of the arc stroke.
    public var lineWidth: CGFloat = 8

    public init(score: Int, size: CGFloat = 120, lineWidth: CGFloat = 8) {
        self.score = min(max(score, 0), 100)
        self.size = size
        self.lineWidth = lineWidth
    }

    private var range: HealthScoreRange { HealthScoreRange(score: score) }
    private var progress: Double { Double(score) / 100.0 }

    /// Arc spans 270° (¾ of a circle), gap at the bottom.
    private static let arcSpan: Double = 270
    private static let startAngle = Angle.degrees(135)

    public var body: some View {
        ZStack {
            // Track (background arc)
            arcShape(progress: 1.0)
                .stroke(
                    GargantuaColors.surface3,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )

            // Fill (foreground arc)
            arcShape(progress: progress)
                .stroke(
                    range.color,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .animation(.linear(duration: 0.3), value: score)

            // Score + caption
            VStack(spacing: GargantuaSpacing.space1) {
                Text("\(score)")
                    .font(GargantuaFonts.display)
                    .foregroundStyle(GargantuaColors.ink)
                    .contentTransition(.numericText())
                    .animation(.linear(duration: 0.3), value: score)

                Text("Health")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
            }
        }
        .frame(width: size, height: size)
    }

    /// Creates an arc path for the given progress (0-1).
    private func arcShape(progress: Double) -> Path {
        Path { path in
            path.addArc(
                center: CGPoint(x: size / 2, y: size / 2),
                radius: (size - lineWidth) / 2,
                startAngle: Self.startAngle,
                endAngle: Angle.degrees(135 + Self.arcSpan * progress),
                clockwise: false
            )
        }
    }
}
