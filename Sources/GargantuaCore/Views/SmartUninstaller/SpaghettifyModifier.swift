import SwiftUI

/// Visual "swallowed by Gargantua" effect for deleted path rows.
///
/// During the uninstall `executing` phase each successfully removed path is
/// shown briefly, then the text's trailing characters dissolve into dots and
/// the whole line stretches, fades, and collapses vertically — as if it's
/// being spaghettified across the event horizon.
///
/// Failed paths never spaghettify; they stay put with the `✗` badge so the
/// user sees what didn't go.
public enum Spaghettify {
    /// Total on-screen duration of the animation, in seconds.
    public static let duration: TimeInterval = 0.4

    /// How long the row lingers at full opacity before the animation starts.
    /// Gives the eye a chance to register the path before it dissolves.
    public static let dwell: TimeInterval = 0.25

    /// Characters the tail dissolves into, cycled by position.
    static let dissolveGlyphs: [Character] = ["·", ".", ".", "·", " ", "⊙"]

    /// Max number of trailing characters that get replaced during the
    /// middle third of the animation.
    static let maxTailStrip = 10

    /// Kerning (points) applied to each character at `progress == 1`.
    static let maxTracking: CGFloat = 8

    /// Compute the textual portion of the spaghettification.
    ///
    /// `progress == 0` returns `base` unchanged. Between 0.33 and 0.66 the
    /// trailing characters of `base` are progressively swapped for glyphs
    /// drawn from `dissolveGlyphs`. Beyond 0.66 the max-strip is held and
    /// the rest of the animation is opacity + layout collapse.
    public static func text(_ base: String, progress: Double) -> String {
        guard progress > 0 else { return base }
        let clamped = min(max(progress, 0), 1)
        let chars = Array(base)
        guard !chars.isEmpty else { return base }

        let strip: Int
        if clamped <= 0.33 {
            strip = 0
        } else if clamped >= 0.66 {
            strip = min(maxTailStrip, chars.count)
        } else {
            let p = (clamped - 0.33) / 0.33
            strip = min(Int((Double(maxTailStrip) * p).rounded()), chars.count)
        }
        guard strip > 0 else { return base }

        let keptCount = chars.count - strip
        let kept = String(chars.prefix(keptCount))
        let tail = (0..<strip).map { dissolveGlyphs[$0 % dissolveGlyphs.count] }
        return kept + String(tail)
    }
}

/// View modifier that applies the visual portion of the spaghettification —
/// tracking, opacity, and a vertical collapse — as `progress` moves from 0
/// to 1. Honors `accessibilityReduceMotion` by collapsing the animation to
/// an instant disappearance.
public struct SpaghettifyModifier: ViewModifier {
    let progress: Double
    let reduceMotion: Bool

    public init(progress: Double, reduceMotion: Bool) {
        self.progress = progress
        self.reduceMotion = reduceMotion
    }

    public func body(content: Content) -> some View {
        if reduceMotion {
            // No kerning fan-out, no scale collapse — just a hard cut once
            // progress crosses any threshold so the row still leaves the list.
            content
                .opacity(progress >= 0.5 ? 0 : 1)
                .frame(maxHeight: progress >= 0.5 ? 0 : nil)
                .clipped()
        } else {
            content
                .tracking(Spaghettify.maxTracking * CGFloat(progress))
                .opacity(1 - progress)
                .scaleEffect(x: 1, y: 1 - progress, anchor: .top)
                .frame(maxHeight: progress >= 1 ? 0 : nil)
                .clipped()
        }
    }
}

public extension View {
    /// Apply the spaghettification visual. Pair with `Spaghettify.text` on the
    /// underlying text so character-level dissolve happens in sync.
    func spaghettify(progress: Double, reduceMotion: Bool) -> some View {
        modifier(SpaghettifyModifier(progress: progress, reduceMotion: reduceMotion))
    }
}
