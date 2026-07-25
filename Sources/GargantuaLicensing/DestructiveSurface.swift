import Foundation

/// Conformance kept local to this file: `BlockReason` is a plain domain enum
/// in `LicenseState.swift`, and ``LicenseGate/authorize(_:)`` needs it as the
/// failure type of a `Result`.
extension BlockReason: Error {}

/// The registry of the destructive surfaces that cross four execution
/// boundaries: `CleanupEngine`, `UninstallExecutor`, the Spotlight orphan-rule
/// writer, and the Developer Tools command runner.
///
/// This is not documentation — it is load-bearing. Each case names a surface
/// that must obtain a ``DestructiveActionAuthorization`` before it can reach
/// one of those four. Adding a caller of them without adding a case here is a
/// compile error at the call site, not a review miss.
///
/// Two shipping features destroy user data outside that boundary and are
/// deliberately not enumerated here: Background Items
/// (`DefaultBackgroundItemTrasher`) and the File Organizer
/// (`OrganizerExecutor`). Whether they should require a license is a product
/// decision that has not been made; do not read their absence as coverage.
public enum DestructiveSurface: String, CaseIterable, Sendable {
    case deepClean
    case devArtifacts
    case aiModels
    case duplicateFinder
    case fileHealthContainers
    case cleanupRetry
    case developerTools
    case uninstaller
    case spotlightOrphanRules
    case mcpClean
    case claudeCodeAgent
}

/// Proof that ``LicenseGate/canExecuteDestructiveAction()`` was consulted and
/// allowed the operation.
///
/// The initializer is private to this file, so the only production way to
/// obtain a value is ``LicenseGate/authorize(_:)``. Destructive entry points
/// take one as a parameter; that makes the license gate structural — a surface
/// that forgets it does not compile — rather than a convention grep and human
/// diligence have to re-verify on every change.
public struct DestructiveActionAuthorization: Sendable, Equatable {
    public let surface: DestructiveSurface

    private init(surface: DestructiveSurface) {
        self.surface = surface
    }

    #if DEBUG
        /// Test-only mint that bypasses the license gate.
        ///
        /// Compiled out of release builds, so the bypass does not exist as a
        /// symbol in a shipped binary. SwiftPM builds test targets in debug, so
        /// tests keep it. `DestructiveSurfaceRegistryTests` additionally fails
        /// the build if any file under `Sources/` references it, catching a
        /// debug-only production call site.
        public static func unchecked(_ surface: DestructiveSurface) -> DestructiveActionAuthorization {
            DestructiveActionAuthorization(surface: surface)
        }
    #endif

    fileprivate static func granted(_ surface: DestructiveSurface) -> DestructiveActionAuthorization {
        DestructiveActionAuthorization(surface: surface)
    }
}

public extension LicenseGate {
    /// The only production mint for ``DestructiveActionAuthorization``.
    ///
    /// Callers pass the returned token to the destructive entry point. On
    /// failure the `BlockReason` drives the Unlock sheet (GUI) or the tool
    /// error (MCP) — the same reasons `canExecuteDestructiveAction()` returns.
    ///
    /// The decision is surface-independent today: `surface` labels the token
    /// for auditing, it does not scope its authority, so every surface gets the
    /// same answer. If tiered licensing ever makes the answer per-surface,
    /// every call site that does not check `authorization.surface` becomes a
    /// real hole and has to be revisited.
    func authorize(
        _ surface: DestructiveSurface
    ) async -> Result<DestructiveActionAuthorization, BlockReason> {
        if case .blocked(let reason) = await canExecuteDestructiveAction() {
            return .failure(reason)
        }
        return .success(.granted(surface))
    }
}
