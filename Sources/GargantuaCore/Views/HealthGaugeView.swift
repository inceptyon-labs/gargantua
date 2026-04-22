import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

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
            // Lensing glow behind the metric arc, keyed to the current health range.
            arcShape(progress: 1.0)
                .stroke(
                    AngularGradient(
                        colors: [
                            range.color.opacity(0.08),
                            range.color.opacity(0.36),
                            Color(red: 1.0, green: 0.56, blue: 0.14).opacity(0.28),
                            GargantuaColors.surface3.opacity(0.18),
                            range.color.opacity(0.08),
                        ],
                        center: .center,
                        startAngle: Self.startAngle,
                        endAngle: Angle.degrees(135 + Self.arcSpan)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth * 1.8, lineCap: .round)
                )
                .blur(radius: lineWidth * 0.45)

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

            eventHorizonCore

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

    private var eventHorizonCore: some View {
        ZStack {
            if let image = Self.brandImage {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.82, height: size * 0.82)
                    .opacity(0.72)
                    .saturation(1.08)
            } else {
                Circle()
                    .fill(GargantuaColors.void_)
                    .frame(width: size * 0.54, height: size * 0.54)
            }

            Circle()
                .fill(GargantuaColors.void_.opacity(0.68))
                .frame(width: size * 0.50, height: size * 0.50)
                .shadow(color: .black.opacity(0.45), radius: lineWidth, x: 0, y: 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

    private static let brandImage: Image? = {
        guard let url = Bundle.module.url(
            forResource: "gargantua-logo",
            withExtension: "png",
            subdirectory: "Brand"
        ) else {
            return nil
        }

        #if os(macOS)
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: nsImage)
        #elseif os(iOS)
        guard let uiImage = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: uiImage)
        #else
        return nil
        #endif
    }()
}
