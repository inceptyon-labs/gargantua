import SwiftUI

/// Shared column widths for the picker header and rows. Keeping them in one
/// place is the only reason headers and row data line up; if a number changes
/// here the visual alignment updates everywhere it matters.
enum UninstallPickerColumn {
    static let checkboxLane: CGFloat = 32
    static let size: CGFloat = 80
    static let lastUsed: CGFloat = 110
    /// Trailing lane that holds the per-row Confidence Orbit. Width matches
    /// the orbit's intrinsic 24pt frame plus a touch of breathing room so the
    /// indicator doesn't kiss the row's right edge.
    static let orbit: CGFloat = 28
}

/// Maps `viewModel.categoryCounts` and `AppInfo` flags onto the inputs of the
/// shared ``ConfidenceOrbit`` component.
///
/// Pre-scan, the picker has no per-app safety classification — there is no
/// plan yet — so the orbit is intentionally a *coverage* indicator: how much
/// remnant signal density we already have for this app, color-anchored by
/// whether the app itself sits in protected territory.
enum UninstallPickerOrbit {
    /// Map a category count onto the 0–100 confidence percent that
    /// ``ConfidenceOrbit`` consumes. Buckets at every 20% so the rendered
    /// bar count steps 1 → 5 monotonically with `count`.
    static func confidencePercent(forCategoryCount count: Int?) -> Int {
        guard let count, count > 0 else { return 0 }
        let total = RemnantCategory.allCases.count
        guard total > 0 else { return 0 }
        let pct = Double(count) / Double(total) * 100.0
        return min(100, max(0, Int(pct.rounded())))
    }

    /// Pick a safety color for the orbit. System-app rows always read
    /// `protected_` because uninstalling them is the dangerous path; every
    /// other row reads `review` (accretion-disc amber) — the neutral default
    /// when no plan classification has been computed yet.
    static func safety(forApp app: AppInfo) -> SafetyLevel {
        app.isSystemApp ? .protected_ : .review
    }
}

struct UninstallPickerSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(GargantuaColors.ink3)

            TextField("Search apps", text: $text)
                .textFieldStyle(.plain)
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(GargantuaColors.ink3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space3)
        .background(GargantuaColors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .stroke(GargantuaColors.border, lineWidth: 1)
        )
    }
}

/// Clickable column header for the picker list. Tapping switches the active
/// sort field; tapping the active field again flips its direction. The active
/// header carries an up/down chevron and primary ink so the user always knows
/// which column is driving the order.
struct UninstallPickerSortableColumnHeader: View {
    let label: String
    let field: UninstallAppSort
    let currentField: UninstallAppSort
    let ascending: Bool
    let alignment: HorizontalAlignment
    let onTap: () -> Void

    @State private var isHovered = false

    private var isActive: Bool { field == currentField }

    private var frameAlignment: Alignment {
        alignment == .leading ? .leading : .trailing
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if alignment == .trailing {
                    Spacer(minLength: 0)
                }

                Text(label)
                    .font(GargantuaFonts.sectionLabel)
                    .foregroundStyle(isActive ? GargantuaColors.ink : GargantuaColors.ink2)
                    .textCase(.uppercase)
                    .tracking(0.4)

                // Reserve space for the chevron in every header so the label
                // doesn't shift horizontally when sort field switches.
                Image(systemName: ascending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(GargantuaColors.ink2)
                    .opacity(isActive ? 1 : 0)

                if alignment == .leading {
                    Spacer(minLength: 0)
                }
            }
            // Expand to fill the parent's column width so the entire lane
            // is a click target, and so the label/chevron sit flush against
            // the column edge — that flush alignment is what makes the
            // headers line up pixel-precisely with the row data underneath.
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isHovered ? GargantuaColors.surface1 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isActive ? "Tap again to flip direction" : "Sort by \(label.lowercased())")
        .accessibilityLabel("Sort by \(label.lowercased())")
        .accessibilityValue(isActive ? (ascending ? "ascending" : "descending") : "inactive")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
