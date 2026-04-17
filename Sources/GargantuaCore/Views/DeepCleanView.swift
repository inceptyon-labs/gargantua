import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.gargantua.core", category: "DeepCleanView")

// MARK: - Deep Clean View

/// Full-system cleanup scan view.
///
/// Runs a deep scan against the YAML rule set using the active `CleanupProfile`,
/// then presents results in the three-bucket `ScanBucketListView` pattern.
public struct DeepCleanView: View {
    private let profile: CleanupProfile
    private let adapterOverride: (any ScanAdapter)?
    private let session: DeepCleanSessionState

    public init(
        profile: CleanupProfile = .deep,
        adapter: (any ScanAdapter)? = nil,
        session: DeepCleanSessionState
    ) {
        self.profile = profile
        self.adapterOverride = adapter
        self.session = session
    }

    @MainActor
    public init(profile: CleanupProfile = .deep, adapter: (any ScanAdapter)? = nil) {
        self.init(profile: profile, adapter: adapter, session: DeepCleanSessionState())
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if let result = session.cleanupResult {
                    CleanupSummaryView(result: result, onDismiss: dismissSummary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let results = session.scanResults {
                    resultsView(results)
                } else {
                    startView
                }
            }

            if session.isCleaning {
                cleaningOverlay
            }

            if session.showConfirmation, let results = session.scanResults {
                let selected = results.filter { session.selectedResultIDs.contains($0.id) }
                ConfirmationModalView(
                    items: selected,
                    onConfirm: { method in confirmCleanup(selected, method: method) },
                    onCancel: { session.showConfirmation = false }
                )
                .transition(.opacity)
            }
        }
        .background(GargantuaColors.void_)
        .animation(.easeOut(duration: 0.15), value: session.showConfirmation)
    }

    private var cleaningOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()

            VStack(spacing: GargantuaSpacing.space3) {
                ProgressView()
                    .controlSize(.regular)

                Text(session.activeCleanupMethod.progressTitle)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
            }
            .padding(GargantuaSpacing.space6)
            .background(GargantuaColors.surface3)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
    }

    // MARK: - Start View

    private var startView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Deep Clean")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)
                Spacer()
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space4)

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            // Description
            Spacer()

            VStack(spacing: GargantuaSpacing.space3) {
                Image(systemName: "bubbles.and.sparkles")
                    .font(.system(size: 36))
                    .foregroundStyle(GargantuaColors.ink3)

                Text("System Cleanup")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Text("Scans for browser caches, system logs, temp files, old installers, and other reclaimable space.")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Spacer()

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            // Scan button / progress
            scanFooter
        }
    }

    private var scanFooter: some View {
        Group {
            if session.isScanning {
                scanningFooter
            } else {
                idleFooter
            }
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
    }

    private var scanningFooter: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            ProgressView(value: session.scanProgress.fractionCompleted)
                .progressViewStyle(.linear)
                .animation(.easeInOut(duration: 0.15), value: session.scanProgress.fractionCompleted)

            HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space2) {
                Text(prettyScanCategory(session.scanProgress.currentCategory) ?? "Scanning...")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                if let path = session.scanProgress.currentPath {
                    Text("-")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                    Text(abbreviateHomePath(path))
                        .font(GargantuaFonts.monoPath)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: GargantuaSpacing.space2)

                Text("\(session.scanProgress.itemsFound) items")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
                    .monospacedDigit()

                if session.scanProgress.reclaimableBytes > 0 {
                    Text("-")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                    Text(AlertItem.formatBytes(session.scanProgress.reclaimableBytes))
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink2)
                }
            }
        }
    }

    @ViewBuilder
    private var idleFooter: some View {
        HStack {
            if session.scanProgress.errors.isEmpty == false {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(GargantuaColors.review)

                Text(session.scanProgress.errors.first ?? "Scan error")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.review)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: startScan) {
                Text("Start Deep Clean Scan")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(.white)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(GargantuaColors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Results

    private func resultsView(_ results: [ScanResult]) -> some View {
        VStack(spacing: 0) {
            // Back header
            HStack {
                Button {
                    session.clearResults()
                } label: {
                    HStack(spacing: GargantuaSpacing.space1) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Back")
                            .font(GargantuaFonts.label)
                    }
                    .foregroundStyle(GargantuaColors.accent)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Deep Clean")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Spacer()

                Button(action: refreshScan) {
                    HStack(spacing: GargantuaSpacing.space1) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Refresh")
                            .font(GargantuaFonts.label)
                    }
                    .foregroundStyle(GargantuaColors.accent)
                }
                .buttonStyle(.plain)
                .disabled(session.isScanning)
                .opacity(session.isScanning ? 0.5 : 1)
                .accessibilityLabel("Refresh Deep Clean Scan")
                .frame(minWidth: 78, alignment: .trailing)
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space3)

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            // Three-bucket scan results
            ScanBucketListView(
                results: results,
                scanDuration: session.scanDuration,
                selectedIDs: Binding(
                    get: { session.selectedResultIDs },
                    set: { session.selectedResultIDs = $0 }
                ),
                onClean: { session.showConfirmation = true },
                onCancel: { session.clearResults() }
            )
        }
    }

    // MARK: - Actions

    private func confirmCleanup(_ items: [ScanResult], method: CleanupMethod) {
        session.beginCleanup(method: method)
        Task {
            let engine = CleanupEngine()
            let result = await engine.clean(items, method: method)
            do {
                try AuditWriter().record(result: result)
            } catch {
                logger.warning("Failed to write audit entry: \(error.localizedDescription)")
            }
            session.finishCleanup(result: result)
        }
    }

    private func dismissSummary() {
        session.dismissSummary()
    }

    private func refreshScan() {
        startScan()
    }

    private func startScan() {
        session.prepareForScan()
        Task {
            let start = Date()
            do {
                let adapter: any ScanAdapter = try adapterOverride
                    ?? NativeScanAdapter.loadDefaults(profile: profile)
                let results = try await adapter.scan(progress: session.scanProgress)
                session.finishScan(results: results, duration: Date().timeIntervalSince(start))
            } catch {
                session.failScan(error.localizedDescription)
            }
        }
    }
}

// MARK: - Footer helpers

/// Turn a rule category like "browser_cache" into "Browser Cache" for the footer.
func prettyScanCategory(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    return raw
        .split(separator: "_")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}

/// Replace `$HOME` in an absolute path with `~` for display.
func abbreviateHomePath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") {
        return "~" + path.dropFirst(home.count)
    }
    return path
}
