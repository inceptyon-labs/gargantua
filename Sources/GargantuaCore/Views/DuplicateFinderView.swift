import AppKit
import SwiftUI

// MARK: - Duplicate Finder View

/// Duplicate-file review UI fed by `FclonesAdapter` output.
///
/// Renders fclones-tagged `ScanResult`s clustered by hash group. Each group
/// shows its short hash, file count, total reclaimable bytes (keep-one
/// assumption), and the list of duplicate paths. Users review and pick which
/// copies to trash; nothing is pre-selected (review-by-default).
///
/// The "Send to Trash" action is surfaced via the `onSendToTrash` callback —
/// this view never performs destructive file operations. Callers must route
/// the callback through the Trust Layer / `ConfirmationModalView` before any
/// real trash call.
public struct DuplicateFinderView: View {
    public let results: [ScanResult]
    @Binding public var selectedIDs: Set<String>
    public let onSendToTrash: (([ScanResult]) -> Void)?
    public let onExplain: ((ScanResult) -> Void)?
    public let onBack: (() -> Void)?
    public let onRefresh: (() -> Void)?
    public let onRescan: (() -> Void)?
    public let persistence: PersistenceController?

    @State var expandedGroupIDs: Set<String>
    @State private var derivation: DuplicateFinderDerivation
    @State private var personalRoots: [URL]
    /// When `true`, drop both the personal-scope whitelist and the
    /// managed-tree blacklist — show every byte-identical group fclones
    /// surfaced. Default off: most matches outside the personal scope are
    /// app-managed noise the user can't act on file-by-file.
    @AppStorage("duplicateFinder.showEverything") private var showEverything: Bool = false

    public init(
        results: [ScanResult],
        selectedIDs: Binding<Set<String>>,
        onSendToTrash: (([ScanResult]) -> Void)? = nil,
        onExplain: ((ScanResult) -> Void)? = nil,
        onBack: (() -> Void)? = nil,
        onRefresh: (() -> Void)? = nil,
        onRescan: (() -> Void)? = nil,
        persistence: PersistenceController? = nil
    ) {
        self.results = results
        self._selectedIDs = selectedIDs
        self.onSendToTrash = onSendToTrash
        self.onExplain = onExplain
        self.onBack = onBack
        self.onRefresh = onRefresh
        self.onRescan = onRescan
        self.persistence = persistence

        let initialRoots = Self.loadPersonalRoots(from: persistence)
        self._personalRoots = State(initialValue: initialRoots)

        // Compute derivation once at init using whatever toggle value is
        // already persisted; .onChange refreshes it on (results, toggle,
        // roots) change. Property accesses then read State (free) instead
        // of re-running filter+group every render — the previous shape
        // did O(N) work per access × ~6 accesses per render, which
        // beachballed during scroll on large duplicate sets.
        let initialShowEverything = UserDefaults.standard.bool(forKey: "duplicateFinder.showEverything")
        let initial = DuplicateFinderDerivation.compute(
            results: results,
            showEverything: initialShowEverything,
            personalRoots: initialRoots.isEmpty ? nil : initialRoots
        )
        self._derivation = State(initialValue: initial)
        // Expand the biggest few groups by default; large duplicate sets can
        // have hundreds of groups, and keeping them all open hurts scroll
        // performance and visual parse.
        self._expandedGroupIDs = State(initialValue: Set(initial.groups.prefix(5).map(\.id)))
    }

    /// Cheap key for change detection. ScanResult isn't Equatable, so we
    /// fingerprint the array via count + endpoint ids — sufficient because
    /// fclones output is regenerated wholesale per scan, never partially
    /// mutated in place. Personal-scope roots are folded in so a settings
    /// change re-derives without a rescan.
    private var derivationKey: String {
        let rootsFingerprint = personalRoots.map(\.path).joined(separator: ":")
        return "\(results.count)|\(results.first?.id ?? "")|\(results.last?.id ?? "")|\(showEverything)|\(rootsFingerprint)"
    }

    /// Read user-configured personal-scope roots from persistence, expanding
    /// `~/x` patterns to absolute URLs. Returns `[]` when persistence is
    /// unavailable or the table is empty so the caller can fall back to
    /// `defaultPersonalRoots()`. Seeding the defaults is the Settings VM's
    /// job — Duplicate Finder shouldn't write to the store.
    @MainActor
    private static func loadPersonalRoots(from persistence: PersistenceController?) -> [URL] {
        guard let persistence else { return [] }
        do {
            let patterns = try persistence.fetchPersonalScopeRoots().map(\.pattern)
            return DuplicateFinderScopeFilter.expand(patterns: patterns)
        } catch {
            return []
        }
    }

    private var visibleResults: [ScanResult] { derivation.visibleResults }

    private var hiddenSummary: DuplicateFinderHiddenSummary { derivation.hidden }

    var groups: [DuplicateGroup] { derivation.groups }

    private var totalReclaimableSelected: Int64 {
        DuplicateFinderSelection.totalReclaimableBytes(
            groups: groups,
            selectedIDs: selectedIDs
        )
    }

    private var totalReclaimableCeiling: Int64 { derivation.totalReclaimableCeiling }

    private var totalVisibleFileCount: Int { derivation.visibleResults.count }

    /// Selectable rows across every group, keyed by id for O(1) lookup.
    /// Protected rows never appear here, so anything pulled through this map
    /// is guaranteed to be a legitimate trash candidate regardless of what
    /// the external `selectedIDs` binding carries.
    var selectableByID: [String: ScanResult] { derivation.selectableByID }

