import SwiftUI

/// Reusable row scaffolding for settings sections.
///
/// Centralizes the icon-slot · title-and-detail · trailing-control layout that
/// every section reimplements, so spacing and alignment stay consistent.

/// Standard 24-pt leading icon slot used by every settings row.
struct SettingsRowIcon: View {
    let systemName: String
    var color: Color = GargantuaColors.ink3
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size))
            .foregroundStyle(color)
            .frame(width: 24, alignment: .center)
    }
}

/// Title + caption pair used as the leading copy block on most rows.
struct SettingsRowText: View {
    let title: String
    let detail: String?
    var detailColor: Color = GargantuaColors.ink3

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink)

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(detailColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Inline status/notice block. Use `tone` for safe/review/protected coloring.
struct SettingsNoticeRow: View {
    enum Tone { case info, safe, review, protected }

    let icon: String
    let message: String
    let tone: Tone

    var body: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(toneColor)
                .frame(width: 16, alignment: .center)

            Text(message)
                .font(GargantuaFonts.caption)
                .foregroundStyle(toneColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(GargantuaSpacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(toneColor.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .stroke(toneColor.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }

    private var toneColor: Color {
        switch tone {
        case .info: return GargantuaColors.accent
        case .safe: return GargantuaColors.safe
        case .review: return GargantuaColors.review
        case .protected: return GargantuaColors.protected_
        }
    }
}

/// Sub-grouping header used inside a `SettingsSectionContainer` card. Reuses
/// the Section-Label tier (10/600 uppercase, 0.8px tracking) so a single card
/// can split into "User Added" / "Bundled" sub-groups without rolling its own
/// header layout.
struct SettingsSubsectionHeader: View {
    let title: String
    let count: Int?

    init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    var body: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Text(title.uppercased())
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(GargantuaColors.ink3)

            Spacer()

            if let count {
                Text("\(count)")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink4)
            }
        }
    }
}

/// 1-px Border-Soft divider used between dense rows inside a section card.
struct SettingsHairlineDivider: View {
    var body: some View {
        Rectangle()
            .fill(GargantuaColors.borderSoft)
            .frame(height: 1)
    }
}

/// Compact circular-x remove glyph used by list-entry rows. Hover swaps to
/// `protected_` so the destructive intent is visible only when the cursor is
/// on the row, and the click target is the standard 18×18 slot.
struct SettingsRemoveButton: View {
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(isHovered ? GargantuaColors.protected_ : GargantuaColors.ink4)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovered = $0 }
    }
}

/// Icon + label + mono-data value triplet used by About, Cloud usage, and any
/// other key/value display row. `monoValue` is true when the value is a path,
/// byte count, percentage, or other numeric data; false for license names,
/// profile names, or other prose values.
struct SettingsValueRow: View {
    let icon: String
    let label: String
    let value: String
    var monoValue: Bool = true
    var background: Color?

    var body: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: icon, size: 14)

            Text(label)
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink)

            Spacer()

            Text(value)
                .font(monoValue ? GargantuaFonts.monoData : GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
        }
        .padding(.horizontal, background == nil ? 0 : GargantuaSpacing.space3)
        .padding(.vertical, background == nil ? 0 : GargantuaSpacing.space2)
        .background(background ?? Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }
}

/// Confirm sheet for destructive actions (Revoke key, Rotate token, Delete model).
/// One sheet contract instead of inline taps wired straight to destructive code.
struct DestructiveConfirmSheet: View {
    let title: String
    let message: String
    let confirmLabel: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(GargantuaColors.protected_)

                VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                    Text(title)
                        .font(GargantuaFonts.title)
                        .foregroundStyle(GargantuaColors.ink)

                    Text(message)
                        .font(GargantuaFonts.body)
                        .foregroundStyle(GargantuaColors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: GargantuaSpacing.space3) {
                Spacer()

                GargantuaButton("Cancel", tone: .neutral) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                GargantuaButton(confirmLabel, icon: "exclamationmark.octagon.fill", tone: .destructive) {
                    onConfirm()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(GargantuaSpacing.space5)
        .frame(width: 420)
        .background(GargantuaColors.surface3)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.large))
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.large)
                .stroke(GargantuaColors.borderEm, lineWidth: 1)
        )
    }
}
