import AppKit
import SwiftUI

/// Top-level view for the Process Inventory pane.
///
/// Read-only surface — kill / remove-source actions land in task 5. The
/// Explain action converts the focused `ProcessItem` into a synthetic
/// `ScanResult` so the existing `AIExplanationController` can drive the
/// AI-fallback sheet without a parallel pipeline.
public struct ProcessInventoryView: View {
    @State private var session = ProcessInventorySession()
    @State private var expandedID: String?
    @State private var sortMetric: ProcessSortMetric = .cpu
    @State private var safetyFilter: ProcessSafetyFilter = .all
    private let onExplain: ((ScanResult) -> Void)?

    /// Default top-N cap. Snapshot views shouldn't fight Activity Monitor for
    /// completeness — surfacing the top 50 keeps cognitive load low and lets
    /// the user re-rank by toggling the metric.
    public static let defaultTopN: Int = 50

    public init(onExplain: ((ScanResult) -> Void)? = nil) {
        self.onExplain = onExplain
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScanResultsHeader(
                title: "Processes",
                subtitle: subtitleText,
                subtitleStyle: .voice,
                onRescan: { Task { await session.scan(metric: sortMetric, topN: Self.defaultTopN) } },
                isBusy: session.isScanning
            )

            if session.scan == nil, !session.isScanning {
                idleState
            } else if session.isScanning {
                scanningState
            } else if let scan = session.scan {
                resultsState(scan)
            }
        }
        .background(GargantuaColors.void_)
        .task {
            if session.scan == nil {
                await session.scan(metric: sortMetric, topN: Self.defaultTopN)
            }
        }
        .onChange(of: session.scan?.scannedAt) { _, _ in
            // Drop stale expansion state — a row that's no longer in the
            // visible list shouldn't keep its expanded marker.
            if let expandedID, !(session.scan?.items.contains(where: { $0.id == expandedID }) ?? false) {
                self.expandedID = nil
            }
        }
    }

    // MARK: - States

    private var subtitleText: String {
        if let scan = session.scan {
            let shown = scan.items.count
            let total = scan.totalProcessCount
            if shown < total {
                return "Top \(shown) of \(total) running · ranked by \(scan.sortedBy.displayLabel)"
            }
            return "\(total) running · ranked by \(scan.sortedBy.displayLabel)"
        }
        if session.isScanning { return "Sampling running processes…" }
        return "Snapshot every running process. Decide what stays."
    }

    private var idleState: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Spacer()
            Image(systemName: "cpu")
                .font(.system(size: 36))
                .foregroundStyle(GargantuaColors.ink3)
            Text("Snapshot running processes")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)
            Text("Read-only. Two samples 500 ms apart for CPU.")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
            Button {
                Task { await session.scan(metric: sortMetric, topN: Self.defaultTopN) }
            } label: {
                Text("Take Snapshot")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(.white)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(GargantuaColors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
            .padding(.top, GargantuaSpacing.space2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanningState: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Spacer()
            AccretionDiskView(activityRate: 18, size: 36, color: GargantuaColors.accretion)
            Text("Reading libproc, parent PIDs, signatures…")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func resultsState(_ scan: ProcessInventoryScan) -> some View {
        let visible = safetyFilter.apply(scan.items)

        VStack(spacing: 0) {
            controlBar(scan: scan, visibleCount: visible.count)

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            if visible.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: GargantuaSpacing.space2) {
                        ForEach(visible) { item in
                            ProcessInventoryRow(
                                item: item,
                                isExpanded: expandedID == item.id,
                                onToggleExpand: {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        expandedID = expandedID == item.id ? nil : item.id
                                    }
                                },
                                onRevealBinary: { revealBinary(item) },
                                onRevealPlist: { revealPlist(item) },
                                onExplain: onExplain != nil ? { explain(item) } : nil
                            )
                        }
                    }
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.vertical, GargantuaSpacing.space3)
                }
            }

            footer(scan: scan)
        }
    }

    private func controlBar(scan: ProcessInventoryScan, visibleCount: Int) -> some View {
        HStack(spacing: GargantuaSpacing.space3) {
            sortToggle
            Divider()
                .frame(height: 14)
                .overlay(GargantuaColors.border)
            ForEach(ProcessSafetyFilter.allCases, id: \.self) { option in
                filterButton(option, scan: scan)
            }
            Spacer()
            Text("\(visibleCount) shown")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
    }

    private var sortToggle: some View {
        HStack(spacing: 4) {
            Text("Sort:")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
            ForEach(ProcessSortMetric.allCases, id: \.self) { metric in
                Button {
                    // Re-sort the existing snapshot in place rather than
                    // re-running a 500 ms scan — toggling between CPU and
                    // Memory should feel instant.
                    sortMetric = metric
                    session.resort(by: metric)
                } label: {
                    Text(metric.displayLabel)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(sortMetric == metric ? GargantuaColors.ink : GargantuaColors.ink2)
                        .padding(.horizontal, GargantuaSpacing.space2)
                        .padding(.vertical, 4)
                        .background {
                            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                                .fill(sortMetric == metric ? GargantuaColors.surface2 : .clear)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func filterButton(_ option: ProcessSafetyFilter, scan: ProcessInventoryScan) -> some View {
        let count = option.apply(scan.items).count
        let isActive = safetyFilter == option
        return Button {
            safetyFilter = option
        } label: {
            HStack(spacing: 4) {
                Text(option.displayLabel)
                    .font(GargantuaFonts.caption)
                Text("\(count)")
                    .font(GargantuaFonts.caption.monospacedDigit())
                    .foregroundStyle(GargantuaColors.ink3)
            }
            .foregroundStyle(isActive ? GargantuaColors.ink : GargantuaColors.ink2)
            .padding(.horizontal, GargantuaSpacing.space2)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .fill(isActive ? GargantuaColors.surface2 : .clear)
            }
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: GargantuaSpacing.space2) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(GargantuaColors.ink3)
            Text("No processes match the current filter.")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(scan: ProcessInventoryScan) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)
            HStack(spacing: GargantuaSpacing.space2) {
                Text("Read-only — actions land in a future update.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                Spacer()
                Text("Last sampled " + Self.timestampFormatter.localizedString(for: scan.scannedAt, relativeTo: Date()))
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space2)
        }
    }

    // MARK: - Actions

    private func revealBinary(_ item: ProcessItem) {
        guard let exe = item.executablePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: exe)])
    }

    private func revealPlist(_ item: ProcessItem) {
        guard let plist = item.launchSource.plistPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plist)])
    }

    private func explain(_ item: ProcessItem) {
        guard let onExplain else { return }
        onExplain(item.toScanResult())
    }

    private static let timestampFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

