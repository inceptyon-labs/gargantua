import Foundation
import Observation

/// State shared by ``DeveloperToolsView`` while users navigate around the app.
/// Mirrors the pattern used by `DeepCleanSessionState` / `DiskExplorerState` /
/// `SmartUninstallerViewModel` — owned by `MainContentView` for the app's
/// lifetime so a tab-away/tab-back round trip doesn't discard the scan.
@Observable @MainActor
public final class DeveloperToolsSessionState {
    public var phase: DeveloperToolsView.Phase = .idle
    public var pendingExecution: DeveloperToolsView.ExecutionRequest?
    public var executingOperationID: DeveloperToolCleanupOperation.ID?
    public var executionNotices: [DeveloperToolCleanupOperation.ID: DeveloperToolsView.ExecutionNotice] = [:]
    /// Tracks an in-flight Docker start/stop so the panel can show a busy
    /// state instead of a stale daemon-stopped CTA while the daemon comes up
    /// (or goes down).
    public var dockerLifecycleActivity: DeveloperToolsView.DockerLifecycleActivity?
    /// Bumped on every kickoff or return-to-idle so background scan tasks
    /// can detect that they've been superseded and bail rather than
    /// stomping the current phase.
    public var loadGeneration: Int = 0

    public init() {}
}
