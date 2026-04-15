import SwiftUI

// MARK: - HSL → Color

/// SwiftUI Color from HSL values (design system uses HSL, SwiftUI uses HSB).
private func hsl(_ h: Double, _ s: Double, _ l: Double) -> Color {
    let s = s / 100
    let l = l / 100
    let a = s * min(l, 1 - l)
    let f = { (n: Double) -> Double in
        let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
        return l - a * max(min(k - 3, 9 - k, 1), -1)
    }
    return Color(red: f(0), green: f(8), blue: f(4))
}

// MARK: - Color Tokens

/// Design system color tokens from .interface-design/system.md.
///
/// Named after the Gargantua space theme — surfaces are void-dark,
/// safety colors (green/amber/red) are the warmest things in the interface.
public enum GargantuaColors {
    // MARK: Surfaces
    /// Canvas / page background. hsl(220, 14%, 9%)
    public static let void_ = hsl(220, 14, 9)
    /// Sidebar, panels. hsl(220, 12%, 11%)
    public static let surface1 = hsl(220, 12, 11)
    /// Cards, list rows. hsl(220, 11%, 14%)
    public static let surface2 = hsl(220, 11, 14)
    /// Dropdowns, elevated cards. hsl(220, 10%, 17%)
    public static let surface3 = hsl(220, 10, 17)
    /// Tooltips, topmost layer. hsl(220, 10%, 20%)
    public static let surface4 = hsl(220, 10, 20)

    // MARK: Text
    /// Primary text — star-white. hsl(210, 20%, 94%)
    public static let ink = hsl(210, 20, 94)
    /// Secondary text — dim star gray. hsl(215, 12%, 65%)
    public static let ink2 = hsl(215, 12, 65)
    /// Tertiary — nebula muted. hsl(218, 10%, 45%)
    public static let ink3 = hsl(218, 10, 45)
    /// Disabled, placeholder. hsl(220, 8%, 30%)
    public static let ink4 = hsl(220, 8, 30)

    // MARK: Borders
    /// Standard separation.
    public static let border = Color.white.opacity(0.07)
    /// Subtle separation.
    public static let borderSoft = Color.white.opacity(0.04)
    /// Emphasis.
    public static let borderEm = Color.white.opacity(0.13)

    // MARK: Safety Classification
    /// Safe — desaturated terminal green. hsl(148, 45%, 42%)
    public static let safe = hsl(148, 45, 42)
    /// Review — accretion disc amber. hsl(38, 85%, 52%)
    public static let review = hsl(38, 85, 52)
    /// Protected — deep red ember. hsl(0, 62%, 48%)
    public static let protected_ = hsl(0, 62, 48)

    // MARK: Interactive
    /// Hawking radiation blue — buttons, links, focus. hsl(213, 90%, 55%)
    public static let accent = hsl(213, 90, 55)
}

// MARK: - Typography Tokens

/// Design system typography from .interface-design/system.md.
public enum GargantuaFonts {
    /// Section headers. 16px, 600 weight.
    public static let heading = Font.system(size: 16, weight: .semibold)
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
