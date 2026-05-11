import Foundation

/// Scanner abstraction used by scheduled scans.
public protocol ScheduledScanScanning: Sendable {
    /// Runs a scan for the supplied profile and optional root URLs.
    func scan(profile: CleanupProfile, scanRoots: [URL]?) async throws -> [ScanResult]
}

/// Scheduled scan backend that delegates to the default profile scan pipeline.
public struct NativeScheduledScanScanner: ScheduledScanScanning {
    /// Creates a native scheduled scan backend.
    public init() {}

    /// Runs a scan for the supplied profile and optional root URLs.
    public func scan(profile: CleanupProfile, scanRoots: [URL]?) async throws -> [ScanResult] {
        let adapter = try ProfileScanAdapterFactory.make(profile: profile, scanRoots: scanRoots)
        return try await adapter.scan(progress: nil)
    }
}
