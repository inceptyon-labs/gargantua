import SwiftUI

extension ScanBucketListView {
    /// Single condensed row replacing the previous summary bar + RESULTS card +
    /// REVIEW REQUIRED panel + Refine disclosure stack. Counts and the grouping
    /// picker stay visible at all times; the safety legend, refine field, and
    /// per-bucket "AI Review" chip live behind progressive disclosure so the
    /// list starts as close to the top as possible.
    var controlsRow: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Text("RESULTS")
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(GargantuaColors.ink4)

            Text(controlsSummary)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink2)
                .lineLimit(1)

            Spacer(minLength: GargantuaSpacing.space3)

            ScanGroupingPicker(mode: $groupingMode)
                .onChange(of: groupingMode) { _, _ in
                    expandedGroupIDs = Set(groups.map(\.id))
                    focusedItemID = nil
                }

            if hasRefinementTools {
                controlIconButton(
                    systemImage: "line.3.horizontal.decrease.circle",
                    isActive: activeFilter != nil || showsRefineControls,
                    accessibility: "Refine results",
                    help: activeFilter != nil ? "Filter active — tap to edit or clear" : "Search and filter results"
                ) {
                    showsRefineControls.toggle()
                }
            }

            controlIconButton(
                systemImage: "questionmark.circle",
                isActive: showsHelpLegend,
                accessibility: "Safety legend",
                help: "What do Safe, Review, and Protected mean?"
            ) {
                showsHelpLegend.toggle()
            }
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(GargantuaColors.surface2)
    }

    /// Compact summary in the controls row. When selection equals total, we
    /// drop the redundant "selected" qualifier; when it differs, both numbers
    /// are shown so the user always has the scan-total context (the previous
    /// "X GB selected" alone hid whether that was X of X or X of much-more).
    private var controlsSummary: String {
        let count = displayedResults.count
        let countText = "\(count) item\(count == 1 ? "" : "s")"
        let totalBytes = displayedResults.reduce(Int64(0)) { $0 + $1.size }
        let totalText = AlertItem.formatBytes(totalBytes)
        let durationText = formattedScanDuration

        if reclaimableBytes == totalBytes {
            return "\(countText) · \(totalText) · \(durationText)"
        }
        let selectedText = AlertItem.formatBytes(reclaimableBytes)
        return "\(countText) · \(totalText) total · \(selectedText) selected · \(durationText)"
    }

    /// Three-line legend revealing what Safe / Review / Protected actually
    /// mean. Inline panel rather than a tooltip so the explanation reads on a
    /// trackpad without a hover gesture, which `mac` users on small Macs miss.
    var helpLegendPanel: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            legendRow(
                color: GargantuaColors.safe,
                label: "Safe",
                detail: "Pre-selected, low-risk to remove. Caches, logs, and temp files."
            )
            legendRow(
                color: GargantuaColors.review,
                label: "Review",
                detail: "Flagged for a second look. Open AI Review on the bucket to summarize before you commit."
            )
            legendRow(
                color: GargantuaColors.protected_,
                label: "Protected",
                detail: "Locked. Removing these can break apps or system state."
            )
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
        .background(GargantuaColors.surface1)
    }

    private func legendRow(color: Color, label: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space2) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink)
                .frame(width: 64, alignment: .leading)
            Text(detail)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func controlIconButton(
        systemImage: String,
        isActive: Bool,
        accessibility: String,
        help helpText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? GargantuaColors.accent : GargantuaColors.ink3)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: GargantuaRadius.small, style: .continuous)
                        .fill(isActive ? GargantuaColors.accent.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
        .help(helpText)
    }
}
