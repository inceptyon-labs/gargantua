import SwiftUI

/// Small rotating accretion disk used as the Smart Uninstaller's activity
/// indicator. Replaces the Unicode ring spinner in `EventHorizonConsoleView`
/// with something the theme actually earns.
///
/// The disk is drawn with `Canvas` + `TimelineView(.animation)` so rotation
/// is driven by the frame clock rather than a `Timer.publish`. When
/// `activityRate` is zero the disk slow-drifts; as scan/delete events stream
/// in it spins proportionally faster.
public struct AccretionDiskView: View {
    /// Events-per-second hint. 0 = idle drift, higher = faster rotation.
    let activityRate: Double
    let size: CGFloat
    let color: Color

    public init(
        activityRate: Double = 0,
        size: CGFloat = 14,
        color: Color = GargantuaColors.accretion
    ) {
        self.activityRate = activityRate
        self.size = size
        self.color = color
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            Canvas { ctx, canvasSize in
                draw(into: &ctx, size: canvasSize, time: context.date.timeIntervalSinceReferenceDate)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
    }

    private func draw(into ctx: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        let innerRadius = radius * 0.28

        // Rotation speed: idle ~0.4 rad/s, bumps up with activity, capped so
        // a firehose of events doesn't blur into a solid ring.
        let rps = min(0.4 + activityRate * 0.08, 4.5)
        let angle = (time * rps).truncatingRemainder(dividingBy: .pi * 2)

        // Main disc — radial amber gradient, warm core fading into the void.
        let discRect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let disc = Path(ellipseIn: discRect)
        ctx.fill(
            disc,
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: color.opacity(0.95), location: 0),
                    .init(color: color.opacity(0.55), location: 0.55),
                    .init(color: color.opacity(0.0), location: 1),
                ]),
                center: center,
                startRadius: 0,
                endRadius: radius
            )
        )

        // Lensing arc — bright crescent swept by the rotation.
        var arc = Path()
        let arcRadius = radius * 0.78
        let sweep = 0.55 * .pi
        arc.addArc(
            center: center,
            radius: arcRadius,
            startAngle: .radians(angle),
            endAngle: .radians(angle + sweep),
            clockwise: false
        )
        ctx.stroke(
            arc,
            with: .color(color.opacity(0.9)),
            style: StrokeStyle(lineWidth: max(1, radius * 0.18), lineCap: .round)
        )

        // Hot core — solid center, always on.
        let coreRect = CGRect(
            x: center.x - innerRadius,
            y: center.y - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2
        )
        ctx.fill(Path(ellipseIn: coreRect), with: .color(color))
    }
}
