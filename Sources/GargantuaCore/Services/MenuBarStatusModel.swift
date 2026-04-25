import Combine
import Foundation

public protocol MenuBarStatusScanning: Sendable {
    func scan(profile: CleanupProfile, scanRoots: [URL]?) async throws -> [ScanResult]
}

public struct NativeMenuBarStatusScanner: MenuBarStatusScanning {
    public init() {}

    public func scan(profile: CleanupProfile, scanRoots: [URL]?) async throws -> [ScanResult] {
        let adapter = try NativeScanAdapter.loadDefaults(profile: profile, scanRoots: scanRoots)
        return try await adapter.scan(progress: nil)
    }
}

public struct MenuBarStatusSnapshot: Equatable, Sendable {
    public var isScanning: Bool
    public var lastScanDate: Date?
    public var reclaimableBytes: Int64
    public var pendingAlertCount: Int
    public var pendingItemCount: Int
    public var snoozedUntil: Date?
    public var errorMessage: String?

    public init(
        isScanning: Bool = false,
        lastScanDate: Date? = nil,
        reclaimableBytes: Int64 = 0,
        pendingAlertCount: Int = 0,
        pendingItemCount: Int = 0,
        snoozedUntil: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.isScanning = isScanning
        self.lastScanDate = lastScanDate
        self.reclaimableBytes = reclaimableBytes
        self.pendingAlertCount = pendingAlertCount
        self.pendingItemCount = pendingItemCount
        self.snoozedUntil = snoozedUntil
        self.errorMessage = errorMessage
    }

    public static let empty = MenuBarStatusSnapshot()

    public var reclaimableDisplay: String {
        AlertItem.formatBytes(reclaimableBytes)
    }

    public var alertsDisplay: String {
        if let snoozedUntil {
            return "Snoozed until \(snoozedUntil.formatted(date: .omitted, time: .shortened))"
        }
        if pendingAlertCount == 1 {
            return "1 pending"
        }
        return "\(pendingAlertCount) pending"
    }

    public var lastScanDisplay: String {
        guard let lastScanDate else { return "No scan yet" }
        return lastScanDate.formatted(date: .abbreviated, time: .shortened)
    }

    public var statusDisplay: String {
        if isScanning { return "Scanning..." }
        if errorMessage != nil { return "Needs attention" }
        if pendingAlertCount > 0 { return "Alerts pending" }
        return "Ready"
    }

    public var canSnoozeAlerts: Bool {
        pendingAlertCount > 0
    }

    public var accessibilitySummary: String {
        if isScanning {
            return "Gargantua menu bar, quick scan running"
        }
        let alertPhrase = pendingAlertCount == 1 ? "1 pending alert" : "\(pendingAlertCount) pending alerts"
        return "Gargantua menu bar, \(reclaimableDisplay) reclaimable, \(alertPhrase)"
    }
}

@MainActor
public final class MenuBarStatusModel: ObservableObject {
    @Published public private(set) var snapshot: MenuBarStatusSnapshot

    private let scanner: any MenuBarStatusScanning
    private let makePersistence: @MainActor () throws -> PersistenceController
    private let defaults: UserDefaults
    private let now: () -> Date
    private let snoozeInterval: TimeInterval
    private var quickScanSummary: MenuBarStatusSummary?

    public init(
        scanner: any MenuBarStatusScanning = NativeMenuBarStatusScanner(),
        makePersistence: @escaping @MainActor () throws -> PersistenceController = { try PersistenceController() },
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        snoozeInterval: TimeInterval = 86_400
    ) {
        self.scanner = scanner
        self.makePersistence = makePersistence
        self.defaults = defaults
        self.now = now
        self.snoozeInterval = snoozeInterval
        self.snapshot = .empty
    }

    public func refresh() async {
        do {
            let persistence = try makePersistence()
            try persistence.bootstrap()
            let summary = try bestSummary(from: persistence)
            snapshot = makeSnapshot(summary: summary, isScanning: false, errorMessage: nil)
        } catch {
            snapshot = makeSnapshot(summary: quickScanSummary, isScanning: false, errorMessage: error.localizedDescription)
        }
    }

