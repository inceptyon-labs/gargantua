import Foundation
@testable import GargantuaCore

struct StubScheduledScanScanner: ScheduledScanScanning {
    let results: [ScanResult]

    func scan(profile: CleanupProfile, scanRoots: [URL]?) async throws -> [ScanResult] {
        results
    }
}

struct ThrowingScheduledScanScanner: ScheduledScanScanning {
    struct Failure: LocalizedError {
        var errorDescription: String? { "scan failed" }
    }

    func scan(profile: CleanupProfile, scanRoots: [URL]?) async throws -> [ScanResult] {
        throw Failure()
    }
}

struct EmptyMessageThrowingScanner: ScheduledScanScanning {
    struct Failure: LocalizedError {
        var errorDescription: String? { "" }
    }

    func scan(profile: CleanupProfile, scanRoots: [URL]?) async throws -> [ScanResult] {
        throw Failure()
    }
}

struct FixedScheduledScanPowerStateProvider: ScheduledScanPowerStateProviding {
    let isOnBattery: Bool

    func isOnBatteryPower() -> Bool {
        isOnBattery
    }
}

final class SpyScheduledScanNotifier: ScheduledScanNotificationDelivering, @unchecked Sendable {
    var delivered: [ScheduledScanSummary] = []

    func deliver(summary: ScheduledScanSummary) async {
        delivered.append(summary)
    }
}

final class SpyScheduledAgentAuditHook: ScheduledScanAgentAuditHook, @unchecked Sendable {
    var summaries: [ScheduledScanSummary] = []

    func run(summary: ScheduledScanSummary) async {
        summaries.append(summary)
    }
}
