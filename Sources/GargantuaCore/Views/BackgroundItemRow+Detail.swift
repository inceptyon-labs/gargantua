import AppKit
import SwiftUI

extension BackgroundItemRow {
    var expandedDetail: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            Rectangle()
                .fill(GargantuaColors.borderSoft)
                .frame(height: 1)
                .padding(.horizontal, GargantuaSpacing.space3)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
                detailRow(label: "Label", value: item.label)
                if let exe = item.executablePath {
                    detailRow(label: "Executable", value: exe, mono: true)
                }
                if let identity = item.identity {
                    if let team = identity.teamIdentifier {
                        detailRow(label: "Team ID", value: team, mono: true)
                    }
                    if let signing = identity.signingIdentity {
                        detailRow(label: "Signed by", value: signing)
                    }
                    if let bundle = identity.bundleIdentifier {
                        detailRow(label: "Bundle ID", value: bundle, mono: true)
                    }
                    if let version = identity.bundleShortVersion {
                        detailRow(label: "Version", value: version)
                    }
                    detailRow(label: "Vendor", value: vendorLabel(identity.vendor))
                    if let valid = identity.signatureValid {
                        detailRow(
                            label: "Signature",
                            value: valid ? "Valid" : "Invalid"
                        )
                    }
                    if let notarized = identity.isNotarized {
                        detailRow(
                            label: "Notarized",
                            value: notarized ? "Yes" : "No"
                        )
                    }
                }
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space2)
            .padding(.leading, GargantuaSpacing.space1)
        }
    }

    private func detailRow(label: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            Text(label)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .frame(width: 92, alignment: .leading)

            Text(value)
                .font(mono ? GargantuaFonts.monoData : GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    var contextMenu: some View {
        if item.source == .loginItem, let onOpenLoginSettings {
            Button("Open Login Items in System Settings") { onOpenLoginSettings() }
        }
        if item.plistPath != nil {
            Button("Reveal plist in Finder") { onReveal() }
        }
        if let exe = item.executablePath, !exe.isEmpty {
            Button("Reveal executable in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: exe)])
            }
        }
        if let onExplain {
            Button("Explain with AI") { onExplain() }
        }
        if let onAction, supportsActions {
            Divider()
            if canDisable {
                Button("Disable") { onAction(.disable) }
            }
            if canEnable {
                Button("Re-enable") { onAction(.enable) }
            }
            if canDelete {
                Button("Move plist to Trash") { onAction(.delete) }
            }
        }
        Button("Copy label") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.label, forType: .string)
        }
    }
}
