import SwiftUI

/// App picker step of the Smart Uninstaller flow.
///
/// Shows the filtered + sorted installed-app list with search, sort selector,
/// and a "Show system apps" toggle. Tapping a row begins planning.
struct UninstallAppPickerView: View {
    @Bindable var viewModel: SmartUninstallerViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar

            Rectangle()
                .fill(GargantuaColors.border)
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
                                onQuickUninstall: { Task { await viewModel.quickUninstall(app) } },
                                onOpen: { Task { await viewModel.selectApp(app) } }
                            )
                            .accessibilityLabel(Text(accessibilityLabel(for: app)))

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

            Text("Choose an app to uninstall — Gargantua will find its leftover files.")
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

            SortPicker(
                sort: viewModel.sort,
                ascending: viewModel.sortAscending,
                onSelect: { viewModel.applySort($0) }
            )
            .frame(width: 260)

            Toggle(isOn: $viewModel.showSystemApps) {
                Text("System apps")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Spacer()

            Text("\(viewModel.visibleApps.count) of \(viewModel.apps.count)")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)

            refreshButton
            rescanButton
        }
        .padding(.horizontal, GargantuaSpacing.space5)
        .padding(.vertical, GargantuaSpacing.space3)
    }

    private var batchActionBar: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Text(viewModel.multiSelected.count == 1
                ? "1 app selected"
                : "\(viewModel.multiSelected.count) apps selected")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink)

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
                Task { await viewModel.startBatchUninstall() }
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
            .keyboardShortcut(.return, modifiers: [])
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

    private var refreshButton: some View {
        Button {
            viewModel.pruneMissingApps()
        } label: {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                Text("Refresh")
                    .font(GargantuaFonts.label)
            }
            .foregroundStyle(GargantuaColors.accent)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
        .accessibilityLabel("Refresh installed apps")
        .help("Drop apps that were just uninstalled (⌘R)")
    }

    private var rescanButton: some View {
        Button {
            Task { await viewModel.rescanApps() }
        } label: {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                Text("Rescan")
                    .font(GargantuaFonts.label)
            }
            .foregroundStyle(GargantuaColors.accent)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .accessibilityLabel("Rescan installed apps")
        .help("Re-enumerate every installed app from scratch (⇧⌘R)")
    }

    private var emptyState: some View {
        VStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "app.badge")
                .font(.system(size: 28))
                .foregroundStyle(GargantuaColors.ink4)

            Text(viewModel.query.isEmpty ? "No apps found" : "No matches")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink2)

            if !viewModel.query.isEmpty {
                Text("Clear the search or try a different name.")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func accessibilityLabel(for app: AppInfo) -> String {
        var parts: [String] = [app.displayName ?? app.name]
        if let size = app.sizeOnDisk {
            parts.append(AlertItem.formatBytes(size))
        }
        if app.isRunning { parts.append("running") }
        if app.isSystemApp { parts.append("system app") }
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

            // Open-row tap target: use a tap gesture instead of a Button so
            // it nests cleanly inside the same HStack as the checkbox /
            // quick-uninstall Buttons. macOS SwiftUI routes Button taps to
            // the innermost Button, but a parent Button with sibling Buttons
            // makes hit-testing on the parent unreliable.
            rowContent
                .contentShape(Rectangle())
                .onTapGesture { onOpen() }

            quickUninstallButton

            Button(action: onOpen) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GargantuaColors.ink4)
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show details for \(app.displayName ?? app.name)")
        }
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space5)
        .background(rowBackground)
        .onHover { isHovered = $0 }
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
                }

                Text(app.bundleID)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let size = app.sizeOnDisk {
                    Text(AlertItem.formatBytes(size))
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink2)
                }
                if let date = app.lastUsedDate {
                    Text(relativeDate(date))
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink4)
                }
                if let count = categoryCount, count > 0 {
                    Text(count == 1 ? "1 category" : "\(count) categories")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }
        }
    }

    @ViewBuilder
    private var quickUninstallButton: some View {
        Button(action: onQuickUninstall) {
            Image(systemName: "trash")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GargantuaColors.protected_)
                .frame(width: 28, height: 24)
                .background(GargantuaColors.protected_.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        }
        .buttonStyle(.plain)
        .opacity(isHovered ? 1 : 0)
        .accessibilityLabel("Quick uninstall \(app.displayName ?? app.name)")
        .help("Uninstall \(app.displayName ?? app.name) (skip review)")
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

// MARK: - Sort Picker
//
// Like `GargantuaSegmentedPicker` but the active segment shows a chevron
// indicating direction, and tapping it again flips ascending/descending.
// Tapping a different segment selects that field at its natural default
// direction (handled by the view model).
private struct SortPicker: View {
    let sort: UninstallAppSort
    let ascending: Bool
    let onSelect: (UninstallAppSort) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(UninstallAppSort.allCases, id: \.self) { field in
                segment(for: field)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: GargantuaRadius.small + 2)
                .fill(GargantuaColors.surface1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sort apps")
    }

    @ViewBuilder
    private func segment(for field: UninstallAppSort) -> some View {
        let isSelected = sort == field
        Button {
            onSelect(field)
        } label: {
            HStack(spacing: 4) {
                Text(field.label)
                    .font(GargantuaFonts.caption.weight(.medium))
                if isSelected {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundStyle(isSelected ? Color.white : GargantuaColors.ink2)
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .fill(isSelected ? GargantuaColors.accent : GargantuaColors.surface2)
            )
            .contentShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: field, isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(isSelected
              ? "\(field.label) — \(ascending ? "ascending" : "descending"). Click to flip."
              : "Sort by \(field.label.lowercased())")
    }

    private func accessibilityLabel(for field: UninstallAppSort, isSelected: Bool) -> String {
        guard isSelected else { return field.label }
        return "\(field.label), \(ascending ? "ascending" : "descending")"
    }
}
