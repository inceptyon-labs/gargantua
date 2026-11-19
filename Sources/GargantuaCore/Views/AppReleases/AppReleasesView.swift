import AppKit
import SwiftUI

/// The App Updates page: checks installed apps against their update feeds,
/// Homebrew and the App Store, and installs updates it can verify.
public struct AppReleasesView: View {
    @Bindable var session: AppReleasesSession
    @State var pendingQuit: AppReleaseRow?
    @State var pendingSigner: AppReleasePendingSigner?
    @State var pendingUpdateAll: AppReleaseUpdateAllRequest?

    /// With one app, its row's own Update button does the same job.
    private static let minimumForUpdateAll = 2

    public init(session: AppReleasesSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            switch session.phase {
            case .idle:
                idleState
            case .checking where session.rows.isEmpty:
                checkingState
            case .failed(let message):
                failedState(message)
            case .checking, .ready:
                listState
            }
        }
        .background(GargantuaColors.void_)
        .destructiveActionGate(reason: $session.blockedReason)
        .onAppear { session.paneDidAppear() }
        .onDisappear { session.paneDidDisappear() }
        .alert(
            pendingQuit.map { "\($0.app.name) is open" } ?? "App is open",
            isPresented: Binding(
                get: { pendingQuit != nil },
                set: { if !$0 { pendingQuit = nil } }
            ),
            presenting: pendingQuit
        ) { row in
            Button("Quit and Update") {
                pendingQuit = nil
                Task { await session.install(row, quitIfRunning: true) }
            }
            Button("Cancel", role: .cancel) { pendingQuit = nil }
        } message: { row in
            Text("Quit \(row.app.name) to update? Unsaved work in it may be lost.")
        }
        .alert(
            pendingUpdateAll?.title ?? "Apps are open",
            isPresented: Binding(
                get: { pendingUpdateAll != nil },
                set: { if !$0 { pendingUpdateAll = nil } }
            ),
            presenting: pendingUpdateAll
        ) { request in
            Button("Quit and Update All") {
                pendingUpdateAll = nil
                startUpdateAll(request.rows, quitting: Set(request.openRows.map(\.id)))
            }
            if !request.closedRows.isEmpty {
                Button("Update Only Closed Apps") {
                    pendingUpdateAll = nil
                    startUpdateAll(request.closedRows, quitting: [])
                }
            }
            Button("Cancel", role: .cancel) { pendingUpdateAll = nil }
        } message: { request in
            Text(request.message)
        }
        .alert(
            pendingSigner?.title ?? "New signer",
            isPresented: Binding(
                get: { pendingSigner != nil },
                set: { if !$0 { pendingSigner = nil } }
            ),
            presenting: pendingSigner
        ) { pending in
            Button(pending.approveLabel) {
                pendingSigner = nil
                Task {
                    await session.approveSigner(pending.change, for: pending.row.id, quitIfRunning: pending.needsQuit)
                }
            }
            Button("Cancel", role: .cancel) { pendingSigner = nil }
        } message: { pending in
            Text(pending.message)
        }
        .alert("Allow Gargantua to update apps", isPresented: $session.showsAppManagementHelp) {
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(
                "macOS stops apps from updating other developers' apps until you allow them. "
                    + "Turn on Gargantua under Privacy & Security > App Management, then try the update again."
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        PageHeaderView(title: "App Updates", subtitle: subtitle) {
            switch session.phase {
            case .idle, .failed:
                EmptyView()
            case .checking, .ready:
                if session.isChecking, !session.rows.isEmpty {
                    GargantuaButton("Cancel") { session.cancelCheck() }
                }
                GargantuaButton("Check", icon: "arrow.clockwise", isDisabled: session.isChecking || session.isUpdatingAll) {
                    session.startCheck()
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Check for updates (⌘R)")
            }
        }
    }

    private var subtitle: String? {
        switch session.phase {
        case .idle, .checking:
            return nil
        case .failed:
            return "The check didn't finish."
        case .ready:
            let count = session.availableCount
            var parts: [String] = []
            if count > 0 { parts.append("\(count) update\(count == 1 ? "" : "s") available") }
            if session.failedCount > 0 { parts.append(Self.couldntCheck(session.failedCount)) }
            if let lastChecked = session.lastChecked {
                parts.append(Self.checkedText(lastChecked: lastChecked, now: Date(), capitalized: parts.isEmpty))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    static func checkedText(lastChecked: Date, now: Date, capitalized: Bool) -> String {
        let ago = now.timeIntervalSince(lastChecked) < 60
            ? "just now"
            : relativeFormatter.localizedString(for: lastChecked, relativeTo: now)
        return (capitalized ? "Checked " : "checked ") + ago
    }

    static func couldntCheck(_ count: Int) -> String {
        "\(count) couldn't be checked"
    }

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    // MARK: - States

    private var idleState: some View {
        centered {
            GargantuaBrandIcon(
                resourceName: "app-updates-gargantua-gpt2",
                fallbackSystemName: "arrow.down.app",
                fallbackColor: GargantuaColors.ink4
            )

            Text("Check your apps for updates")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)

            Text(
                "Contacts each app's update feed, Homebrew and the App Store. "
                    + "Apple receives the bundle IDs of your App Store apps; "
                    + "nothing else about your Mac is sent."
            )
            .font(GargantuaFonts.body)
            .foregroundStyle(GargantuaColors.ink2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 390)

            GargantuaButton("Check for updates", tone: .primary) { session.startCheck() }
                .keyboardShortcut("r", modifiers: .command)
                .padding(.top, GargantuaSpacing.space2)
        }
    }

    private var checkingState: some View {
        centered {
            AccretionDiskView(activityRate: 18, size: 36, color: GargantuaColors.accretion)
            Text("Reading installed apps and asking their update sources…")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
            GargantuaButton("Cancel") { session.cancelCheck() }
                .padding(.top, GargantuaSpacing.space2)
        }
    }

    private func failedState(_ message: String) -> some View {
        centered {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(GargantuaColors.review)
            Text(message)
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 390)
            GargantuaButton("Try again", tone: .primary) { session.startCheck() }
                .keyboardShortcut("r", modifiers: .command)
                .padding(.top, GargantuaSpacing.space2)
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension AppReleasesView {
    // MARK: - List

    private var listState: some View {
        let visible = session.visibleRows
        return VStack(spacing: 0) {
            PaneSearchField(placeholder: "Search by name or bundle ID", text: $session.query)
                .padding(.horizontal, GargantuaSpacing.space4)
                .padding(.top, GargantuaSpacing.space3)
                .padding(.bottom, GargantuaSpacing.space1)

            controlBar

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            if visible.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: GargantuaSpacing.space2) {
                        ForEach(visible) { row in
                            AppReleaseRowView(
                                row: row,
                                installPhase: session.installPhases[row.id],
                                updatesPaused: session.isChecking || session.isUpdatingAll,
                                message: session.rowMessages[row.id],
                                onUpdate: { requestUpdate(row) },
                                onTrustSigner: { change in
                                    pendingSigner = AppReleasePendingSigner(
                                        row: row,
                                        change: change,
                                        needsQuit: session.requiresQuitConsent(row)
                                    )
                                },
                                onIgnore: { session.ignore(row.id) },
                                onStopIgnoring: { Task { await session.unignore(row.id) } },
                                onSkip: { version in session.skip(version: version, for: row.id) },
                                onStopSkipping: { Task { await session.unskip(row.id) } }
                            )
                        }
                    }
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.vertical, GargantuaSpacing.space3)
                }
            }
        }
    }

    private var controlBar: some View {
        let updatable = session.updatableRows
        return HStack(spacing: GargantuaSpacing.space3) {
            Picker("Filter", selection: $session.filter) {
                ForEach(AppReleasesFilter.allCases, id: \.self) { option in
                    Text("\(option.label) \(session.count(for: option))").tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            Spacer()

            if let batch = session.batch {
                activity("Updating \(batch.current) of \(batch.total)…")
                if batch.waiting > 0 {
                    GargantuaButton("Stop") { session.stopUpdateAll() }
                        .help("Finish the app being updated and leave the rest")
                }
            } else {
                if session.isChecking {
                    activity("Checking…")
                } else if let summary = session.batchSummary {
                    Text(summary.text)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
                if updatable.count >= Self.minimumForUpdateAll {
                    GargantuaButton("Update All (\(updatable.count))", tone: .primary, isDisabled: session.isChecking) {
                        requestUpdateAll(updatable)
                    }
                    .help("Updates these apps one at a time. App Store apps and download links aren't included.")
                    .accessibilityLabel("Update all \(updatable.count) apps")
                }
            }
        }
        .frame(minHeight: Self.controlBarHeight)
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
    }

    /// Tall enough for a button, so the bar keeps its height when one goes away.
    private static let controlBarHeight: CGFloat = 32

    private func activity(_ text: String) -> some View {
        HStack(spacing: GargantuaSpacing.space3) {
            AccretionDiskView(activityRate: 18, size: 16, color: GargantuaColors.accretion)
            Text(text)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
        }
    }

    private var emptyState: some View {
        centered {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(GargantuaColors.ink3)
            Text(emptyMessage)
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 390)
            if showsAllShortcut {
                GargantuaButton("Show all apps") { session.filter = .all }
            }
        }
    }

    private var showsAllShortcut: Bool {
        session.query.isEmpty && session.filter == .updates && session.failedCount > 0
    }

    private var emptyMessage: String {
        if !session.query.isEmpty { return "No apps match the search." }
        switch session.filter {
        case .updates:
            let failed = session.failedCount
            if failed > 0 {
                return "Nothing to update · " + Self.couldntCheck(failed)
            }
            return "Every app Gargantua can check is up to date."
        case .all: return "No apps to show."
        case .ignored: return "You haven't ignored any apps or versions."
        }
    }

    // MARK: - Actions

    private func requestUpdateAll(_ rows: [AppReleaseRow]) {
        let open = rows.filter(session.requiresQuitConsent)
        if open.isEmpty {
            startUpdateAll(rows, quitting: [])
        } else {
            pendingUpdateAll = AppReleaseUpdateAllRequest(rows: rows, openRows: open)
        }
    }

    private func startUpdateAll(_ rows: [AppReleaseRow], quitting: Set<String>) {
        Task { await session.updateAll(rows, quitting: quitting) }
    }

    private func requestUpdate(_ row: AppReleaseRow) {
        if session.requiresQuitConsent(row) {
            pendingQuit = row
        } else {
            Task { await session.install(row, quitIfRunning: false) }
        }
    }
}