    public func runQuickScan() async {
        snapshot = MenuBarStatusSnapshot(
            isScanning: true,
            lastScanDate: snapshot.lastScanDate,
            reclaimableBytes: snapshot.reclaimableBytes,
            pendingAlertCount: snapshot.pendingAlertCount,
            pendingItemCount: snapshot.pendingItemCount,
            snoozedUntil: snapshot.snoozedUntil,
            errorMessage: nil
        )

        do {
            let persistence = try makePersistence()
            try persistence.bootstrap()
            let settings = try persistence.fetchSettings()
            let scanRoots = ScanRootSettings.resolvedURLs(from: settings.scanRoots)
            let rootsOverride = scanRoots.isEmpty ? nil : scanRoots
            let runDate = now()
            let results = try await scanner.scan(profile: .light, scanRoots: rootsOverride)
            let alerts = AlertItem.aggregate(from: results, referenceDate: runDate)
            let itemCount = alerts.reduce(0) { $0 + $1.itemCount }
            let reclaimableBytes = alerts.reduce(Int64(0)) { $0 + $1.reclaimableSize }
            let summary = MenuBarStatusSummary(
                date: runDate,
                itemCount: itemCount,
                reclaimableBytes: reclaimableBytes,
                alertCount: alerts.count,
                errorMessage: nil
            )

            quickScanSummary = summary
            defaults.removeObject(forKey: MenuBarPreferences.alertsSnoozedUntilKey)
            var persistenceErrorMessage: String?
            do {
                try persistence.updateSettings { settings in
                    settings.lastScanDate = runDate
                }
            } catch {
                PersistenceDiagnostics.logFailure("updateSettings lastScanDate", error: error)
                persistenceErrorMessage = error.localizedDescription
            }
            snapshot = makeSnapshot(summary: summary, isScanning: false, errorMessage: persistenceErrorMessage)
        } catch {
            snapshot = makeSnapshot(summary: quickScanSummary, isScanning: false, errorMessage: error.localizedDescription)
        }
    }

    public func snoozeAlerts() {
        guard snapshot.pendingAlertCount > 0 else { return }
        let until = now().addingTimeInterval(snoozeInterval)
        defaults.set(until.timeIntervalSince1970, forKey: MenuBarPreferences.alertsSnoozedUntilKey)
        snapshot = MenuBarStatusSnapshot(
            isScanning: snapshot.isScanning,
            lastScanDate: snapshot.lastScanDate,
            reclaimableBytes: snapshot.reclaimableBytes,
            pendingAlertCount: 0,
            pendingItemCount: snapshot.pendingItemCount,
            snoozedUntil: until,
            errorMessage: snapshot.errorMessage
        )
    }

    private func bestSummary(from persistence: PersistenceController) throws -> MenuBarStatusSummary? {
        let settings = try persistence.fetchSettings()
        let scheduledSummary = try persistence.fetchPendingScheduledScanSummary().map(MenuBarStatusSummary.init(scheduledSummary:))
        let lastScanSummary = settings.lastScanDate.map {
            MenuBarStatusSummary(
                date: $0,
                itemCount: 0,
                reclaimableBytes: 0,
                alertCount: 0,
                errorMessage: nil
            )
        }

        return [quickScanSummary, scheduledSummary]
            .compactMap { $0 }
            .max { $0.date < $1.date }
            ?? lastScanSummary
    }

    private func makeSnapshot(
        summary: MenuBarStatusSummary?,
        isScanning: Bool,
        errorMessage: String?
    ) -> MenuBarStatusSnapshot {
        let referenceDate = now()
        let snoozedUntil = activeSnoozedUntil(now: referenceDate)
        let rawAlertCount = summary?.alertCount ?? 0
        let pendingAlertCount = snoozedUntil == nil ? rawAlertCount : 0

        return MenuBarStatusSnapshot(
            isScanning: isScanning,
            lastScanDate: summary?.date,
            reclaimableBytes: summary?.reclaimableBytes ?? 0,
            pendingAlertCount: pendingAlertCount,
            pendingItemCount: summary?.itemCount ?? 0,
            snoozedUntil: snoozedUntil,
            errorMessage: errorMessage ?? summary?.errorMessage
        )
    }

    private func activeSnoozedUntil(now: Date) -> Date? {
        let rawValue = defaults.double(forKey: MenuBarPreferences.alertsSnoozedUntilKey)
        guard rawValue > 0 else { return nil }

        let date = Date(timeIntervalSince1970: rawValue)
        if date <= now {
            defaults.removeObject(forKey: MenuBarPreferences.alertsSnoozedUntilKey)
            return nil
        }
        return date
    }
}

private struct MenuBarStatusSummary: Equatable {
    let date: Date
    let itemCount: Int
    let reclaimableBytes: Int64
    let alertCount: Int
    let errorMessage: String?

    init(
        date: Date,
        itemCount: Int,
        reclaimableBytes: Int64,
        alertCount: Int,
        errorMessage: String?
    ) {
        self.date = date
        self.itemCount = itemCount
        self.reclaimableBytes = reclaimableBytes
        self.alertCount = alertCount
        self.errorMessage = errorMessage
    }

    init(scheduledSummary: ScheduledScanSummary) {
        let hasError = scheduledSummary.errorMessage?.isEmpty == false
        self.init(
            date: scheduledSummary.date,
            itemCount: scheduledSummary.itemCount,
            reclaimableBytes: scheduledSummary.reclaimableBytes,
            alertCount: hasError || scheduledSummary.itemCount > 0 ? 1 : 0,
            errorMessage: scheduledSummary.errorMessage
        )
    }
}
