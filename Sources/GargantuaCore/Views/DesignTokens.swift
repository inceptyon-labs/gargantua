import AppKit
import SwiftUI

// MARK: - HSL → NSColor

/// sRGB NSColor from HSL values (design system uses HSL, AppKit uses RGB).
private func hslNS(_ h: Double, _ s: Double, _ l: Double, _ alpha: Double = 1) -> NSColor {
    let s = s / 100
    let l = l / 100
    let a = s * min(l, 1 - l)
    let f = { (n: Double) -> Double in
        let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
        return l - a * max(min(k - 3, 9 - k, 1), -1)
    }
    return NSColor(srgbRed: f(0), green: f(8), blue: f(4), alpha: alpha)
}

/// An appearance-adaptive Color. Resolves `dark` under `.darkAqua`, `light`
/// otherwise, so a single token serves all three appearance modes (system
/// resolves to whichever the OS is currently showing). SwiftUI re-evaluates
/// the wrapped dynamic NSColor whenever the environment appearance flips.
private func adaptive(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

/// An HSL triple, resolved to an sRGB NSColor on demand. Lets the token
/// definitions read as `light:`/`dark:` pairs without tripping the linter's
/// tuple / parameter-count rules.
private struct HSLColor {
    let h: Double
    let s: Double
    let l: Double
    init(_ h: Double, _ s: Double, _ l: Double) {
        self.h = h
        self.s = s
        self.l = l
    }
    var ns: NSColor { hslNS(h, s, l) }
}

/// Convenience: adaptive Color from light/dark HSL triples.
private func adaptive(light: HSLColor, dark: HSLColor) -> Color {
    adaptive(light: light.ns, dark: dark.ns)
}

// MARK: - Color Tokens

/// Design system color tokens from .interface-design/system.md.
///
/// Named after the Gargantua space theme. In dark mode (the original theme)
/// surfaces are void-dark and the safety colors are the warmest things in the
/// interface. Each token carries a light-mode counterpart so the whole UI
/// adapts to the user's chosen appearance (light / dark / system).
public enum GargantuaColors {

    // MARK: Surfaces

    /// Canvas / page background.
    public static let void_ = adaptive(light: HSLColor(220, 22, 96), dark: HSLColor(220, 14, 9))
    /// Sidebar, panels.
    public static let surface1 = adaptive(light: HSLColor(220, 20, 98), dark: HSLColor(220, 12, 11))
    /// Cards, list rows.
    public static let surface2 = adaptive(light: HSLColor(0, 0, 100), dark: HSLColor(220, 11, 14))
    /// Dropdowns, elevated cards.
    public static let surface3 = adaptive(light: HSLColor(220, 24, 99), dark: HSLColor(220, 10, 17))
    /// Tooltips, topmost layer.
    public static let surface4 = adaptive(light: HSLColor(0, 0, 100), dark: HSLColor(220, 10, 20))

    // MARK: Text

    /// Primary text — star-white in dark, near-black in light.
    public static let ink = adaptive(light: HSLColor(220, 26, 13), dark: HSLColor(210, 20, 94))
    /// Secondary text.
    public static let ink2 = adaptive(light: HSLColor(216, 14, 36), dark: HSLColor(215, 12, 65))
    /// Tertiary — muted.
    public static let ink3 = adaptive(light: HSLColor(218, 11, 50), dark: HSLColor(218, 10, 45))
    /// Disabled, placeholder.
    public static let ink4 = adaptive(light: HSLColor(220, 9, 68), dark: HSLColor(220, 8, 30))

    // MARK: Borders

    /// Standard separation. White-on-void in dark, black-on-paper in light.
    public static let border = adaptive(light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.07))
    /// Subtle separation.
    public static let borderSoft = adaptive(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.04))
    /// Emphasis.
    public static let borderEm = adaptive(light: NSColor(white: 0, alpha: 0.16), dark: NSColor(white: 1, alpha: 0.13))

    /// Neutral darkening scrim used behind chips/pills. Black in dark, a
    /// lighter black in light so it doesn't punch a hole in paper surfaces.
    public static let scrim = adaptive(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 0, alpha: 0.18))

    /// Hover tint for transparent rows on Void. Darkens in light and lightens
    /// in dark; the light surface steps are 2% apart, too close to read as hover.
    public static let hoverFill = adaptive(
        light: NSColor(white: 0, alpha: 0.06),
        dark: NSColor(white: 1, alpha: 0.04)
    )

    // MARK: Safety Classification

    /// Safe — terminal green. Darkened a touch in light for contrast on paper.
    public static let safe = adaptive(light: HSLColor(148, 58, 34), dark: HSLColor(148, 45, 42))
    /// Safe background tint.
    public static let safeDim = safe.opacity(0.12)
    /// Review — accretion disc amber. Darkened in light so it reads on white.
    public static let review = adaptive(light: HSLColor(36, 92, 42), dark: HSLColor(38, 85, 52))
    /// Review background tint.
    public static let reviewDim = review.opacity(0.12)
    /// Accretion disc amber — alias of `review` used by the Smart Uninstaller
    /// console where the semantic is "material being pulled into Gargantua",
    /// not "needs review". Same pixels, different name.
    public static let accretion = review
    /// Protected — deep red ember.
    public static let protected_ = adaptive(light: HSLColor(0, 68, 46), dark: HSLColor(0, 62, 48))
    /// Protected background tint.
    public static let protectedDim = protected_.opacity(0.12)

    // MARK: Interactive

    /// Hawking radiation blue — buttons, links, focus.
    public static let accent = adaptive(light: HSLColor(213, 90, 48), dark: HSLColor(213, 90, 55))
    /// Focus ring border — 2px accent stroke with 2px offset.
    public static let borderFocus = accent
}