    /// Sanitized handoff for `onSendToTrash` — drops any id that isn't a
    /// current, selectable, ungrouped-free row. Defends the Trust Layer
    /// boundary against stale or externally mutated `selectedIDs`.
    private var selectedResults: [ScanResult] {
        let allowed = selectableByID
        return selectedIDs.compactMap { allowed[$0] }
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScanResultsHeader(
                title: "Duplicate Finder",
                onBack: onBack,
                onRefresh: onRefresh,
                onRescan: onRescan
            )

            summaryBar

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            if groups.isEmpty {
                emptyState
            } else {
                contentList
            }

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            actionBar
        }
        .onChange(of: derivationKey) { _, _ in
            derivation = DuplicateFinderDerivation.compute(
                results: results,
                showEverything: showEverything,
                personalRoots: personalRoots.isEmpty ? nil : personalRoots
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .gargantuaPersonalScopeRootsChanged)) { _ in
            personalRoots = Self.loadPersonalRoots(from: persistence)
        }
    }

    // MARK: - Summary Bar

    private var summaryBar: some View {
        HStack(spacing: GargantuaSpacing.space4) {
            summaryLabel("\(groups.count) groups")
            summaryDot
            summaryLabel("\(totalVisibleFileCount) files")
            summaryDot
            summaryLabel(AlertItem.formatBytes(totalReclaimableCeiling) + " reclaimable")

            if !showEverything {
                let hidden = hiddenSummary
                if hidden.groups > 0 {
                    summaryDot
                    summaryLabel("\(hidden.groups) outside personal scope hidden")
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }

            Spacer()

            scopeToggle
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(GargantuaColors.surface2)
    }

    private var scopeToggle: some View {
        Toggle(isOn: $showEverything) {
            Text("Show all duplicates")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink2)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .help(
            "Off (default): show only duplicates inside ~/Documents, ~/Downloads, ~/Desktop, ~/Pictures, "
                + "~/Movies, ~/Music — and hide app-managed sub-trees like ~/Documents/Adobe. "
                + "On: surface every byte-identical group fclones found, including dependency trees and system caches."
        )
    }

    private func summaryLabel(_ text: String) -> some View {
        Text(text)
            .font(GargantuaFonts.caption)
            .foregroundStyle(GargantuaColors.ink2)
    }

    private var summaryDot: some View {
        Text("·")
            .font(GargantuaFonts.caption)
            .foregroundStyle(GargantuaColors.ink3)
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        let hidden = hiddenSummary
        let filterIsHidingEverything = !showEverything && hidden.groups > 0

        VStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "doc.on.doc")
                .font(GargantuaFonts.display)
                .foregroundStyle(GargantuaColors.ink4)

            Text(filterIsHidingEverything
                ? "No duplicates in your personal folders"
                : "No duplicate groups to review")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink2)

            if filterIsHidingEverything {
                Text(
                    "\(hidden.groups) duplicate group\(hidden.groups == 1 ? "" : "s") "
                        + "(\(hidden.files) file\(hidden.files == 1 ? "" : "s"), "
                        + "\(AlertItem.formatBytes(hidden.reclaimableBytes))) live outside ~/Documents, "
                        + "~/Downloads, ~/Desktop, ~/Pictures, ~/Movies, ~/Music — or inside "
                        + "app-managed sub-trees like ~/Documents/Adobe. Clear dependency trees and caches via Deep Clean."
                )
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

                Button(action: { showEverything = true }, label: {
                    Text("Show all duplicates")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(
                            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                                .fill(GargantuaColors.surface3)
                        )
                })
                .buttonStyle(.plain)
                .padding(.top, GargantuaSpacing.space1)
            } else {
                Text("Your scan roots are clean.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Action Bar

extension DuplicateFinderView {
    var actionBar: some View {
        HStack {
            Text("\(selectedResults.count) selected")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)

            if !selectedResults.isEmpty {
                Text("(\(AlertItem.formatBytes(totalReclaimableSelected)))")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }

            Spacer()

            Button(action: triggerTrash) {
                Text("Send to Trash")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(.white)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(
                        selectedResults.isEmpty
                            ? GargantuaColors.review.opacity(0.4)
                            : GargantuaColors.review
                    )
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
            .disabled(selectedResults.isEmpty || onSendToTrash == nil)
            .help(
                onSendToTrash == nil
                    ? "Destructive actions are disabled until Trust Layer wiring is complete."
                    : "Route selected duplicates through the Trust Layer before trashing."
            )
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
    }
}

// MARK: - Actions

extension DuplicateFinderView {
    func triggerTrash() {
        guard !selectedIDs.isEmpty else { return }
        onSendToTrash?(selectedResults)
    }

    func toggleGroup(_ id: String) {
        if expandedGroupIDs.contains(id) {
            expandedGroupIDs.remove(id)
        } else {
            expandedGroupIDs.insert(id)
        }
    }

    func toggleGroupSelection(_ group: DuplicateGroup) {
        let ids = group.selectableIDs
        guard !ids.isEmpty else { return }
        if ids.allSatisfy(selectedIDs.contains) {
            selectedIDs.subtract(ids)
        } else {
            selectedIDs.formUnion(ids)
        }
    }

    func selectAllButFirst(in group: DuplicateGroup) {
        selectedIDs.subtract(group.files.map(\.id))
        selectedIDs.formUnion(DuplicateFinderSelection.selectAllButFirst(in: group))
    }

    func toggleSelection(_ id: String) {
        // Defense in depth: refuse to add ids for protected or unknown
        // (ungrouped) rows, even if something upstream attempts to feed
        // them through. Removal always succeeds so stale ids can be
        // cleaned out by unchecking.
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            return
        }
        guard selectableByID[id] != nil else { return }
        selectedIDs.insert(id)
    }
}