// MARK: - Filter

public enum ProcessSafetyFilter: CaseIterable, Equatable {
    case all
    case review
    case safe
    case protected_
    case sensitive
    case orphaned

    var displayLabel: String {
        switch self {
        case .all: "All"
        case .review: "Review"
        case .safe: "Safe"
        case .protected_: "Protected"
        case .sensitive: "Sensitive"
        case .orphaned: "Orphaned"
        }
    }

    func apply(_ items: [ProcessItem]) -> [ProcessItem] {
        switch self {
        case .all: items
        case .review: items.filter { $0.safety == .review }
        case .safe: items.filter { $0.safety == .safe }
        case .protected_: items.filter { $0.safety == .protected_ }
        case .sensitive: items.filter { $0.reasons.contains(.sensitiveVendor) }
        case .orphaned: items.filter { $0.reasons.contains(.orphaned) }
        }
    }
}

// MARK: - Session

/// Lightweight async wrapper around `ProcessInventoryScanning` so the view can
/// kick scans off the main actor and observe the result via `@Observable`.
@MainActor
@Observable
public final class ProcessInventorySession {
    public private(set) var scan: ProcessInventoryScan?
    public private(set) var isScanning = false

    private let scanner: any ProcessInventoryScanning

    public init(scanner: any ProcessInventoryScanning = DefaultProcessInventoryScanner()) {
        self.scanner = scanner
    }

    public func scan(metric: ProcessSortMetric, topN: Int?) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let scanner = self.scanner
        let result = await Task.detached(priority: .userInitiated) {
            await scanner.scan(metric: metric, topN: topN)
        }.value
        self.scan = result
    }

    /// Re-rank the existing snapshot in place. Avoids the 500 ms sample
    /// window when the user just wants to toggle between CPU and Memory.
    /// The top-N cap from the original scan is preserved.
    public func resort(by metric: ProcessSortMetric) {
        guard let current = scan else { return }
        if current.sortedBy == metric { return }
        let resorted = Self.rank(current.items, by: metric)
        self.scan = ProcessInventoryScan(
            items: resorted,
            totalProcessCount: current.totalProcessCount,
            sortedBy: metric,
            topN: current.topN,
            scannedAt: current.scannedAt
        )
    }

    private static func rank(_ items: [ProcessItem], by metric: ProcessSortMetric) -> [ProcessItem] {
        items.sorted { lhs, rhs in
            let lhsP: Double = metric == .cpu ? lhs.cpuFraction : Double(lhs.residentBytes)
            let rhsP: Double = metric == .cpu ? rhs.cpuFraction : Double(rhs.residentBytes)
            if lhsP != rhsP { return lhsP > rhsP }
            let nameCmp = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameCmp != .orderedSame { return nameCmp == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}

// MARK: - Synthetic ScanResult bridge

extension ProcessItem {
    /// Convert to a `ScanResult` so the existing `AIExplanationController`
    /// can drive the AI fallback sheet without a parallel pipeline. This is
    /// strictly a presentation bridge — nothing in the cleanup engine ever
    /// reads a synthetic result.
    public func toScanResult() -> ScanResult {
        let attribution = SourceAttribution(
            name: identity?.vendorDisplayName ?? identity?.bundleName ?? command,
            bundleID: identity?.bundleIdentifier,
            verifySignature: false
        )
        let categoryName: String = {
            switch launchSource {
            case .launchd: "background_process_launchd"
            case .foregroundApp: "background_process_foreground"
            case .userSession: "background_process_user_session"
            case .childProcess: "background_process_child"
            case .unknown: "background_process_unknown"
            }
        }()
        var tags = reasons.map(\.rawValue)
        tags.append("confidence:\(launchConfidence.rawValue)")
        return ScanResult(
            id: id,
            name: displayName,
            path: executablePath ?? command,
            size: 0,
            safety: safety,
            confidence: explanationConfidence,
            explanation: explanation,
            source: attribution,
            lastAccessed: nil,
            category: categoryName,
            tags: tags,
            regenerates: false,
            regenerateCommand: nil
        )
    }

    /// Heuristic confidence for the explanation sheet. Identity + bundle
    /// present → 90, signed but unbundled → 70, unsigned → 40, no identity
    /// → 30. Used only in the synthetic bridge.
    private var explanationConfidence: Int {
        guard let identity else { return 30 }
        if identity.bundlePath != nil, identity.vendor != .unsigned { return 90 }
        if identity.vendor == .unsigned { return 40 }
        return 70
    }
}
