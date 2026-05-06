import SwiftUI

struct FileHealthFooter: View {
    let selectedResults: [ScanResult]
    let selectedBytes: Int64
    let onClearSelection: () -> Void
    let onSendToTrash: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            HStack(spacing: GargantuaSpacing.space3) {
                selectionSummary

                Spacer()

                if !selectedResults.isEmpty {
                    clearSelectionButton
                }

                sendToTrashButton
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space3)
            .background(GargantuaColors.surface1)
        }
    }

    @ViewBuilder
    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            if selectedResults.isEmpty {
                Text("No items selected")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink2)
                Text("Pick safe items above to send them to the Trash.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            } else {
                Text("\(selectedResults.count) item\(selectedResults.count == 1 ? "" : "s") selected")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                Text("\(AlertItem.formatBytes(selectedBytes)) ready for Trash")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
        }
    }

    private var clearSelectionButton: some View {
        Button(action: onClearSelection) {
            Text("Clear Selection")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink2)
                .padding(.horizontal, GargantuaSpacing.space4)
                .padding(.vertical, GargantuaSpacing.space2)
                .background(
                    RoundedRectangle(cornerRadius: GargantuaRadius.small, style: .continuous)
                        .fill(GargantuaColors.surface3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: GargantuaRadius.small, style: .continuous)
                        .stroke(GargantuaColors.borderEm, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
    }

    private var sendToTrashButton: some View {
        Button(action: onSendToTrash) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))

                if selectedResults.isEmpty {
                    Text("Send to Trash")
                        .font(GargantuaFonts.label)
                } else {
                    Text(
                        "Send \(selectedResults.count) item\(selectedResults.count == 1 ? "" : "s") "
                            + "· \(AlertItem.formatBytes(selectedBytes)) to Trash"
                    )
                    .font(GargantuaFonts.label)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(
                selectedResults.isEmpty
                    ? GargantuaColors.accent.opacity(0.4)
                    : GargantuaColors.accent
            )
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        }
        .buttonStyle(.plain)
        .disabled(selectedResults.isEmpty)
        .keyboardShortcut(.delete, modifiers: .command)
        .accessibilityLabel("Send selected File Health items to Trash")
    }
}
