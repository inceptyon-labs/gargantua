import Foundation

/// Abstraction over scan backends (native YAML rules, Mole subprocess, future fclones/czkawka).
///
/// Views depend on `any ScanAdapter` so the underlying engine can be swapped
/// without touching the UI. Matches PRD §8.2 "Scan Engine (Abstraction)".
public protocol ScanAdapter: Sendable {
    /// Run a scan, reporting progress and returning discovered items.
    func scan(progress: ScanProgress?) async throws -> [ScanResult]
}

/// Errors raised when building a scan adapter from app state.
public enum ScanAdapterError: Error, LocalizedError, Sendable {
    /// The `cleanup_rules` directory could not be located.
    case rulesDirectoryNotFound

    public var errorDescription: String? {
        switch self {
        case .rulesDirectoryNotFound:
            "cleanup_rules directory not found. Set GARGANTUA_RULES_DIR or run from the project root."
        }
    }
}
