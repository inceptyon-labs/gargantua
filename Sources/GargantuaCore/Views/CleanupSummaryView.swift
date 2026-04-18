import AppKit
import SwiftUI

/// Post-clean summary showing freed space, item status, and undo option.
///
/// Displayed after a cleanup operation completes. Shows:
/// - Total items cleaned and bytes freed
/// - Failed items (if partial failure)
/// - "Open Audit Trail" link
/// - "Reveal Trash" undo button when applicable
public struct CleanupSummaryView: View {
    let result: CleanupResult
    let outcomeAccent: Color?
    let onDismiss: () -> Void

    public init(
        result: CleanupResult,
        outcomeAccent: Color? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.result = result
        self.outcomeAccent = outcomeAccent
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let outcomeAccent {
                Rectangle()
                    .fill(outcomeAccent)
                    .frame(height: 3)
            }

            header

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            successSection

            if !result.failedItems.isEmpty {
                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)

                failureSection
            }

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            footerActions
        }
        .background(GargantuaColors.surface2)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.border, lineWidth: 1)
        )
        .frame(maxWidth: 480)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: result.allSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(result.allSucceeded ? GargantuaColors.safe : GargantuaColors.review)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.allSucceeded ? "Cleanup Complete" : "Cleanup Partially Complete")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Text("\(AlertItem.formatBytes(result.totalFreed)) freed")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.safe)
            }

            Spacer()
        }
        .padding(GargantuaSpacing.space4)
    }

    // MARK: - Success Section

    private var successSection: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            let count = result.succeededItems.count
            Text(count == 1
                 ? "1 item \(result.cleanupMethod.summaryActionText)"
                 : "\(count) items \(result.cleanupMethod.summaryActionText)")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink2)
        }
        .padding(GargantuaSpacing.space4)
    }

    // MARK: - Failure Section

    private var failureSection: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            let count = result.failedItems.count
            HStack(spacing: GargantuaSpacing.space2) {
                Circle()
                    .fill(GargantuaColors.protected_)
                    .frame(width: 6, height: 6)
                Text(count == 1 ? "1 item failed" : "\(count) items failed")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.protected_)
            }

            ForEach(result.failedItems, id: \.item.id) { failed in
                HStack(spacing: GargantuaSpacing.space2) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failed.item.name)
                            .font(GargantuaFonts.label)
                            .foregroundStyle(GargantuaColors.ink)
                            .lineLimit(1)

                        if let error = failed.error {
                            Text(error)
                                .font(GargantuaFonts.caption)
                                .foregroundStyle(GargantuaColors.ink3)
                                .lineLimit(2)
                        }
                    }

                    Spacer()

                    Text(AlertItem.formatBytes(failed.item.size))
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink3)
                }
                .padding(.vertical, GargantuaSpacing.space1)
            }
        }
        .padding(GargantuaSpacing.space4)
    }

    // MARK: - Footer Actions

    private var footerActions: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            // Audit trail link
            Button(action: openAuditTrail) {
                HStack(spacing: GargantuaSpacing.space1) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                    Text("View Audit Trail")
                        .font(GargantuaFonts.caption)
                }
                .foregroundStyle(GargantuaColors.accent)
            }
            .buttonStyle(.plain)

            Spacer()

            if result.cleanupMethod == .trash {
                // Undo - reveal Trash
                Button(action: revealTrash) {
                    HStack(spacing: GargantuaSpacing.space1) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                        Text("Reveal Trash")
                            .font(GargantuaFonts.label)
                    }
                    .foregroundStyle(GargantuaColors.ink)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .padding(.horizontal, GargantuaSpacing.space3)
                    .background(Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                    .overlay(
                        RoundedRectangle(cornerRadius: GargantuaRadius.small)
                            .stroke(GargantuaColors.borderEm, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            // Done
            Button(action: onDismiss) {
                Text("Done")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(.white)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .background(GargantuaColors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
        }
        .padding(GargantuaSpacing.space4)
    }

    // MARK: - Actions

    private func revealTrash() {
        TrashRevealer().revealCleanupResult(result)
    }

    private func openAuditTrail() {
        let logFile = AuditWriter().logFile
        if FileManager.default.fileExists(atPath: logFile.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logFile])
        }
    }
}
