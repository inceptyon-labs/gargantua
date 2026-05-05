import SwiftUI

/// Shared column widths for the picker header and rows. Keeping them in one
/// place is the only reason headers and row data line up; if a number changes
/// here the visual alignment updates everywhere it matters.
private enum PickerColumn {
    static let checkboxLane: CGFloat = 32
    static let size: CGFloat = 80
    static let lastUsed: CGFloat = 110
}

/// App picker step of the Smart Uninstaller flow.
///
/// Shows the filtered + sorted installed-app list with a search field, a
/// "Show system apps" toggle, and a clickable column-header row that doubles
/// as the sort control. Tapping a row begins planning.
struct UninstallAppPickerView: View {
    @Bindable var viewModel: SmartUninstallerViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            columnHeaders

            Rectangle()
                .fill(GargantuaColors.borderSoft)
                .frame(height: 1)

            if viewModel.visibleApps.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.visibleApps) { app in
                            AppRow(
                                app: app,
                                isChecked: viewModel.multiSelected.contains(app.bundleID),
                                categoryCount: viewModel.categoryCounts[app.bundleID],
                                onToggleCheck: { viewModel.toggleMultiSelect(bundleID: app.bundleID) },
                                onQuickUninstall: { viewModel.runTracked { await viewModel.quickUninstall(app) } },
                                onOpen: { viewModel.runTracked { await viewModel.selectApp(app) } }
                            )
                            .accessibilityLabel(Text(accessibilityLabel(
                                for: app,
                                categoryCount: viewModel.categoryCounts[app.bundleID]
                            )))

                            if app.id != viewModel.visibleApps.last?.id {
                                Rectangle()
                                    .fill(GargantuaColors.borderSoft)
                                    .frame(height: 1)
                            }
                        }
                    }
                }
            }

            if !viewModel.multiSelected.isEmpty {
                batchActionBar
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            Text("Smart Uninstaller")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)

            Text("Choose an app to uninstall. Gargantua will find its leftover files.")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, GargantuaSpacing.space5)
        .padding(.top, GargantuaSpacing.space5)
        .padding(.bottom, GargantuaSpacing.space3)
    }

    private var toolbar: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            SearchField(text: $viewModel.query)
                .frame(maxWidth: 320)

            Toggle(isOn: $viewModel.showSystemApps) {
                Text("Show system apps")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Spacer()

            Text("\(viewModel.visibleApps.count) of \(viewModel.apps.count)")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)

            rescanButton
        }
        .padding(.horizontal, GargantuaSpacing.space5)
        .padding(.vertical, GargantuaSpacing.space3)
    }

    private var columnHeaders: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            // Reserve the checkbox lane so "Name" lines up with row text,
            // not the checkbox.
            Color.clear
                .frame(width: PickerColumn.checkboxLane, height: 1)

            SortableColumnHeader(
                label: "Name",
                field: .name,
                currentField: viewModel.sort,
                ascending: viewModel.sortAscending,
                alignment: .leading,
                onTap: { viewModel.applySort(.name) }
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            SortableColumnHeader(
                label: "Size",
                field: .size,
                currentField: viewModel.sort,
                ascending: viewModel.sortAscending,
                alignment: .trailing,
                onTap: { viewModel.applySort(.size) }
            )
            .frame(width: PickerColumn.size, alignment: .trailing)

            SortableColumnHeader(
                label: "Last used",
                field: .lastUsed,
                currentField: viewModel.sort,
                ascending: viewModel.sortAscending,
                alignment: .trailing,
                onTap: { viewModel.applySort(.lastUsed) }
            )
            .frame(width: PickerColumn.lastUsed, alignment: .trailing)
        }
        .padding(.horizontal, GargantuaSpacing.space5)
        .padding(.vertical, GargantuaSpacing.space2)
        // Group the three sortable headers under one VoiceOver container so
        // the cluster reads as the picker's sort affordance, not three
        // isolated buttons. Mirrors what GargantuaSegmentedPicker conveyed.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sort apps")
    }

    private var batchActionBar: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Text(viewModel.multiSelected.count == 1
                ? "1 app selected"
                : "\(viewModel.multiSelected.count) apps selected")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink)

            // Surface selections the current filter is hiding so the user
            // can't accidentally trash apps that fell off-screen when they
            // typed in search or flipped the system-apps toggle.
            if viewModel.hiddenSelectedCount > 0 {
                hiddenSelectionPill
            }

            Spacer()

            Button {
                viewModel.clearMultiSelect()
            } label: {
                Text("Clear")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink2)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .padding(.horizontal, GargantuaSpacing.space3)
                    .overlay(
                        RoundedRectangle(cornerRadius: GargantuaRadius.small)
                            .stroke(GargantuaColors.borderEm, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear app selection")

            Button {
                viewModel.runTracked { await viewModel.startBatchUninstall() }
            } label: {
                Text(viewModel.multiSelected.count == 1
                    ? "Uninstall 1 app"
                    : "Uninstall \(viewModel.multiSelected.count) apps")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(.white)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .background(GargantuaColors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal, GargantuaSpacing.space5)
        .padding(.vertical, GargantuaSpacing.space3)
        .background(GargantuaColors.surface1)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)
        }
    }

    private var hiddenSelectionPill: some View {
        Button {
            viewModel.clearHiddenSelections()
        } label: {
            Text("Drop \(viewModel.hiddenSelectedCount) not shown")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.review)
                .padding(.vertical, 1)
                .padding(.horizontal, 6)
                .background(GargantuaColors.reviewDim)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help("These apps are selected but hidden by the active filter. Click to drop them.")
        .accessibilityLabel("Drop \(viewModel.hiddenSelectedCount) selections that aren't shown")
    }

    private var rescanButton: some View {
        Button {
            viewModel.runTracked { await viewModel.rescanApps() }
        } label: {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                Text("Rescan")
                    .font(GargantuaFonts.label)
            }
            .foregroundStyle(GargantuaColors.ink2)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
        .accessibilityLabel("Rescan installed apps")
        .help("Re-enumerate every installed app from scratch (⌘R)")
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.apps.isEmpty {
            emptyStateNoApps
        } else if !viewModel.query.isEmpty {
            emptyStateNoMatches
        } else {
            emptyStateAllFiltered
        }
    }

    private var emptyStateNoApps: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "questionmark.app.dashed")
                .font(.system(size: 28))
                .foregroundStyle(GargantuaColors.ink4)

            Text("Couldn't find any installed apps")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink2)

            Text("This usually means Gargantua doesn't have permission to read your Applications folder. Grant access in System Settings, then rescan.")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            HStack(spacing: GargantuaSpacing.space2) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                    Link(destination: url) {
                        Text("Open System Settings")
                            .font(GargantuaFonts.label)
                            .foregroundStyle(GargantuaColors.ink)
                            .padding(.vertical, GargantuaSpacing.space2)
                            .padding(.horizontal, GargantuaSpacing.space4)
                            .overlay(
                                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                                    .stroke(GargantuaColors.borderEm, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    viewModel.runTracked { await viewModel.rescanApps() }
                } label: {
                    Text("Rescan")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(.white)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .background(GargantuaColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, GargantuaSpacing.space1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateNoMatches: some View {
        VStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(GargantuaColors.ink4)

            Text("No matches")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink2)

            Text("Search covers app name and bundle identifier. Try a shorter or different term.")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if viewModel.hiddenSystemMatchCount > 0 {
                Button {
                    viewModel.showSystemApps = true
                } label: {
                    Text(viewModel.hiddenSystemMatchCount == 1
                        ? "1 system app matches. Show system apps?"
                        : "\(viewModel.hiddenSystemMatchCount) system apps match. Show system apps?")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, GargantuaSpacing.space2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateAllFiltered: some View {
        VStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 28))
                .foregroundStyle(GargantuaColors.ink4)

            Text("Nothing to show")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink2)

            Text("Every installed app is filtered out. Turn on \"Show system apps\" if you're looking for one of those.")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func accessibilityLabel(for app: AppInfo, categoryCount: Int?) -> String {
        var parts: [String] = [app.displayName ?? app.name]
        if let size = app.sizeOnDisk {
            parts.append(AlertItem.formatBytes(size))
        }
        if app.isRunning { parts.append("running") }
        if app.isSystemApp { parts.append("system app") }
        if let valid = app.signatureValid {
            parts.append(valid ? "signed" : "unsigned")
        }
        if let count = categoryCount, count > 0 {
            parts.append(count == 1 ? "1 leftover category" : "\(count) leftover categories")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Search Field

private struct SearchField: View {
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

// MARK: - App Row

private struct AppRow: View {
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
                .frame(width: PickerColumn.size, alignment: .trailing)

            lastUsedColumn
                .frame(width: PickerColumn.lastUsed, alignment: .trailing)
        }
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

    /// Right-aligned last-used cell. The relative date sits on top; the
    /// remnant-category caption sits underneath so async category-count
    /// arrival doesn't shift the row height.
    private var lastUsedColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(app.lastUsedDate.map(relativeDate) ?? "—")
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink)
                .opacity(app.lastUsedDate == nil ? 0 : 1)
                .lineLimit(1)
                .accessibilityHidden(app.lastUsedDate == nil)

            Text(categoryCaption ?? "—")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .opacity(categoryCaption == nil ? 0 : 1)
                .lineLimit(1)
                .accessibilityHidden(categoryCaption == nil)
        }
    }

    private var categoryCaption: String? {
        guard let count = categoryCount, count > 0 else { return nil }
        return count == 1 ? "1 category" : "\(count) categories"
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

// MARK: - Sortable Column Header

/// Clickable column header for the picker list. Tapping switches the active
/// sort field; tapping the active field again flips its direction. The active
/// header carries an up/down chevron and primary ink so the user always knows
/// which column is driving the order.
private struct SortableColumnHeader: View {
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
