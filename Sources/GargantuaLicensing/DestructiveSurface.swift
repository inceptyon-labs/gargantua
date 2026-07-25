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
/// one of those four. The compile-time guarantee is narrow but real: a caller
/// of `CleanupEngine.clean`, `UninstallExecutor`'s real run, the Spotlight
/// orphan-rule writer, or the Developer Tools command runner cannot invoke
/// them without presenting a token, so a surface that forgets the gate fails
/// to build. It is *not* a guarantee that nothing inside `GargantuaCore` can
/// touch the disk — module-internal helpers such as
/// `CleanupEngine.recycleSingle(url:item:)` and `deleteSingle(url:item:)`
/// delete files and take no token; they are reachable from other files in the
/// module and are covered only by the gate their callers pass through.
///
/// Three shipping features destroy user data outside that boundary and are
/// deliberately not enumerated here: Background Items
/// (`DefaultBackgroundItemTrasher`), the File Organizer (`OrganizerExecutor`),
/// and Disk Explorer's per-row "Move to Trash"
/// (`DirectoryRowView.moveToTrash()` and
/// `DirectoryTreemapCellView.moveToTrash()`, both calling
/// `NSWorkspace.shared.recycle` directly on the selected path). Whether they
/// should require a license is a product decision that has not been made; do
/// not read their absence as coverage.
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

/// What ``LicenseGate/authorize(_:)`` hands back: the token on success, the
/// `BlockReason` that drives the Unlock sheet (GUI) or the tool error (MCP) on
/// failure. Views and controllers that inject the call for testing express
/// their provider closures in terms of this so the shape is declared once.
public typealias DestructiveAuthorizationResult = Result<DestructiveActionAuthorization, BlockReason>

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
    ///
    /// That is also why the boundaries check `surface` inconsistently, and why
    /// making them uniform would be wrong. `UninstallExecutor` and the
    /// Spotlight orphan-rule writer mint and consume a token within the same
    /// call, so they can assert the surface matches as defense-in-depth.
    /// `CleanupEngine.clean` and `DeveloperToolsExecutionFlow.execute`
    /// legitimately accept a token minted elsewhere and forwarded in — the
    /// uninstaller's `WorkspaceUninstallRemover.moveToTrash` hands a
    /// `.uninstaller` token straight to `CleanupEngine.clean` — so they
    /// deliberately do not assert on it. The surface-independent decision is
    /// what makes that forwarding sound.
    func authorize(
        _ surface: DestructiveSurface
    ) async -> DestructiveAuthorizationResult {
        if case .blocked(let reason) = await canExecuteDestructiveAction() {
            return .failure(reason)
        }
        return .success(.granted(surface))
    }
}
