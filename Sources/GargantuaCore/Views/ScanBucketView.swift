import SwiftUI

// MARK: - Scan Bucket

/// Groups scan results by safety level with computed totals.
public struct ScanBucket: Identifiable {
    public let id: SafetyLevel
    public let items: [ScanResult]

    public var count: Int { items.count }
    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    /// Display title for the bucket header.
    public var title: String {
        switch id {
        case .safe:       return "Safe to Clean"
        case .review:     return "Review Required"
        case .protected_: return "Protected"
        }
    }

    /// Groups an array of scan results into ordered buckets: safe, review, protected.
    /// Empty buckets are included so headers always render.
    public static func group(_ results: [ScanResult]) -> [ScanBucket] {
        let grouped = Dictionary(grouping: results) { $0.safety }
        return SafetyLevel.allCases.map { level in
            ScanBucket(id: level, items: grouped[level] ?? [])
        }
    }
}

// MARK: - Summary Bar

/// Top bar showing total items, reclaimable space, and scan duration.
public struct ScanSummaryBar: View {
    public let totalItems: Int
    public let reclaimableBytes: Int64
    public let scanDuration: TimeInterval

    public init(totalItems: Int, reclaimableBytes: Int64, scanDuration: TimeInterval) {
        self.totalItems = totalItems
        self.reclaimableBytes = reclaimableBytes
        self.scanDuration = scanDuration
    }

    public var body: some View {
        HStack(spacing: GargantuaSpacing.space4) {
            label("\(totalItems) items")
            separator
            label(AlertItem.formatBytes(reclaimableBytes) + " reclaimable")
            separator
            label(formattedDuration)
            Spacer()
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(GargantuaColors.surface2)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(GargantuaFonts.caption)
            .foregroundStyle(GargantuaColors.ink2)
    }

    private var separator: some View {
        Text("·")
            .font(GargantuaFonts.caption)
            .foregroundStyle(GargantuaColors.ink3)
    }

    private var formattedDuration: String {
        if scanDuration < 1 {
            return String(format: "%.0f ms", scanDuration * 1000)
        } else if scanDuration < 60 {
            return String(format: "%.1f s", scanDuration)
        } else {
            let minutes = Int(scanDuration) / 60
            let seconds = Int(scanDuration) % 60
            return "\(minutes)m \(seconds)s"
        }
    }
}

// MARK: - Bucket Header

/// Collapsible header for a scan bucket: "Safe to Clean · 18.2 GB"
struct ScanBucketHeader: View {
    let bucket: ScanBucket
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GargantuaColors.ink3)
                    .frame(width: 12)

                // Safety color indicator dot
                Circle()
                    .fill(safetyColor)
                    .frame(width: 8, height: 8)

                Text(bucket.title)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Text("·")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink3)

                Text("\(bucket.count) items")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)

                Text("·")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink3)

                Text(AlertItem.formatBytes(bucket.totalSize))
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink)

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space4)
        .background(GargantuaColors.surface1)
    }

    private var safetyColor: Color {
        switch bucket.id {
        case .safe:       return GargantuaColors.safe
        case .review:     return GargantuaColors.review
        case .protected_: return GargantuaColors.protected_
        }
    }
}

// MARK: - Scan Bucket List View

/// Three-bucket scan results layout with collapsible sections.
///
/// Safe items are expanded and pre-selected, Review items are expanded
/// but unchecked, Protected items are visible but locked (no checkboxes).
public struct ScanBucketListView: View {
    public let results: [ScanResult]
    public let scanDuration: TimeInterval
    @Binding public var selectedIDs: Set<String>
    public let onExplain: ((ScanResult) -> Void)?

    @State private var expandedBuckets: Set<SafetyLevel> = [.safe, .review, .protected_]

    public init(
        results: [ScanResult],
        scanDuration: TimeInterval,
        selectedIDs: Binding<Set<String>>,
        onExplain: ((ScanResult) -> Void)? = nil
    ) {
        self.results = results
        self.scanDuration = scanDuration
        self._selectedIDs = selectedIDs
        self.onExplain = onExplain
    }

    private var buckets: [ScanBucket] { ScanBucket.group(results) }

    private var reclaimableBytes: Int64 {
        results.filter { selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Summary bar
            ScanSummaryBar(
                totalItems: results.count,
                reclaimableBytes: reclaimableBytes,
                scanDuration: scanDuration
            )

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            // Buckets
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(buckets) { bucket in
                        bucketSection(bucket)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bucketSection(_ bucket: ScanBucket) -> some View {
        let isExpanded = expandedBuckets.contains(bucket.id)

        ScanBucketHeader(
            bucket: bucket,
            isExpanded: isExpanded,
            onToggle: { toggleBucket(bucket.id) }
        )

        Rectangle()
            .fill(GargantuaColors.borderSoft)
            .frame(height: 1)

        if isExpanded {
            ForEach(bucket.items) { item in
                if bucket.id == .protected_ {
                    // Protected: visible but locked, no interaction
                    protectedRow(item)
                } else {
                    DenseScanItemRow(
                        item: item,
                        isSelected: selectedIDs.contains(item.id),
                        onToggleSelection: { toggleSelection(item.id) },
                        onExplain: onExplain.map { handler in { handler(item) } }
                    )
                }

                Rectangle()
                    .fill(GargantuaColors.borderSoft)
                    .frame(height: 1)
            }
        }
    }

    /// Protected items: shown but dimmed, locked indicator, no checkbox.
    private func protectedRow(_ item: ScanResult) -> some View {
        HStack(spacing: GargantuaSpacing.space2) {
            ConfidenceOrbit(confidence: item.confidence, safety: item.safety)

            // Lock icon instead of checkbox
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(GargantuaColors.ink4)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: GargantuaSpacing.space1) {
                    Text(item.name)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(1)

                    if !item.explanation.isEmpty {
                        Text(item.explanation)
                            .font(GargantuaFonts.body)
                            .foregroundStyle(GargantuaColors.ink4)
                            .lineLimit(1)
                    }
                }

                Text(item.path)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink4)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(AlertItem.formatBytes(item.size))
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink3)
                .lineLimit(1)
        }
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space3)
        .background(GargantuaColors.protected_.opacity(0.06))
    }

    private func toggleBucket(_ level: SafetyLevel) {
        if expandedBuckets.contains(level) {
            expandedBuckets.remove(level)
        } else {
            expandedBuckets.insert(level)
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}
