import SwiftUI

extension OrganizerStagedPreviewView {
    @ViewBuilder
    func appliedState(summary: OrganizerExecutionResult) -> some View {
        OrganizerPostApplyView(session: session, summary: summary)
    }

    @ViewBuilder
    func undoneState(summary: OrganizerUndoResult) -> some View {
        VStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(GargantuaColors.ink2)
            Text("Reversed \(summary.reversed.count) move\(summary.reversed.count == 1 ? "" : "s")")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)
            if let note = undoNote(summary) {
                Text(note)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            if !summary.failed.isEmpty {
                undoFailureList(summary.failed)
            }
            Button("Back") { session.reset() }
                .buttonStyle(.plain)
                .font(GargantuaFonts.label)
                .foregroundStyle(.white)
                .padding(.horizontal, GargantuaSpacing.space3)
                .padding(.vertical, GargantuaSpacing.space2)
                .background(GargantuaColors.accent)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                .padding(.top, GargantuaSpacing.space2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Files that couldn't come back, and a Cancel that stopped early, are
    /// spelled out rather than folded into the reversed count.
    private func undoNote(_ summary: OrganizerUndoResult) -> String? {
        var parts: [String] = []
        if !summary.missing.isEmpty {
            let count = summary.missing.count
            let files = count == 1 ? "1 file was" : "\(count) files were"
            parts.append("\(files) no longer where Apply put them (trashed or moved since), so they couldn't come back.")
        }
        if !summary.failed.isEmpty {
            let count = summary.failed.count
            parts.append("\(count) couldn't be moved back. Undo again to retry them.")
        }
        if summary.wasCancelled {
            parts.append("Stopped before every move was reversed. Undo again to finish.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func undoFailureList(_ failures: [OrganizerMoveFailure]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                ForEach(failures, id: \.self) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.sourceURL.lastPathComponent)
                            .font(GargantuaFonts.monoPath)
                            .foregroundStyle(GargantuaColors.ink2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(failure.reason)
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.review)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(GargantuaSpacing.space3)
        }
        .frame(maxWidth: 480, maxHeight: 160)
        .background(GargantuaColors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }

    @ViewBuilder
    func failedState(message: String) -> some View {
        VStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(GargantuaColors.review)
            Text("Couldn't complete")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)
            Text(message)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Back") { session.reset() }
                .buttonStyle(.plain)
                .font(GargantuaFonts.label)
                .foregroundStyle(.white)
                .padding(.horizontal, GargantuaSpacing.space3)
                .padding(.vertical, GargantuaSpacing.space2)
                .background(GargantuaColors.accent)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                .padding(.top, GargantuaSpacing.space2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(GargantuaSpacing.space5)
    }
}
