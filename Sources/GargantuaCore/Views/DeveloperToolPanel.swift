import Foundation
import SwiftUI

/// One per-tool card inside ``DeveloperToolsView`` — header, command preview,
/// and the list of dry-run rows returned by ``DeveloperToolPreviewAdapter``.
///
/// Scoped to the file that owns the surrounding scan state. Intentionally
/// lives outside `DeveloperToolsView.swift` only to keep that file under the
/// 400-line soft limit; the panel is otherwise a private implementation
/// detail of the Developer Tools screen.
struct DeveloperToolPanel: View {
    let availability: DeveloperToolAvailability
    let preview: DeveloperToolsView.PreviewState
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            toolHeader
            Rectangle()
                .fill(GargantuaColors.borderSoft)
                .frame(height: 1)

            switch preview {
            case .loading:
                HStack(spacing: GargantuaSpacing.space2) {
                    ProgressView().controlSize(.small)
                    Text("Running preview…")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            case .loaded(let p):
                previewBody(p)
            case .failed(let message):
                failureBody(message: message)
            }
        }
        .padding(GargantuaSpacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .fill(GargantuaColors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.border, lineWidth: 1)
        )
    }

    private var toolHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space2) {
            Image(systemName: icon(for: availability.tool))
                .foregroundStyle(GargantuaColors.ink2)
                .frame(width: 18, alignment: .center)
            Text(availability.tool.displayName)
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)
            if let version = availability.version {
                Text(version)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(1)
            }
            Spacer()
            if case .loaded(let p) = preview, p.reclaimableBytes > 0 {
                Text("\(Self.formatBytes(p.reclaimableBytes)) reclaimable")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink)
            }
        }
    }

    private func previewBody(_ preview: DeveloperToolPreview) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            commandRow(preview.commandPreview)

            if preview.items.isEmpty {
                Text("Nothing to clean up.")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink3)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(preview.items) { item in
                        previewRow(item)
                        if item.id != preview.items.last?.id {
                            Rectangle()
                                .fill(GargantuaColors.borderSoft)
                                .frame(height: 1)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: GargantuaRadius.small)
                        .fill(GargantuaColors.surface1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: GargantuaRadius.small)
                        .stroke(GargantuaColors.borderSoft, lineWidth: 1)
                )
            }
        }
    }

    private func commandRow(_ command: [String]) -> some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "terminal")
                .foregroundStyle(GargantuaColors.ink4)
            Text(command.joined(separator: " "))
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(GargantuaColors.ink3)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .fill(GargantuaColors.surface3)
        )
    }

    private func previewRow(_ item: DeveloperToolPreviewItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space3) {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                Text(item.title)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = item.detail {
                    Text(detail)
                        .font(GargantuaFonts.monoPath)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: GargantuaSpacing.space3)
            if let bytes = item.reclaimableBytes {
                Text(Self.formatBytes(bytes))
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)
            } else {
                Text("—")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink4)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
    }

    private func failureBody(message: String) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(GargantuaColors.review)
                Text("Preview failed")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
            }
            Text(message)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .lineLimit(5)
                .multilineTextAlignment(.leading)

            Button {
                onRetry()
            } label: {
                Text("Try again")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                    .padding(.horizontal, GargantuaSpacing.space3)
                    .padding(.vertical, GargantuaSpacing.space1)
                    .background(
                        RoundedRectangle(cornerRadius: GargantuaRadius.small)
                            .fill(GargantuaColors.surface3)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private func icon(for tool: DeveloperTool) -> String {
        switch tool {
        case .homebrew: "mug"
        case .docker: "shippingbox"
        }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
