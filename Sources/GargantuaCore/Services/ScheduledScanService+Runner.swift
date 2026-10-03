import Foundation

@MainActor
/// Runs scheduled scans, records summaries, and dispatches notifications.
public final class ScheduledScanRunner {
    private let persistence: PersistenceController
    private let scanner: any ScheduledScanScanning
    private let notifier: any ScheduledScanNotificationDelivering
    private let powerStateProvider: any ScheduledScanPowerStateProviding
    private let agentAuditHook: any ScheduledScanAgentAuditHook
    private let now: () -> Date

    /// Creates a runner with production scanner, notifier, power, and audit dependencies.
    public convenience init(persistence: PersistenceController) {
        self.init(
            persistence: persistence,
            scanner: NativeScheduledScanScanner(),
            notifier: defaultScheduledScanNotifier(),
            powerStateProvider: SystemScheduledScanPowerStateProvider(),
            agentAuditHook: MaintenanceEngineAuditHook(),
            now: Date.init
        )
    }

    /// Creates a runner with injected dependencies for tests or alternate schedulers.
    public init(
        persistence: PersistenceController,
        scanner: any ScheduledScanScanning,
        notifier: any ScheduledScanNotificationDelivering,
        powerStateProvider: any ScheduledScanPowerStateProviding,
        agentAuditHook: any ScheduledScanAgentAuditHook = NoopScheduledScanAgentAuditHook(),
        now: @escaping () -> Date
    ) {
        self.persistence = persistence
        self.scanner = scanner
        self.notifier = notifier
        self.powerStateProvider = powerStateProvider
        self.agentAuditHook = agentAuditHook
        self.now = now
    }

    /// Runs a scheduled scan when enabled, due, and permitted by power settings.
    public func runIfDue() async -> ScheduledScanRunResult {
        do {
            try persistence.bootstrap()
            let settings = try persistence.fetchSettings()
            let configuration = ScheduledScanConfiguration(settings: settings)
            let runDate = now()

            guard configuration.isEnabled else { return .disabled }
            guard configuration.isDue(now: runDate) else { return .notDue }

            if configuration.skipWhenOnBattery, powerStateProvider.isOnBatteryPower() {
                return .skippedOnBattery
            }

            let profiles = try persistence.fetchProfiles()
            let profile = CleanupProfile.resolve(
                activeProfileID: configuration.profileID,
                persisted: profiles,
                fallback: .light
            )
            let roots = ScanRootSettings.resolvedURLs(from: settings.scanRoots)
            let exclusions = try PathExclusionMatcher(patterns: persistence.fetchExclusionEntries().map(\.pattern))
            let results = try await exclusions.filter(scanner.scan(
                profile: profile,
                scanRoots: roots.isEmpty ? nil : roots
            ))
            let actionable = results.filter(\.safety.isActionable)
            let reclaimableBytes = actionable.reduce(Int64(0)) { $0 + $1.size }
            let summary = ScheduledScanSummary(
                date: runDate,
                profileID: profile.id,
                itemCount: actionable.count,
                reclaimableBytes: reclaimableBytes
            )
            try persistence.recordScheduledScanSummary(summary)
            await notifier.deliver(summary: summary)
            await agentAuditHook.run(summary: summary)
            return .completed(summary)
        } catch {
            let runDate = now()
            // Read the previously-recorded error before overwriting it: a failed
            // run no longer advances the schedule clock (so the next attempt
            // isn't pushed a full interval out), which means a persistent
            // failure — e.g. revoked Full Disk Access — is retried every poll
            // interval. Notify only when the error changes so the user isn't
            // alerted every ~15 minutes for the same unresolved problem.
            let priorError = (try? persistence.fetchSettings())?.scheduledScanLastSummaryError
            // Failure is signalled downstream by a non-empty errorMessage (the
            // persistence clock-guard and the summary headline both key off it),
            // so guarantee one even in the unlikely case localizedDescription is
            // empty — otherwise this failure would be misread as a success.
            let description = error.localizedDescription
            let summary = ScheduledScanSummary(
                date: runDate,
                profileID: "unknown",
                itemCount: 0,
                reclaimableBytes: 0,
                errorMessage: description.isEmpty ? "Scheduled scan failed" : description
            )
            do {
                try persistence.recordScheduledScanSummary(summary)
            } catch {
                PersistenceDiagnostics.logFailure("recordScheduledScanSummary", error: error)
            }
            if summary.errorMessage != priorError {
                await notifier.deliver(summary: summary)
            }
            return .failed(summary)
        }
    }
}

private func defaultScheduledScanNotifier() -> any ScheduledScanNotificationDelivering {
    #if os(macOS)
        return UserNotificationScheduledScanNotifier()
    #else
        return NoopScheduledScanNotifier()
    #endif
}
