import SwiftUI

struct UninstallPickerAppRow: View {
    let app: AppInfo
    let isChecked: Bool
    let categoryCount: Int?
    let onToggleCheck: () -> Void
    let onQuickUninstall: () -> Void
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            checkbox

            // Row body wrapped in a Button so keyboard / VoiceOver users can
            // reach the open-review path — the safest action on the screen
            // is the only one that should always be focusable. The checkbox
            // is a peer Button that routes taps independently. Quick
            // uninstall lives in the row's context menu (right-click /
            // control-click) so the destructive action requires explicit
            // intent and doesn't undermine the trust flow that's the whole
            // reason to use Gargantua over a manual drag-to-Trash. The
            // accessibilityAction below keeps the destructive path reachable
            // for VoiceOver users without forcing them through the menu.
            Button(action: onOpen) {
                rowContent
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open uninstall review for \(app.displayName ?? app.name)")
            .accessibilityAction(named: Text("Quick uninstall, skips review")) {
                onQuickUninstall()
            }
        }
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space5)
        .background(rowBackground)
        .onHover { isHovered = $0 }
        // contentShape pins the contextMenu's hit region to the entire
        // padded row rectangle so right-click on whitespace at the row's
        // edges still raises the menu. Without it, padding regions and the
        // gap between sibling Buttons may not register the gesture.
        .contentShape(Rectangle())
        // No ellipsis on the menu label: macOS convention is that an
        // ellipsis means "this opens a confirmation," and the quick-uninstall
        // path skips the plan-review modal entirely. The destructive role
        // styles the item red so the trade-off reads at a glance. The
        // "Quick" prefix differentiates this from the row's tap action,
        // which opens the plan-review modal.
        .contextMenu {
            Button(role: .destructive, action: onQuickUninstall) {
                Label(
                    "Quick Uninstall \(app.displayName ?? app.name)",
                    systemImage: "trash"
                )
            }
        }
    }

    private var rowBackground: Color {
        if isChecked {
            return GargantuaColors.accent.opacity(0.10)
        }
        return isHovered ? GargantuaColors.surface1 : Color.clear
    }

    private var checkbox: some View {
        Button(action: onToggleCheck) {
            ZStack {
                // Filled rect (or transparent) provides a hit-testable
                // interior. A bare RoundedRectangle().stroke() only
                // registers clicks on the 1.5pt outline, which is why the
                // checkbox felt unclickable even when the cursor was
                // visibly over it.
                RoundedRectangle(cornerRadius: 4)
                    .fill(isChecked ? GargantuaColors.accent : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(
                                isChecked ? GargantuaColors.accent : GargantuaColors.borderEm,
                                lineWidth: 1.5
                            )
                    )
                    .frame(width: 18, height: 18)

                if isChecked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            // Pad the visual checkbox out to a 32x32 tap target so the
            // user doesn't have to be pixel-precise on an 18pt control.
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isChecked ? "Deselect \(app.displayName ?? app.name)" : "Select \(app.displayName ?? app.name)")
        .accessibilityAddTraits(isChecked ? .isSelected : [])
    }

    private var rowContent: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: GargantuaSpacing.space2) {
                    Text(app.displayName ?? app.name)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                        .lineLimit(1)

                    if app.isRunning {
                        StatusPill(label: "Running", color: GargantuaColors.review)
                    }
                    if app.isSystemApp {
                        StatusPill(label: "System", color: GargantuaColors.ink3)
                    }
                    if let valid = app.signatureValid {
                        signaturePill(valid: valid)
                    }
                }

                Text(app.bundleID)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            sizeColumn
                .frame(width: UninstallPickerColumn.size, alignment: .trailing)

            lastUsedColumn
                .frame(width: UninstallPickerColumn.lastUsed, alignment: .trailing)

            orbitColumn
                .frame(width: UninstallPickerColumn.orbit, alignment: .center)
        }
    }

    /// Trailing per-row Confidence Orbit. The signature Gargantua signal
    /// indicator finally lands on the picker — DESIGN.md calls it the brand's
    /// orbit ring, and ``ConfidenceOrbit`` is the reusable component already
    /// shared by Dense Scan and Duplicate Finder. Pre-scan, "confidence"
    /// reads as remnant coverage density (categoryCount over total
    /// `RemnantCategory.allCases`), and safety is `.protected_` for system
    /// apps and `.review` for everything else (no plan to classify yet). The
    /// numeric category count moves to a hover tooltip per the brand-element
    /// brief; VoiceOver still reads the count via the row's accessibility
    /// label, so screen-reader users don't lose the signal.
    private var orbitColumn: some View {
        // Three distinct states so a blank cell is never ambiguous:
        //   nil → background scan hasn't reached this app → small accretion
        //         disk (the brand spinner) signals "working".
        //   0   → scan finished, no leftover categories → five fully-unlit
        //         bars via `floorClamp: false`. Reads as "we looked, nothing
        //         to clean" instead of falsely lighting the first bar.
        //   >0  → real coverage orbit, same as before.
        Group {
            if categoryCount == nil {
                AccretionDiskView(
                    activityRate: 6,
                    size: 12,
                    color: GargantuaColors.ink4
                )
            } else {
                ConfidenceOrbit(
                    confidence: UninstallPickerOrbit.confidencePercent(forCategoryCount: categoryCount),
                    safety: UninstallPickerOrbit.safety(forApp: app),
                    floorClamp: false
                )
            }
        }
        .help(orbitHelpText)
        .accessibilityHidden(true)
    }

    private var orbitHelpText: String {
        guard let count = categoryCount else {
            return "Scanning for leftover categories…"
        }
        guard count > 0 else {
            return "No leftover categories detected for this app"
        }
        let total = RemnantCategory.allCases.count
        let label = count == 1 ? "category" : "categories"
        return "\(count) of \(total) leftover \(label) for this app"
    }

    /// Right-aligned size cell. Always renders both rows (value + spacer
    /// caption) so row heights stay stable as async data arrives. The
    /// placeholder em-dash is rendered at zero opacity for the height contribution.
    private var sizeColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(app.sizeOnDisk.map(AlertItem.formatBytes) ?? "—")
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink)
                .opacity(app.sizeOnDisk == nil ? 0 : 1)
                .lineLimit(1)
                .accessibilityHidden(app.sizeOnDisk == nil)

            // Invisible placeholder reserves the caption-line height so the
            // size column's height matches the last-used column.
            Text("—")
                .font(GargantuaFonts.caption)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    /// Right-aligned last-used cell. The relative date sits on top; an
    /// invisible caption-line placeholder sits underneath so the column
    /// height stays in lock-step with `sizeColumn`. The category-count
    /// caption that previously lived here moved into the trailing
    /// `orbitColumn`'s hover tooltip — the orbit *is* that signal now, and
    /// duplicating the count next to it just adds visual noise.
    private var lastUsedColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(app.lastUsedDate.map(relativeDate) ?? "—")
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink)
                .opacity(app.lastUsedDate == nil ? 0 : 1)
                .lineLimit(1)
                .accessibilityHidden(app.lastUsedDate == nil)

            Text("—")
                .font(GargantuaFonts.caption)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private func signaturePill(valid: Bool) -> some View {
        StatusPill(
            label: valid ? "Signed" : "Unsigned",
            color: valid ? GargantuaColors.safe : GargantuaColors.review
        )
        .help(signatureHelpText(valid: valid))
    }

    private func signatureHelpText(valid: Bool) -> String {
        if valid {
            if let team = app.teamIdentifier {
                return "Code signature valid · Team ID: \(team)"
            }
            return "Code signature valid"
        }
        return "Code signature missing or invalid"
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct StatusPill: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(GargantuaFonts.caption)
            .foregroundStyle(color)
            .padding(.vertical, 1)
            .padding(.horizontal, 6)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
