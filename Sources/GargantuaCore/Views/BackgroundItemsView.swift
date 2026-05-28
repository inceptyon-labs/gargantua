import AppKit
import SwiftUI

// swiftlint:disable file_length

// Top-level view for the Background Items review pane.
//
// Pre-selection (`preSelectedPlistPath`) lets Process Inventory navigate here
// for the "remove source" handoff — the row matching the plist path expands
// once the scan lands.
// swiftlint:disable:next type_body_length
public struct BackgroundItemsView: View {
    @State private var session: BackgroundItemsSession
    @State private var expandedID: String?
    @State private var filter: BackgroundItemFilter = .all
    @State private var pendingAction: PendingBackgroundItemAction?
    @State private var lastError: String?
    @Binding private var preSelectedPlistPath: String?
    private let onExplain: ((ScanResult) -> Void)?
    private let onTriage: (([ScanResult]) -> Void)?

    public init(
        session: BackgroundItemsSession? = nil,
        onExplain: ((ScanResult) -> Void)? = nil,
        onTriage: (([ScanResult]) -> Void)? = nil,
        actionExecutor: (any BackgroundItemActionExecuting)? = nil,
        preSelectedPlistPath: Binding<String?> = .constant(nil)
    ) {
        self.onExplain = onExplain
        self.onTriage = onTriage
        self._preSelectedPlistPath = preSelectedPlistPath
        self._session = State(
            initialValue: session ?? BackgroundItemsSession(actionExecutor: actionExecutor)
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            if session.scan == nil, !session.isScanning {
                startView
            } else {
                ScanResultsHeader(
                    title: "Background Items",
                    subtitle: subtitleText,
                    subtitleStyle: .voice,
                    onBack: { clearScan() },
                    onRescan: { startScan() },
                    isBusy: session.isScanning
                )

                if session.isScanning {
                    scanningState
                } else if let scan = session.scan {
                    resultsState(scan)
                }
            }
        }
        .background(GargantuaColors.void_)
        .task {
            if preSelectedPlistPath != nil, session.scan == nil, !session.isScanning {
                await session.scan()
            }
            consumePendingPreSelection()
        }
        .onChange(of: preSelectedPlistPath) { _, _ in
            // Re-trigger when Process Inventory navigates here a second time
            // for the same path — clearing then re-setting the binding makes
            // SwiftUI fire this even if the value matches the previous nil.
            if preSelectedPlistPath != nil, session.scan == nil, !session.isScanning {
                Task { await session.scan() }
            }
            consumePendingPreSelection()
        }
        .onChange(of: session.scan?.scannedAt) { _, _ in
            // First scan can finish after the .task body runs (the session
            // kicks the scan in detached priority); apply pre-selection once
            // the scan lands.
            consumePendingPreSelection()
        }
        .sheet(item: $pendingAction) { pending in
            BackgroundItemActionConfirmation(
                item: pending.item,
                action: pending.action,
                onConfirm: {
                    let toRun = pending
                    pendingAction = nil
                    Task { await runAction(toRun) }
                },
                onCancel: { pendingAction = nil }
            )
        }
        .alert(
            "Background item action failed",
            isPresented: Binding(
                get: { lastError != nil },
                set: { if !$0 { lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { lastError = nil }
        } message: {
            Text(lastError ?? "")
        }
    }

    // MARK: - States

    private var subtitleText: String {
        if let scan = session.scan {
            let total = scan.items.count
            let review = scan.items.filter { $0.safety == .review }.count
            return "\(total) item\(total == 1 ? "" : "s") · \(review) need review"
        }
        if session.isScanning { return "Cataloging the things that linger after launch." }
        return "Trace what runs in the background. Decide what to trust."
    }

    private var startView: some View {
        VStack(spacing: 0) {
            PageHeaderView(
                title: "Background Items",
                subtitle: "Trace what starts itself, then decide what to trust.",
                subtitleStyle: .voice
            )

            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: GargantuaSpacing.space3) {
                        Spacer(minLength: 0)

                        GargantuaBrandIcon(
                            resourceName: "background-items-gargantua-gpt2",
                            fallbackSystemName: "clock.badge.questionmark",
                            fallbackColor: GargantuaColors.ink4
                        )

                        Text("Scan launch agents and daemons")
                            .font(GargantuaFonts.heading)
                            .foregroundStyle(GargantuaColors.ink)

                        Text("Scans first. Disable, enable, and remove actions require confirmation after review.")
                            .font(GargantuaFonts.body)
                            .foregroundStyle(GargantuaColors.ink2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 390)

                        HStack(spacing: GargantuaSpacing.space3) {
                            ForEach(["Launch Agents", "Launch Daemons", "Login Items"], id: \.self) { label in
                                HStack(spacing: GargantuaSpacing.space1) {
                                    Circle()
                                        .fill(GargantuaColors.ink4)
                                        .frame(width: 5, height: 5)
                                    Text(label)
                                        .font(GargantuaFonts.caption)
                                        .foregroundStyle(GargantuaColors.ink3)
                                }
                            }
                        }

                        GargantuaButton("Start Scan", tone: .primary, action: startScan)
                            .padding(.top, GargantuaSpacing.space2)

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var scanningState: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Spacer()
            AccretionDiskView(activityRate: 18, size: 36, color: GargantuaColors.accretion)
            Text("Reading launchd plists, signatures, login items…")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func resultsState(_ scan: BackgroundItemScan) -> some View {
        let visible = filter.apply(scan.items)

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
                            BackgroundItemRow(
                                item: item,
                                isExpanded: expandedID == item.id,
                                isBusy: session.busyItemIDs.contains(item.id),
                                isSessionDisabled: session.sessionDisabledIDs.contains(item.id),
                                onToggleExpand: {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        expandedID = expandedID == item.id ? nil : item.id
                                    }
                                },
                                onReveal: { revealInFinder(item) },
                                onExplain: onExplain != nil ? { explain(item) } : nil,
                                onOpenLoginSettings: openLoginItemsSettings,
                                onAction: { action in
                                    pendingAction = PendingBackgroundItemAction(
                                        item: item,
                                        action: action
                                    )
                                }
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

    private func controlBar(scan: BackgroundItemScan, visibleCount: Int) -> some View {
        let triageResults = suspiciousTriageResults(scan)
        return HStack(spacing: GargantuaSpacing.space3) {
            ForEach(BackgroundItemFilter.allCases, id: \.self) { option in
                filterButton(option, scan: scan)
            }
            Spacer()
            if let onTriage, !triageResults.isEmpty {
                aiTriageButton {
                    onTriage(triageResults)
                }
            }
            Text("\(visibleCount) shown")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
    }

    private func aiTriageButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 11, weight: .medium))
                Text("Suspicious Triage")
                    .font(GargantuaFonts.caption)
            }
            .foregroundStyle(GargantuaColors.accent)
        }
        .buttonStyle(.plain)
        .help("Analyze the top suspicious background item candidates with the active AI engine")
    }

    private func suspiciousTriageResults(_ scan: BackgroundItemScan) -> [ScanResult] {
        scan.items.compactMap { item -> (score: Int, result: ScanResult)? in
            let triage = backgroundItemTriageSignals(for: item)
            guard triage.score >= 45 else { return nil }
            return (triage.score, backgroundItemTriageResult(for: item, signals: triage.signals))
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.result.name.localizedCaseInsensitiveCompare(rhs.result.name) == .orderedAscending
        }
        .prefix(6)
        .map(\.result)
    }

    private func backgroundItemTriageSignals(for item: BackgroundItem) -> (score: Int, signals: [String]) {
        guard item.safety != .protected_ else { return (0, []) }
        let contributions = Self.bgTriageReasonContributions(for: item)
            + Self.bgTriageSourceContributions(for: item)
            + Self.bgTriageIdentityContributions(for: item)
            + Self.bgTriagePathContributions(for: item)
        return (contributions.reduce(0) { $0 + $1.points }, contributions.map(\.signal))
    }

    private static func bgTriageReasonContributions(for item: BackgroundItem) -> [(points: Int, signal: String)] {
        var out: [(Int, String)] = []
        if item.reasons.contains(.unsigned) { out.append((90, "unsigned binary")) }
        if item.reasons.contains(.orphaned) { out.append((80, "orphaned executable")) }
        if item.reasons.contains(.orphanedVendor) { out.append((70, "orphaned vendor")) }
        if item.reasons.contains(.listensForRequests) { out.append((25, "listens for requests")) }
        if item.reasons.contains(.persistentlyRunning) { out.append((20, "persistent at boot or login")) }
        return out
    }

    private static func bgTriageSourceContributions(for item: BackgroundItem) -> [(points: Int, signal: String)] {
        switch item.source {
        case .startupItem: return [(45, "legacy startup item")]
        case .launchDaemon: return [(30, "runs as launch daemon")]
        default: return []
        }
    }

    private static func bgTriageIdentityContributions(for item: BackgroundItem) -> [(points: Int, signal: String)] {
        item.identity == nil ? [(20, "no resolved identity")] : []
    }

    private static func bgTriagePathContributions(for item: BackgroundItem) -> [(points: Int, signal: String)] {
        guard let path = item.executablePath ?? item.plistPath else { return [] }
        var out: [(Int, String)] = []
        let lower = path.lowercased()
        if lower.hasPrefix("/tmp/") || lower.hasPrefix("/private/tmp/") || lower.contains("/var/folders/") {
            out.append((35, "temporary-path item"))
        }
        if lower.contains("/downloads/") {
            out.append((20, "runs from downloads"))
        }
        return out
    }

    private func backgroundItemTriageResult(for item: BackgroundItem, signals: [String]) -> ScanResult {
        let base = item.toScanResult()
        let readableSignals = signals.joined(separator: ", ")
        return ScanResult(
            id: "triage:\(base.id)",
            name: base.name,
            path: base.path,
            size: base.size,
            safety: base.safety,
            confidence: base.confidence,
            explanation: "Triage signals: \(readableSignals). \(base.explanation)",
            source: base.source,
            lastAccessed: base.lastAccessed,
            category: "background_item_triage",
            tags: base.tags + signals.map { "triage_signal:\($0.replacingOccurrences(of: " ", with: "_"))" },
            regenerates: base.regenerates,
            regenerateCommand: base.regenerateCommand
        )
    }

    private func filterButton(_ option: BackgroundItemFilter, scan: BackgroundItemScan) -> some View {
        let count = option.apply(scan.items).count
        let isActive = filter == option
        return Button {
            filter = option
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
            Text("No items match the current filter.")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(scan: BackgroundItemScan) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)
            HStack(spacing: GargantuaSpacing.space2) {
                if scan.loginItemsNeedPrivileges {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 11))
                        .foregroundStyle(GargantuaColors.ink3)
                    Text("Login-item enumeration is limited without elevated privileges.")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                    Button("Open Login Items", action: openLoginItemsSettings)
                        .buttonStyle(.plain)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.accent)
                }
                if scan.unparseableCount > 0 {
                    Text("\(scan.unparseableCount) unreadable plist\(scan.unparseableCount == 1 ? "" : "s") skipped.")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.review)
                }
                Spacer()
                Text("Last scanned " + Self.timestampFormatter.localizedString(for: scan.scannedAt, relativeTo: Date()))
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space2)
        }
    }

    // MARK: - Actions

    private func revealInFinder(_ item: BackgroundItem) {
        guard let plistPath = item.plistPath else { return }
        let url = URL(fileURLWithPath: plistPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func explain(_ item: BackgroundItem) {
        guard let onExplain else { return }
        onExplain(item.toScanResult())
    }

    private func startScan() {
        Task { await session.scan() }
    }

    private func clearScan() {
        expandedID = nil
        session.clearScan()
    }

    private func runAction(_ pending: PendingBackgroundItemAction) async {
        let outcome = await session.perform(pending.action, on: pending.item)
        if !outcome.succeeded, let error = outcome.error {
            lastError = Self.humanReadableError(error)
        }
    }

    private static func humanReadableError(_ raw: String) -> String {
        if raw.contains("odesigning failure") || raw.contains("-67028") || raw.contains("errSecCS") {
            return "macOS blocked this action because the helper isn't signed for this build. "
                + "This is expected in debug builds. A release build with Developer ID signing won't hit this."
        }
        if raw.contains("permission") || raw.contains("not permitted") || raw.contains("-60005") {
            return "macOS denied access to this item. It may require Full Disk Access or belong to a system process that can't be modified."
        }
        if raw.contains("No such file") || raw.contains("does not exist") {
            return "The plist file no longer exists on disk. It may have already been removed."
        }
        return raw
    }

    /// If the parent passed a plist path to pre-select, expand the matching
    /// row (and switch to the All filter so it's actually visible) once the
    /// scan has produced an item with that plist path. Clears the binding so
    /// the parent can re-trigger the same handoff later.
    private func consumePendingPreSelection() {
        guard let path = preSelectedPlistPath else { return }
        guard let scan = session.scan else { return }
        guard let match = scan.items.first(where: { $0.plistPath == path }) else {
            // Scan didn't surface the path — most likely a daemon plist that
            // requires elevated enumeration. Surface as a soft error so the
            // user understands why navigation didn't land somewhere visible.
            lastError = "Could not locate that source in the Background Items list. It may require elevated enumeration."
            preSelectedPlistPath = nil
            return
        }
        // The path may belong to an item filtered out by the current chip
        // (e.g. Sensitive). Drop back to All so the row actually shows.
        if !filter.apply([match]).contains(where: { $0.id == match.id }) {
            filter = .all
        }
        withAnimation(.easeOut(duration: 0.15)) {
            expandedID = match.id
        }
        preSelectedPlistPath = nil
    }

    private static let timestampFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

// MARK: - Filter

public enum BackgroundItemFilter: CaseIterable, Equatable {
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

    func apply(_ items: [BackgroundItem]) -> [BackgroundItem] {
        switch self {
        case .all: items
        case .review: items.filter { $0.safety == .review }
        case .safe: items.filter { $0.safety == .safe }
        case .protected_: items.filter { $0.safety == .protected_ }
        case .sensitive: items.filter { $0.reasons.contains(.sensitiveVendor) }
        case .orphaned: items.filter { $0.isOrphaned }
        }
    }
}

// MARK: - Session

/// Lightweight async wrapper around `BackgroundItemScanning` so the view can
/// kick scans off the main actor and observe the result via `@Observable`.
@MainActor
@Observable
public final class BackgroundItemsSession {
    public private(set) var scan: BackgroundItemScan?
    public private(set) var isScanning = false
    /// IDs of items currently being mutated. The row uses this to render a
    /// spinner inline so the user gets feedback while `launchctl` runs.
    public private(set) var busyItemIDs: Set<String> = []
    /// IDs the user disabled in this session. The scanner derives the
    /// `disabledFlag` reason from the plist's `Disabled` key, but
    /// `launchctl disable` writes runtime state to launchd's disabled DB
    /// instead — so a fresh scan after a successful disable still reports
    /// the plist as enabled. Carry the in-session disable state forward so
    /// the Delete button reveals on the same row the user just disabled.
    public private(set) var sessionDisabledIDs: Set<String> = []

    private let scanner: any BackgroundItemScanning
    private let actionExecutor: (any BackgroundItemActionExecuting)?

    public init(
        scanner: any BackgroundItemScanning = DefaultBackgroundItemScanner(),
        actionExecutor: (any BackgroundItemActionExecuting)? = DefaultBackgroundItemActionExecutor()
    ) {
        self.scanner = scanner
        self.actionExecutor = actionExecutor
    }

    public func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let scanner = self.scanner
        let result = await Task.detached(priority: .userInitiated) {
            scanner.scan()
        }.value
        self.scan = result
    }

    public func clearScan() {
        scan = nil
        busyItemIDs.removeAll()
        sessionDisabledIDs.removeAll()
    }

    /// Run a `BackgroundItemAction` against `item`, marking the row busy for
    /// the duration. After success, the session re-scans so the row's
    /// disabled/enabled state reflects the new ground truth.
    public func perform(
        _ action: BackgroundItemAction,
        on item: BackgroundItem
    ) async -> BackgroundItemActionOutcome {
        guard let actionExecutor else {
            return BackgroundItemActionOutcome(
                itemID: item.id,
                action: action,
                succeeded: false,
                error: "Action executor is not configured."
            )
        }
        busyItemIDs.insert(item.id)
        defer { busyItemIDs.remove(item.id) }

        // The executor's delete pre-condition checks `disabledFlag` to enforce
        // "disable runs first." When the user disabled the item earlier in
        // this session, the plist key still reads as enabled, so synthesize
        // the reason on the fly.
        let effectiveItem = sessionDisabledIDs.contains(item.id)
            ? item.withSessionDisabled()
            : item

        let outcome: BackgroundItemActionOutcome
        switch action {
        case .disable:
            outcome = await actionExecutor.disable(effectiveItem)
        case .enable:
            outcome = await actionExecutor.enable(effectiveItem)
        case .delete:
            outcome = await actionExecutor.delete(effectiveItem, confirmedAt: item.safety.confirmationTier)
        }

        if outcome.succeeded {
            switch action {
            case .disable:
                sessionDisabledIDs.insert(item.id)
            case .enable, .delete:
                sessionDisabledIDs.remove(item.id)
            }
            await scan()
        }
        return outcome
    }
}

/// Identifies a pending action awaiting user confirmation. Stored on the view
/// rather than the session so dismissing the sheet doesn't have to round-trip
/// through `@Observable`.
public struct PendingBackgroundItemAction: Identifiable, Equatable {
    public let item: BackgroundItem
    public let action: BackgroundItemAction
    public var id: String { "\(item.id)|\(action.rawValue)" }

    public init(item: BackgroundItem, action: BackgroundItemAction) {
        self.item = item
        self.action = action
    }
}

// MARK: - Synthetic ScanResult bridge

extension BackgroundItem {
    /// Convert to a `ScanResult` so the existing `AIExplanationController`
    /// can drive the AI fallback sheet without a parallel pipeline. This is
    /// strictly a presentation bridge — nothing in the cleanup engine ever
    /// reads a synthetic result.
    public func toScanResult() -> ScanResult {
        let bytes: Int64 = 0
        let categoryName: String = {
            switch source {
            case .userLaunchAgent, .systemLaunchAgent: "background_launch_agent"
            case .launchDaemon: "background_launch_daemon"
            case .startupItem: "background_startup_item"
            case .loginItem: "background_login_item"
            }
        }()
        let attribution = SourceAttribution(
            name: identity?.vendorDisplayName ?? identity?.bundleName ?? label,
            bundleID: identity?.bundleIdentifier,
            verifySignature: false
        )
        return ScanResult(
            id: id,
            name: displayName,
            path: plistPath ?? executablePath ?? label,
            size: bytes,
            safety: safety,
            confidence: explanationConfidence,
            explanation: explanation,
            source: attribution,
            lastAccessed: nil,
            category: categoryName,
            tags: reasons.map(\.rawValue),
            regenerates: false,
            regenerateCommand: nil
        )
    }

    /// Heuristic confidence: identity + bundle present → 90, signed but
    /// unbundled → 70, unsigned → 40, no identity → 30. Used only in the
    /// synthetic bridge; the deterministic explanation itself doesn't carry
    /// a confidence score yet.
    private var explanationConfidence: Int {
        guard let identity else { return 30 }
        if identity.bundlePath != nil, identity.vendor != .unsigned { return 90 }
        if identity.vendor == .unsigned { return 40 }
        return 70
    }
}
