import SwiftUI

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
                            UninstallPickerAppRow(
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
                .font(GargantuaFonts.body.italic())
                .foregroundStyle(GargantuaColors.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, GargantuaSpacing.space5)
        .padding(.top, GargantuaSpacing.space5)
        .padding(.bottom, GargantuaSpacing.space3)
    }

    private var toolbar: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            UninstallPickerSearchField(text: $viewModel.query)
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
                .frame(width: UninstallPickerColumn.checkboxLane, height: 1)

            UninstallPickerSortableColumnHeader(
                label: "Name",
                field: .name,
                currentField: viewModel.sort,
                ascending: viewModel.sortAscending,
                alignment: .leading,
                onTap: { viewModel.applySort(.name) }
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            UninstallPickerSortableColumnHeader(
                label: "Size",
                field: .size,
                currentField: viewModel.sort,
                ascending: viewModel.sortAscending,
                alignment: .trailing,
                onTap: { viewModel.applySort(.size) }
            )
            .frame(width: UninstallPickerColumn.size, alignment: .trailing)

            UninstallPickerSortableColumnHeader(
                label: "Last used",
                field: .lastUsed,
                currentField: viewModel.sort,
                ascending: viewModel.sortAscending,
                alignment: .trailing,
                onTap: { viewModel.applySort(.lastUsed) }
            )
            .frame(width: UninstallPickerColumn.lastUsed, alignment: .trailing)

            // No header for the orbit lane — it's a glance indicator, not a
            // sortable column. Reserve the width so row data lines up with
            // the lane below.
            Color.clear
                .frame(width: UninstallPickerColumn.orbit, height: 1)
        }
        .padding(.horizontal, GargantuaSpacing.space5)
        .padding(.vertical, GargantuaSpacing.space2)
        // Group the three sortable headers under one VoiceOver container so
        // the cluster reads as the picker's sort affordance, not three
        // isolated buttons. Mirrors what GargantuaSegmentedPicker conveyed.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sort apps")
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

    func accessibilityLabel(for app: AppInfo, categoryCount: Int?) -> String {
        var parts: [String] = [app.displayName ?? app.name]
        if let size = app.sizeOnDisk {
            parts.append(AlertItem.formatBytes(size))
        }
        if app.isRunning { parts.append("running") }
        if app.isSystemApp { parts.append("system app") }
        if let valid = app.signatureValid {
            parts.append(valid ? "signed" : "unsigned")
        }
        switch categoryCount {
        case nil:
            parts.append("scanning for leftovers")
        case 0?:
            parts.append("no leftover categories")
        case let count?:
            parts.append(count == 1 ? "1 leftover category" : "\(count) leftover categories")
        }
        return parts.joined(separator: ", ")
    }
}
