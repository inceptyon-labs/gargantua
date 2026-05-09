import Foundation

/// Operation kind passed across the privileged boundary for Background Items.
///
/// Closed enum on purpose: any future addition lands here so the helper's
/// allowlist validator stays exhaustive.
public enum PrivilegedBackgroundItemOperation: String, Codable, Sendable {
    /// `launchctl bootout system/<label>` — stop the job and unload it.
    case bootoutDaemon = "bootout_daemon"
    /// `launchctl disable system/<label>` — refuse to load the job again.
    case disableDaemon = "disable_daemon"
    /// `launchctl enable system/<label>` — re-allow loading.
    case enableDaemon = "enable_daemon"
    /// `launchctl bootstrap system /Library/LaunchDaemons/<label>.plist` —
    /// re-load a previously booted-out job.
    case bootstrapDaemon = "bootstrap_daemon"
    /// Move a launchd plist (under `/Library/LaunchAgents/` or
    /// `/Library/LaunchDaemons/`) to the Trash.
    case trashLaunchPlist = "trash_launch_plist"
}

/// Request body for `performBackgroundItemAction(requestData:withReply:)`.
///
/// Keep this small and explicit — every field is independently validated by
/// the helper before any subprocess runs.
public struct PrivilegedBackgroundItemRequest: Codable, Sendable, Equatable {
    public let id: UUID
    public let operation: PrivilegedBackgroundItemOperation
    /// Job label, e.g. `com.acme.helper`. Required for every operation —
    /// also used by `trashLaunchPlist` to ensure the path matches the label.
    public let label: String
    /// Plist path. Required for `bootstrapDaemon` and `trashLaunchPlist`;
    /// optional context for the launchctl operations (carried for audit).
    public let plistPath: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        operation: PrivilegedBackgroundItemOperation,
        label: String,
        plistPath: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.operation = operation
        self.label = label
        self.plistPath = plistPath
        self.createdAt = createdAt
    }
}

/// Successful response payload for a Background Item privileged operation.
public struct PrivilegedBackgroundItemResponse: Codable, Sendable, Equatable {
    public let id: UUID
    public let succeeded: Bool
    /// Captured stdout from `launchctl` (or the trash result path) for audit.
    public let stdout: String?
    /// Captured stderr from `launchctl` for audit / surfacing failures.
    public let stderr: String?
    /// Process exit code for command-shaped operations. `nil` for trash ops.
    public let exitCode: Int32?
    /// On `trashLaunchPlist` success, the resulting Trash URL path.
    public let trashPath: String?
    /// Human-readable error if `succeeded == false` and the helper rejected
    /// the request before running.
    public let error: String?

    public init(
        id: UUID,
        succeeded: Bool,
        stdout: String? = nil,
        stderr: String? = nil,
        exitCode: Int32? = nil,
        trashPath: String? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.succeeded = succeeded
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.trashPath = trashPath
        self.error = error
    }
}
