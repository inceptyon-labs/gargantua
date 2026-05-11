import AppKit
import SwiftUI

extension CleanupSummaryView {
    // MARK: - Narrative loading

    var narrativeLoadingSection: some View {
        HStack(alignment: .center, spacing: GargantuaSpacing.space2) {
            AccretionDiskView(activityRate: 0, size: 14, color: GargantuaColors.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Composing summary…")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
                if didShowFirstWarmupAtStart {
                    Text("Compiling shaders for first use…")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(GargantuaSpacing.space4)
    }

    // MARK: - Header

    var header: some View {
        let outcome = Self.outcome(for: result)
        let icon: String
        let iconColor: Color
        let title: String
        switch outcome {
        case .complete:
            icon = "checkmark.circle.fill"
            iconColor = GargantuaColors.safe
            title = "Cleanup Complete"
        case .partial:
            icon = "exclamationmark.triangle.fill"
            iconColor = GargantuaColors.review
            title = "Cleanup Partially Complete"
        case .failed:
            icon = "xmark.octagon.fill"
            iconColor = GargantuaColors.protected_
            title = "Cleanup Failed"
        }

        return HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                if outcome != .failed {
                    Text("\(AlertItem.formatBytes(result.totalFreed)) freed")
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.safe)
                }
            }

            Spacer()
        }
        .padding(GargantuaSpacing.space4)
    }

    // MARK: - Success Section

    var successSection: some View {
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
                // anything sortable visible — always, if there are any items.
                // The picker drives both the succeeded list (when expanded)
                // and the always-rendered failure list below.
                if hasSortableItems {
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

    var failureSection: some View {
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

    var sortPicker: some View {
        GargantuaSegmentedPicker(
            selection: $sort,
            options: SummarySort.allCases.map { (value: $0, label: $0.label) },
            accessibilityLabel: "Sort cleanup items"
        )
        .frame(width: 140)
    }

    func itemList(_ items: [CleanupItemResult], foreground: Color) -> some View {
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

    // MARK: - Helpers

    /// Size descending with name as the deterministic tiebreaker so rows
    /// don't reshuffle between refreshes when sizes match. Name sort is
    /// case-insensitive so "AppCleaner" and "aria2" sort lexically.
    func sorted(_ items: [CleanupItemResult]) -> [CleanupItemResult] {
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
    var hasSortableItems: Bool {
        !result.succeededItems.isEmpty || !result.failedItems.isEmpty
    }

    func toggleSucceededExpanded() {
        if reduceMotion {
            succeededExpanded.toggle()
        } else {
            withAnimation(.easeOut(duration: 0.18)) { succeededExpanded.toggle() }
        }
    }

    // MARK: - Footer Actions

    var footerActions: some View {
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

    func revealTrash() {
        TrashRevealer().revealCleanupResult(result)
    }

    func openAuditTrail() {
        let logFile = AuditWriter().logFile
        if FileManager.default.fileExists(atPath: logFile.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logFile])
        }
    }
}