// MARK: - Typography Tokens

/// Design system typography from .interface-design/system.md.
public enum GargantuaFonts {
    /// Top-level grouping header that sits ABOVE a stack of cards (e.g. the
    /// AI tab's "Your AI engines" / "What uses which engine"). 20px, 700 — a
    /// clear step between the 28px page display title and the 15px card titles.
    public static let sectionHeading = Font.system(size: 20, weight: .bold)
    /// Section headers. 16px, 600 weight.
    public static let heading = Font.system(size: 16, weight: .semibold)
    /// Panel names, dynamic state headlines, status titles. 15px, 600 weight.
    public static let title = Font.system(size: 15, weight: .semibold)
    /// List item names. 13px, 500 weight.
    public static let label = Font.system(size: 13, weight: .medium)
    /// Descriptions, explanations. 13px, 400 weight.
    public static let body = Font.system(size: 13, weight: .regular)
    /// Metadata, timestamps. 11px, 400 weight.
    public static let caption = Font.system(size: 11, weight: .regular)
    /// File sizes, confidence. 12px mono, tabular numbers.
    public static let monoData = Font.system(size: 12, design: .monospaced).monospacedDigit()
    /// File paths. 11px mono.
    public static let monoPath = Font.system(size: 11, design: .monospaced)
    /// Sidebar section labels. 10px, 600 weight, uppercase, 0.08em tracking.
    public static let sectionLabel = Font.system(size: 10, weight: .semibold)
    /// Display metric — health score, primary KPI. 28px, 700 weight.
    public static let display = Font.system(size: 28, weight: .bold)
}

// MARK: - Spacing Tokens

/// Design system spacing (4px base unit) from .interface-design/system.md.
public enum GargantuaSpacing {
    /// 4px — icon gaps, tight pairs.
    public static let space1: CGFloat = 4
    /// 8px — inline spacing within components.
    public static let space2: CGFloat = 8
    /// 12px — compact component padding.
    public static let space3: CGFloat = 12
    /// 16px — standard component padding.
    public static let space4: CGFloat = 16
    /// 24px — between related groups.
    public static let space5: CGFloat = 24
    /// 32px — between distinct sections.
    public static let space6: CGFloat = 32
    /// 48px — major layout separation.
    public static let space7: CGFloat = 48
    /// 64px — page-level breathing room.
    public static let space8: CGFloat = 64
}

// MARK: - Radius Tokens

/// Design system border radii from .interface-design/system.md.
public enum GargantuaRadius {
    /// Inputs, buttons, badges.
    public static let small: CGFloat = 4
    /// Cards, list containers.
    public static let medium: CGFloat = 6
    /// Modals, sheets.
    public static let large: CGFloat = 8
}
