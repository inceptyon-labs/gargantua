import AppKit
import SwiftUI

/// One installed app in the App Updates list.
struct AppReleaseRowView: View {
    let row: AppReleaseRow
    let installPhase: AppReleaseInstallPhase?
    /// A check is running; updating waits so the two can't overwrite each other.
    let isChecking: Bool
    let message: AppReleaseRowMessage?
    let onUpdate: () -> Void
    let onIgnore: () -> Void
    let onStopIgnoring: () -> Void
    let onSkip: (String) -> Void
    let onStopSkipping: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            HStack(spacing: GargantuaSpacing.space3) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: row.app.url.path))
                    .resizable()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.app.name)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                        .lineLimit(1)
                    Text(row.app.bundleID)
                        .font(GargantuaFonts.monoPath)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: GargantuaSpacing.space3)

                HStack(spacing: GargantuaSpacing.space3) {
                    versionColumn
                        .frame(width: Self.versionWidth, alignment: .trailing)

                    HStack(spacing: GargantuaSpacing.space1) {
                        ForEach(row.sources, id: \.self) { source in
                            pill(source.label, color: GargantuaColors.ink3)
                        }
                    }
                    .frame(width: Self.sourceWidth, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(versionAccessibilityLabel)

                action
                    .frame(width: Self.actionWidth, alignment: .trailing)
            }

            detailLine

            if let message {
                messageLine(message)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(GargantuaColors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        .opacity(isDimmed ? 0.6 : 1)
        .contextMenu { contextMenu }
    }

    // MARK: - Pieces

    private static let versionWidth: CGFloat = 150
    private static let sourceWidth: CGFloat = 124
    private static let actionWidth: CGFloat = 112
    private static let barHeight: CGFloat = 3
    private static let spinnerSize: CGFloat = 16
    private static let topLineHeight: CGFloat = 16

    /// A known-length download uses the whole column for the size label; every
    /// other phase puts the label beside the spinner.
    @ViewBuilder
    private func installTopLine(_ phase: AppReleaseInstallPhase) -> some View {
        if phase.downloadFraction != nil {
            installLabel(phase.label, width: Self.actionWidth)
        } else {
            HStack(spacing: GargantuaSpacing.space2) {
                AccretionDiskView(activityRate: 18, size: Self.spinnerSize, color: GargantuaColors.accretion)
                installLabel(
                    phase.label,
                    width: Self.actionWidth - Self.spinnerSize - GargantuaSpacing.space2
                )
            }
            .frame(height: Self.topLineHeight)
        }
    }

    private func installLabel(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(GargantuaFonts.caption.monospacedDigit())
            .foregroundStyle(GargantuaColors.ink2)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: width, height: Self.topLineHeight, alignment: .trailing)
    }

    private var versionAccessibilityLabel: String {
        var label = row.app.version.description
        if let candidate = row.availableCandidate { label += " to \(candidate.displayVersion)" }
        if !row.sources.isEmpty { label += ", from " + row.sources.map(\.label).joined(separator: ", ") }
        return label
    }

    private var isDimmed: Bool {
        guard message == nil else { return false }
        switch row.status {
        case .upToDate, .untracked, .ignored, .skippedVersion: return true
        case .available, .failed: return false
        }
    }

    private var versionColumn: some View {
        HStack(spacing: GargantuaSpacing.space1) {
            Text(row.app.version.description)
                .foregroundStyle(GargantuaColors.ink2)
            if let candidate = row.availableCandidate {
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(GargantuaColors.ink4)
                Text(candidate.displayVersion)
                    .foregroundStyle(GargantuaColors.ink)
            }
        }
        .font(GargantuaFonts.monoData)
        .lineLimit(1)
    }

    @ViewBuilder
    private var action: some View {
        if let installPhase {
            VStack(alignment: .trailing, spacing: 2) {
                installTopLine(installPhase)
                Capsule()
                    .fill(GargantuaColors.borderEm)
                    .frame(height: Self.barHeight)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(GargantuaColors.accretion)
                                .frame(width: proxy.size.width * (installPhase.downloadFraction ?? 0))
                        }
                    }
                    .opacity(installPhase.downloadFraction == nil ? 0 : 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Installing \(row.app.name)")
            .accessibilityValue(installPhase.accessibilityValue)
        } else {
            switch row.status {
            case .available(_, let strategy):
                availableAction(strategy)
            case .upToDate:
                statusText("Up to date")
            case .ignored:
                GargantuaButton("Stop ignoring", action: onStopIgnoring)
                    .accessibilityLabel("Stop ignoring \(row.app.name)")
            case .skippedVersion(let version):
                GargantuaButton("Stop skipping", action: onStopSkipping)
                    .help("Skipping \(version)")
                    .accessibilityLabel("Stop skipping \(version) of \(row.app.name)")
            case .untracked:
                statusText("Not tracked")
            case .failed:
                statusText("Couldn't check")
            }
        }
    }

    @ViewBuilder
    private func availableAction(_ strategy: AppReleaseInstallStrategy) -> some View {
        switch strategy {
        case .inPlace, .brewUpgrade:
            GargantuaButton("Update", tone: .ghost(GargantuaColors.accent), isDisabled: isChecking, action: onUpdate)
                .accessibilityLabel("Update \(row.app.name)")
        case .openAppStore(let url):
            GargantuaButton("App Store") { NSWorkspace.shared.open(url) }
                .accessibilityLabel("Open \(row.app.name) in the App Store")
        case .linkOnly(let url, let reason):
            if let url {
                GargantuaButton("Download") { NSWorkspace.shared.open(url) }
                    .help(reason.explanation)
                    .accessibilityLabel("Download \(row.app.name)")
            } else {
                statusText("Manual").help(reason.explanation)
            }
        }
    }

    @ViewBuilder
    private var detailLine: some View {
        if let text = detailText {
            Text(text)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 28 + GargantuaSpacing.space3)
        }
    }

    private var detailText: String? {
        switch row.status {
        case .available(_, .linkOnly(_, let reason)): reason.explanation
        case .failed(let reason): reason
        case .skippedVersion(let version): "Skipped version \(version)"
        default: nil
        }
    }

    private func messageLine(_ message: AppReleaseRowMessage) -> some View {
        let (text, color): (String, Color) = switch message {
        case .installed(let text): (text, GargantuaColors.safe)
        case .installedWithWarning(let text): (text, GargantuaColors.review)
        case .failed(let text): (text, GargantuaColors.protected_)
        }
        return Text(text)
            .font(GargantuaFonts.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 28 + GargantuaSpacing.space3)
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(GargantuaFonts.caption)
            .foregroundStyle(GargantuaColors.ink3)
    }

    private func pill(_ label: String, color: Color) -> some View {
        Text(label)
            .font(GargantuaFonts.caption)
            .foregroundStyle(color)
            .padding(.vertical, 1)
            .padding(.horizontal, 6)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenu: some View {
        switch row.status {
        case .ignored:
            Button("Stop ignoring", action: onStopIgnoring)
        case .skippedVersion:
            Button("Stop skipping this version", action: onStopSkipping)
        default:
            Button("Ignore app", action: onIgnore)
        }
        if let candidate = row.availableCandidate {
            Button("Skip this version") { onSkip(candidate.displayVersion) }
        }
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([row.app.url])
        }
        if let notes = row.availableCandidate?.releaseNotesURL {
            Button("Open release notes") { NSWorkspace.shared.open(notes) }
        }
    }
}

