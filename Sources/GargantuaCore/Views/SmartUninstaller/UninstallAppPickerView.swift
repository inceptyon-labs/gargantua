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
                            Button {
                                Task { await viewModel.selectApp(app) }
                            } label: {
                                AppRow(app: app)
                            }
                            .buttonStyle(.plain)
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

            Picker("Sort", selection: $viewModel.sort) {
                ForEach(UninstallAppSort.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .accessibilityLabel("Sort apps")

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
        }
        .padding(.horizontal, GargantuaSpacing.space5)
        .padding(.vertical, GargantuaSpacing.space3)
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

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "app.dashed")
                .font(.system(size: 18))
                .foregroundStyle(GargantuaColors.ink3)
                .frame(width: 28)

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
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(GargantuaColors.ink4)
        }
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space5)
        .background(isHovered ? GargantuaColors.surface1 : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
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
