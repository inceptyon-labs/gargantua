import Foundation
@testable import GargantuaCore

@MainActor
final class SpyUninstallRemover: UninstallRemoving {
    private(set) var removedPaths: [String] = []

    func moveToTrash(_ item: ScanResult) async -> CleanupItemResult {
        removedPaths.append(item.path)
        return CleanupItemResult(
            item: item,
            succeeded: true,
            trashURL: URL(fileURLWithPath: "/Users/test/.Trash/\(item.id)")
        )
    }
}

@MainActor
final class SpyPrivilegedUninstallHelper: PrivilegedUninstallHelping {
    private(set) var removedPaths: [String] = []
    private(set) var requests: [PrivilegedUninstallRequest] = []

    func movePrivilegedItemsToTrash(
        _ request: PrivilegedUninstallRequest,
        authorization: UninstallAuthorization
    ) async -> [CleanupItemResult] {
        requests.append(request)
        removedPaths.append(contentsOf: request.items.map(\.path))
        return request.items.map { item in
            let scanResult = ScanResult(
                id: item.id,
                name: URL(fileURLWithPath: item.path).lastPathComponent,
                path: item.path,
                size: item.size,
                safety: .review,
                confidence: 100,
                explanation: "Privileged test result",
                source: SourceAttribution(name: "Demo", bundleID: "com.example.Demo"),
                category: item.category
            )
            return CleanupItemResult(
                item: scanResult,
                succeeded: true,
                trashURL: URL(fileURLWithPath: "/Users/test/.Trash/\(item.id)")
            )
        }
    }
}

@MainActor
final class SpyProcessTerminator: RunningApplicationTerminating {
    private(set) var terminatedBundleIDs: [String] = []

    func terminateRunningApplications(bundleIdentifier: String, timeout: TimeInterval) async -> Bool {
        terminatedBundleIDs.append(bundleIdentifier)
        return true
    }
}

@MainActor
final class SpyUninstallAuditRecorder: UninstallAuditRecording {
    private(set) var entries: [AuditEntry] = []

    func write(_ entry: AuditEntry) throws {
        entries.append(entry)
    }
}
