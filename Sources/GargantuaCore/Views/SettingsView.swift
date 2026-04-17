import SwiftUI

/// Settings view with general preferences and AI model management.
///
/// Shows app settings (profile, retention, auto-scan) and an AI model section
/// with download progress, size info, and cancel/delete controls.
public struct SettingsView: View {
    let persistence: PersistenceController

    @StateObject private var downloadManager = ModelDownloadManager()
    @State private var settings: PersistedSettings?

    public init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space6) {
                headerView
                modelSection
                ScanRootsSettingsSection(
                    settings: settings,
                    persistence: persistence,
                    onSettingsChanged: { settings = $0 }
                )
                generalSection
            }
            .padding(GargantuaSpacing.space6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GargantuaColors.void_)
        .task {
            settings = try? persistence.fetchSettings()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        Text("Settings")
            .font(GargantuaFonts.heading)
            .foregroundStyle(GargantuaColors.ink)
    }

    // MARK: - AI Model Section

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            sectionHeader("AI Model")

            VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                // Model info row
                HStack(spacing: GargantuaSpacing.space3) {
                    Image(systemName: "cpu")
                        .font(.system(size: 20))
                        .foregroundStyle(GargantuaColors.accent)
                        .frame(width: 24, alignment: .center)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(downloadManager.modelInfo.name)
                            .font(GargantuaFonts.label)
                            .foregroundStyle(GargantuaColors.ink)

                        Text(modelStatusText)
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(modelStatusColor)
                    }

                    Spacer()

                    modelSizeLabel
                }

                // Progress bar (when downloading)
                if case .downloading(let progress, _) = downloadManager.state {
                    VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(GargantuaColors.surface3)

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(GargantuaColors.accent)
                                    .frame(width: max(4, geo.size.width * progress))
                            }
                        }
                        .frame(height: 6)

                        HStack {
                            Text("\(Int(progress * 100))%")
                                .font(GargantuaFonts.monoData)
                                .foregroundStyle(GargantuaColors.ink2)

                            Spacer()

                            if case .downloading(_, let bytesReceived) = downloadManager.state {
                                Text(ByteCountFormatter.string(fromByteCount: bytesReceived, countStyle: .file))
                                    .font(GargantuaFonts.monoData)
                                    .foregroundStyle(GargantuaColors.ink3)
                            }
                        }
                    }
                }

                // Error message
                if case .failed(let message) = downloadManager.state {
                    HStack(spacing: GargantuaSpacing.space2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(GargantuaColors.review)
                        Text(message)
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.review)
                            .lineLimit(2)
                    }
                }

                // Action buttons
                HStack(spacing: GargantuaSpacing.space3) {
                    switch downloadManager.state {
                    case .notDownloaded, .failed:
                        actionButton(
                            label: "Download Model",
                            icon: "arrow.down.circle.fill",
                            color: GargantuaColors.accent
                        ) {
                            downloadManager.startDownload()
                        }

                        Text("~\(downloadManager.formattedExpectedSize)")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink4)

                    case .downloading:
                        actionButton(
                            label: "Cancel",
                            icon: "xmark.circle.fill",
                            color: GargantuaColors.protected_
                        ) {
                            downloadManager.cancelDownload()
                        }

                    case .downloaded:
                        HStack(spacing: GargantuaSpacing.space2) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(GargantuaColors.safe)
                            Text("Ready")
                                .font(GargantuaFonts.label)
                                .foregroundStyle(GargantuaColors.safe)
                        }

                        Spacer()

                        actionButton(
                            label: "Delete",
                            icon: "trash",
                            color: GargantuaColors.protected_
                        ) {
                            downloadManager.deleteModel()
                        }
                    }
                }
            }
            .padding(GargantuaSpacing.space4)
            .background(GargantuaColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
    }

    // MARK: - General Section

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            sectionHeader("General")

            VStack(spacing: 1) {
                settingsRow(
                    icon: "person.2",
                    label: "Active Profile",
                    value: settings?.activeProfileID ?? "developer"
                )

                settingsRow(
                    icon: "clock",
                    label: "Audit Retention",
                    value: "\(settings?.retentionDays ?? 90) days"
                )

                settingsRow(
                    icon: "arrow.triangle.2.circlepath",
                    label: "Auto Scan",
                    value: (settings?.autoScanEnabled ?? false) ? "Enabled" : "Disabled"
                )

                if let lastScan = settings?.lastScanDate {
                    settingsRow(
                        icon: "calendar",
                        label: "Last Scan",
                        value: lastScan.formatted(date: .abbreviated, time: .shortened)
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(GargantuaFonts.label)
            .foregroundStyle(GargantuaColors.ink2)
    }

    private func settingsRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(GargantuaColors.ink3)
                .frame(width: 20, alignment: .center)

            Text(label)
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink)

            Spacer()

            Text(value)
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink2)
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
        .background(GargantuaColors.surface2)
    }

    private func actionButton(label: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(label)
                    .font(GargantuaFonts.label)
            }
            .foregroundStyle(color)
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        }
        .buttonStyle(.plain)
    }

    private var modelStatusText: String {
        switch downloadManager.state {
        case .notDownloaded: "Not downloaded"
        case .downloading: "Downloading…"
        case .downloaded: "Downloaded"
        case .failed: "Download failed"
        }
    }

    private var modelStatusColor: Color {
        switch downloadManager.state {
        case .notDownloaded: GargantuaColors.ink4
        case .downloading: GargantuaColors.accent
        case .downloaded: GargantuaColors.safe
        case .failed: GargantuaColors.review
        }
    }

    private var modelSizeLabel: some View {
        Group {
            if let size = downloadManager.formattedDownloadedSize {
                Text(size)
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)
            } else {
                Text(downloadManager.formattedExpectedSize)
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink4)
            }
        }
    }
}
