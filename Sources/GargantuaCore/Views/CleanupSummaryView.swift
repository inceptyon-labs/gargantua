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

    @State private var sort: SummarySort = .size
    @State private var succeededExpanded: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Sort options for the cleaned-item lists in the summary.
    public enum SummarySort: String, CaseIterable, Sendable {
        case name, size

        var label: String {
            switch self {
            case .name: "Name"
            case .size: "Size"
            }
        }
    }

    public init(
        result: CleanupResult,
        outcomeAccent: Color? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.result = result
        self.outcomeAccent = outcomeAccent
        self.onDismiss = onDismiss
    }

    /// Size descending with name as the deterministic tiebreaker so rows
    /// don't reshuffle between refreshes when sizes match. Name sort is
    /// case-insensitive so "AppCleaner" and "aria2" sort lexically.
    private func sorted(_ items: [CleanupItemResult]) -> [CleanupItemResult] {
        switch sort {
        case .name:
            items.sorted {
                $0.item.name.localizedCaseInsensitiveCompare($1.item.name) == .orderedAscending
            }
        case .size:
            items.sorted {
                if $0.item.size != $1.item.size {
                    return $0.item.size > $1.item.size
                }
                return $0.item.name.localizedCaseInsensitiveCompare($1.item.name) == .orderedAscending
            }
        }
    }

    /// True if there is at least one item (succeeded or failed) that the
    /// user could plausibly want to sort.
    private var hasSortableItems: Bool {
        !result.succeededItems.isEmpty || !result.failedItems.isEmpty
    }

    private func toggleSucceededExpanded() {
        if reduceMotion {
            succeededExpanded.toggle()
        } else {
            withAnimation(.easeOut(duration: 0.18)) { succeededExpanded.toggle() }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let outcomeAccent {
                Rectangle()
                    .fill(outcomeAccent)
                    .frame(height: 3)
                    .accessibilityHidden(true)
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
            HStack(spacing: GargantuaSpacing.space2) {
                Text(count == 1
                     ? "1 item \(result.cleanupMethod.summaryActionText)"
                     : "\(count) items \(result.cleanupMethod.summaryActionText)")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink2)

                Spacer()

                // Sort picker lives here (stable position) whenever there is
                // anything to sort — either expanded succeeded items, or any
                // failed items (which are always rendered below). Keeping it
                // anchored prevents it from jumping into the failure header
                // when succeeded items are collapsed.
                if hasSortableItems, succeededExpanded || !result.failedItems.isEmpty {
                    sortPicker
                }

                if count > 0 {
                    Button(action: toggleSucceededExpanded) {
                        HStack(spacing: GargantuaSpacing.space1) {
                            Image(systemName: succeededExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .accessibilityHidden(true)
                            Text(succeededExpanded ? "Hide items" : "Show items")
                                .font(GargantuaFonts.caption)
                        }
                        .foregroundStyle(GargantuaColors.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(succeededExpanded ? "Hide cleaned items" : "Show cleaned items")
                }
            }

            if succeededExpanded, !result.succeededItems.isEmpty {
                itemList(sorted(result.succeededItems), foreground: GargantuaColors.ink)
            }
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

                Spacer()
            }

            ForEach(sorted(result.failedItems), id: \.item.id) { failed in
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

    // MARK: - Shared item list

    private var sortPicker: some View {
        Picker("Sort", selection: $sort) {
            ForEach(SummarySort.allCases, id: \.self) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 140)
        .controlSize(.small)
        .accessibilityLabel("Sort cleanup items")
    }

    private func itemList(_ items: [CleanupItemResult], foreground: Color) -> some View {
        // Cap the inline list height so an app like Xcode with hundreds of
        // remnants can't push the footer off-screen; scroll inside the card.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(items, id: \.item.id) { entry in
                    HStack(spacing: GargantuaSpacing.space2) {
                        Text(entry.item.name)
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(foreground)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: GargantuaSpacing.space2)

                        // Size text gets layout priority so a long app name
                        // truncates before the byte count does.
                        Text(AlertItem.formatBytes(entry.item.size))
                            .font(GargantuaFonts.monoData)
                            .foregroundStyle(GargantuaColors.ink3)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        .frame(maxHeight: 180)
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
