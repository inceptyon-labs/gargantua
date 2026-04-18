import Foundation

/// Abstraction over scan backends (native YAML rules, future fclones/czkawka).
///
/// Views depend on `any ScanAdapter` so the underlying engine can be swapped
/// without touching the UI. Matches PRD §8.2 "Scan Engine (Abstraction)".
public protocol ScanAdapter: Sendable {
    /// Run a scan, reporting progress and returning discovered items.
    func scan(progress: ScanProgress?) async throws -> [ScanResult]

    /// Run a scan with an additional path-level event observer for the
    /// EventHorizon-style console. Default implementation ignores the
    /// observer; conformers that can emit per-path events override.
    func scan(
        progress: ScanProgress?,
        observer: (any ScanProgressObserving)?
    ) async throws -> [ScanResult]
}

extension ScanAdapter {
    public func scan(
        progress: ScanProgress?,
        observer: (any ScanProgressObserving)?
    ) async throws -> [ScanResult] {
        try await scan(progress: progress)
    }
}

/// Errors raised when building a scan adapter from app state.
public enum ScanAdapterError: Error, LocalizedError, Sendable {
    /// The `cleanup_rules` directory could not be located.
    case rulesDirectoryNotFound

    public var errorDescription: String? {
        switch self {
        case .rulesDirectoryNotFound:
            "cleanup_rules resource missing from GargantuaCore bundle. Set GARGANTUA_RULES_DIR to override."
        }
    }
}
