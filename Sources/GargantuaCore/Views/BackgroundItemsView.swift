import AppKit
import SwiftUI

/// Top-level view for the Background Items review pane.
///
/// Read-only surface — no mutations. Disable / re-enable / delete actions land
/// in task 3. The Explain action converts the focused `BackgroundItem` into a
/// synthetic `ScanResult` so the existing `AIExplanationController` can drive
/// the AI-fallback sheet without a parallel pipeline.
public struct BackgroundItemsView: View {
    @State private var session: BackgroundItemsSession
    @State private var expandedID: String?
    @State private var filter: BackgroundItemFilter = .all
    @State private var pendingAction: PendingBackgroundItemAction?
    @State private var lastError: String?
    private let onExplain: ((ScanResult) -> Void)?

    public init(
        onExplain: ((ScanResult) -> Void)? = nil,
        actionExecutor: (any BackgroundItemActionExecuting)? = nil
    ) {
        self.onExplain = onExplain
        self._session = State(
            initialValue: BackgroundItemsSession(actionExecutor: actionExecutor)
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScanResultsHeader(
                title: "Background Items",
                subtitle: subtitleText,
                subtitleStyle: .voice,
                onRescan: { Task { await session.scan() } },
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
            if session.scan == nil { await session.scan() }
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

    private var idleState: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Spacer()
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 36))
                .foregroundStyle(GargantuaColors.ink3)
            Text("Scan launch agents, daemons, and login items")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)
            Text("Read-only. Nothing changes until you say so.")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
            Button {
                Task { await session.scan() }
            } label: {
                Text("Start Scan")
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
        HStack(spacing: GargantuaSpacing.space3) {
            ForEach(BackgroundItemFilter.allCases, id: \.self) { option in
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

    private func runAction(_ pending: PendingBackgroundItemAction) async {
        let outcome = await session.perform(pending.action, on: pending.item)
        if !outcome.succeeded, let error = outcome.error {
            lastError = error
        }
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
