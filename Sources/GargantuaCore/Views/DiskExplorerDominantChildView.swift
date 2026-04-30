import SwiftUI

/// Alternate layout for folders where one child is so large the treemap
/// would just show a giant rectangle with sliver-thin neighbors. Renders
/// the dominant child as a hero card with a Drill In affordance and the
/// remaining children as a compact size-bar list below.
struct DiskExplorerDominantChildView: View {
    let dominant: DirectoryItem
    let items: [DirectoryItem]
    let maxSize: Int64
    let onDrillDown: (DirectoryItem) -> Void

    private var total: Int64 {
        items.reduce(0) { $0 + max($1.size, 0) }
    }

    private var fraction: Double {
        total > 0 ? Double(dominant.size) / Double(total) : 0
    }

    private var percent: Int {
        Int((fraction * 100).rounded())
    }

    private var remaining: [DirectoryItem] {
        items.filter { $0.id != dominant.id }
    }

    private var canDrillIn: Bool {
        !dominant.isPermissionDenied
            && !dominant.isFilesAggregate
            && !dominant.isSizing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            header
            heroCard
            otherItems
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GargantuaSpacing.space6)
        .padding(.bottom, GargantuaSpacing.space6)
    }

    private var header: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "scope")
                .font(.system(size: 14))
                .foregroundStyle(GargantuaColors.review)
            Text("One folder dominates this directory")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink2)
            Spacer()
        }
    }

    private var heroCard: some View {
        Button {
            if canDrillIn { onDrillDown(dominant) }
        } label: {
            HStack(spacing: GargantuaSpacing.space4) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(GargantuaColors.accent)

                VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                    Text(dominant.name)
                        .font(GargantuaFonts.heading)
                        .foregroundStyle(GargantuaColors.ink)
                        .lineLimit(2)
                    HStack(spacing: GargantuaSpacing.space2) {
                        Text(AlertItem.formatBytes(dominant.size))
                            .font(GargantuaFonts.monoData)
                            .foregroundStyle(GargantuaColors.ink2)
                        Text("•")
                            .foregroundStyle(GargantuaColors.ink4)
                        Text("\(percent)% of folder")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink2)
                    }
                }

                Spacer()

                if canDrillIn {
                    HStack(spacing: GargantuaSpacing.space1) {
                        Text("Drill in")
                            .font(GargantuaFonts.label)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(GargantuaColors.accent)
                }
            }
            .padding(GargantuaSpacing.space4)
            .background(GargantuaColors.surface3)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                    .strokeBorder(GargantuaColors.accent.opacity(0.5), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canDrillIn)
    }

    @ViewBuilder
    private var otherItems: some View {
        if !remaining.isEmpty {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
                Text("Other items")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .textCase(.uppercase)

                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(remaining) { item in
                            DirectoryRowView(
                                item: item,
                                maxSize: maxSize,
                                isExpanded: false,
                                onExpand: nil,
                                onDrillDown: { onDrillDown(item) }
                            )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
                }
            }
        }
    }
}
