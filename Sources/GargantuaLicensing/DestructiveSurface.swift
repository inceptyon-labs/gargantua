import Foundation

/// Conformance kept local to this file: `BlockReason` is a plain domain enum
/// in `LicenseState.swift`, and ``LicenseGate/authorize(_:)`` needs it as the
/// failure type of a `Result`.
extension BlockReason: Error {}

/// The registry of every code path in Gargantua that destroys user data.
///
/// This is not documentation — it is load-bearing. Each case names a surface
/// that must obtain a ``DestructiveActionAuthorization`` before it can reach
/// `CleanupEngine`, `UninstallExecutor`, the Spotlight rule writer, or the
/// Developer Tools command executor. Adding a destructive surface without
/// adding a case here is a compile error at the call site, not a review miss.
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

    /// Test-only mint that bypasses the license gate.
    ///
    /// Production code must never call this: `DestructiveSurfaceRegistryTests`
    /// fails the build if any file under `Sources/` references it.
    public static func unchecked(_ surface: DestructiveSurface) -> DestructiveActionAuthorization {
        DestructiveActionAuthorization(surface: surface)
    }

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
    func authorize(
        _ surface: DestructiveSurface
    ) async -> Result<DestructiveActionAuthorization, BlockReason> {
        if case .blocked(let reason) = await canExecuteDestructiveAction() {
            return .failure(reason)
        }
        return .success(.granted(surface))
    }
}
