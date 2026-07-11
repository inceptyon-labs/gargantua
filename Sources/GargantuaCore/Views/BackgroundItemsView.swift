import AppKit
import SwiftUI

// Top-level view for the Background Items review pane.
//
// Pre-selection (`preSelectedPlistPath`) lets Process Inventory navigate here
// for the "remove source" handoff — the row matching the plist path expands
// once the scan lands.
//
// Helpers are split across peer files (`BackgroundItemsView+Controls`,
// `+Triage`, `+Actions`, `+Types`); stored properties are internal rather than
// private so those cross-file extensions can reach them.
public struct BackgroundItemsView: View {
    @State var session: BackgroundItemsSession
    @State var expandedID: String?
    @State var filter: BackgroundItemFilter = .all
    @State var pendingAction: PendingBackgroundItemAction?
    @State var lastError: String?
    @Binding var preSelectedPlistPath: String?
    let onExplain: ((ScanResult) -> Void)?
    let onTriage: (([ScanResult]) -> Void)?

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
                // This scan is already fresh for the pending path — a miss
                // shouldn't trigger the rescan-once fallback on top of it.
                session.preSelectionRescanPath = preSelectedPlistPath
                await session.scan()
            }
            consumePendingPreSelection()
        }
        .onChange(of: preSelectedPlistPath) { _, newValue in
            // Re-trigger when Process Inventory navigates here a second time
            // for the same path — clearing then re-setting the binding makes
            // SwiftUI fire this even if the value matches the previous nil.
            if newValue != nil {
                // Each fresh handoff gets one rescan opportunity, even for a
                // path an earlier handoff already burned its rescan on.
                session.preSelectionRescanPath = nil
            }
            if preSelectedPlistPath != nil, session.scan == nil, !session.isScanning {
                session.preSelectionRescanPath = preSelectedPlistPath
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

    var subtitleText: String {
        if let scan = session.scan {
            let total = scan.items.count
            let review = scan.items.filter { $0.safety == .review }.count
            return "\(total) item\(total == 1 ? "" : "s") · \(review) need review"
        }
        if session.isScanning { return "Cataloging the things that linger after launch." }
        return "Trace what runs in the background. Decide what to trust."
    }

    var startView: some View {
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

    var scanningState: some View {
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
    func resultsState(_ scan: BackgroundItemScan) -> some View {
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
                                runtimeDetail: session.runtimeDetails[item.id],
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
                                },
                                onExpandDetail: { Task { await session.loadRuntimeDetail(for: item) } }
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
}