extension AppReleaseInstallPhase {
    var label: String {
        switch self {
        case .downloading(let received, let expected): Self.downloadLabel(received: received, expected: expected)
        case .verifying: "Verifying…"
        case .quitting: "Quitting…"
        case .installing: "Installing…"
        case .relaunching: "Relaunching…"
        case .upgradingWithHomebrew: "Upgrading…"
        }
    }
}

extension AppReleaseInstallPhase {
    /// 0...1 while a download of known length is running.
    var downloadFraction: Double? {
        guard case .downloading(let received, let expected) = self, let expected, expected > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(expected)))
    }

    var accessibilityValue: String {
        guard let fraction = downloadFraction else { return label }
        return "Downloading, \(Int(fraction * 100)) percent"
    }

    static func downloadLabel(received: Int64, expected: Int64?) -> String {
        guard received > 0 else { return "Downloading…" }
        let got = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        guard let expected, expected > 0 else { return "\(got) downloaded" }
        let total = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
        // One unit at the end saves width: "12.3 of 85.0 MB".
        if let gotSplit = got.lastIndex(of: " "), let totalSplit = total.lastIndex(of: " "),
           got[got.index(after: gotSplit)...] == total[total.index(after: totalSplit)...] {
            return "\(got[..<gotSplit]) of \(total)"
        }
        return "\(got) of \(total)"
    }
}
