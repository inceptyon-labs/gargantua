import SwiftUI

/// Post-apply structure view. Replaces the previous generic "Moved N
/// files" summary with a row per new subfolder showing file count,
/// total size, and a Move-to-Trash action. Bridges the organizer
/// surface into the natural follow-up moment — once the folder is
/// organized, the user can see at a glance what they don't need.
struct OrganizerPostApplyView: View {
    @ObservedObject var session: OrganizerSessionState
    let summary: OrganizerExecutionResult

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
                    Text("NEW STRUCTURE")
                        .font(GargantuaFonts.sectionLabel)
                        .tracking(0.8)
                        .foregroundStyle(GargantuaColors.ink4)
                        .padding(.bottom, GargantuaSpacing.space1)

                    if let plans = session.proposal?.plans, !plans.isEmpty {
                        ForEach(plans) { plan in
                            folderRow(for: plan)
                        }
                    } else {
                        Text("No new subfolders were created.")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink3)
                    }
                }
                .padding(GargantuaSpacing.space4)
            }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(GargantuaColors.safe)

            VStack(alignment: .leading, spacing: 2) {
                Text("Moved \(summary.totalMoved) file\(summary.totalMoved == 1 ? "" : "s")")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)
                if !summary.skipped.isEmpty || !summary.failed.isEmpty {
                    Text(detailLine)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }
            Spacer()
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
        .background(GargantuaColors.surface2)
    }

    private var detailLine: String {
        var parts: [String] = []
        if !summary.skipped.isEmpty { parts.append("\(summary.skipped.count) skipped") }
        if !summary.failed.isEmpty { parts.append("\(summary.failed.count) failed") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Row

    @ViewBuilder
    private func folderRow(for plan: OrganizationPlan) -> some View {
        let folderURL = destinationFolderURL(for: plan)
        let key = folderURL.standardizedFileURL.path
        let trashed = session.trashedFolderPaths.contains(key)
        let error = session.folderTrashErrors[key]
        // v1 shows file count only; per-move byte sizes aren't carried
        // on MoveAction so adding a size column would mean threading
        // the original listing through. Defer.

        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            HStack(spacing: GargantuaSpacing.space3) {
                Image(systemName: trashed ? "trash" : "folder")
                    .font(.system(size: 16))
                    .foregroundStyle(trashed ? GargantuaColors.ink4 : GargantuaColors.accent)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.name)
                        .font(GargantuaFonts.label)
                        .strikethrough(trashed)
                        .foregroundStyle(trashed ? GargantuaColors.ink4 : GargantuaColors.ink)
                    Text("\(plan.moves.count) file\(plan.moves.count == 1 ? "" : "s")")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }

                Spacer()

                if trashed {
                    Text("In Trash")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                        .padding(.horizontal, GargantuaSpacing.space2)
                        .padding(.vertical, 4)
                        .background(GargantuaColors.surface3)
                        .clipShape(Capsule())
                } else {
                    Button("Move to Trash") { session.trashSubfolder(at: folderURL) }
                        .buttonStyle(.plain)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.review)
                        .padding(.horizontal, GargantuaSpacing.space2)
                        .padding(.vertical, 4)
                        .overlay(
                            Capsule().stroke(GargantuaColors.review, lineWidth: 1)
                        )
                }
            }

            if let error {
                HStack(spacing: GargantuaSpacing.space1) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(GargantuaColors.review)
                    Text(error)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
                .padding(.leading, 30)
            }
        }
        .padding(GargantuaSpacing.space3)
        .background(GargantuaColors.surface1)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.borderSoft, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
    }

    private func destinationFolderURL(for plan: OrganizationPlan) -> URL {
        // Use the first move's destination parent — every move in a
        // plan lands in the same subfolder (the validator guarantees
        // this via the no-flat-in-root + same-root rules).
        if let firstMove = plan.moves.first {
            return firstMove.destinationURL.deletingLastPathComponent()
        }
        // Fallback: build from source folder + plan name. Should be
        // unreachable when a proposal has any moves.
        let source = session.proposal?.sourceFolder ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return source.appendingPathComponent(plan.name, isDirectory: true)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Button("Undo") { session.undoLastApply() }
                .buttonStyle(.plain)
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink2)
                .padding(.horizontal, GargantuaSpacing.space3)
                .padding(.vertical, GargantuaSpacing.space2)
                .background(GargantuaColors.surface2)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))

            if session.trashedFolderPaths.isEmpty == false {
                HStack(spacing: GargantuaSpacing.space1) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                    Text("Trashed folders are recovered from Finder's Trash, not by Undo.")
                        .font(GargantuaFonts.caption)
                        .lineLimit(2)
                }
                .foregroundStyle(GargantuaColors.ink3)
                .padding(.leading, GargantuaSpacing.space2)
            }

            Spacer()

            Button("Done") { session.reset() }
                .buttonStyle(.plain)
                .font(GargantuaFonts.label)
                .foregroundStyle(.white)
                .padding(.horizontal, GargantuaSpacing.space4)
                .padding(.vertical, GargantuaSpacing.space2)
                .background(GargantuaColors.accent)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
        .background(GargantuaColors.surface2)
    }
}
