import Foundation

/// How confidently a process was tied back to its launching mechanism.
public enum LaunchSourceConfidence: String, Sendable, Equatable, Hashable, Codable {
    /// The process is parented under launchd (PID 1) AND the launchd item's
    /// executable path matches the process's `proc_pidpath`.
    case exact
    /// The process's executable path matches a launchd item's `Program` /
    /// `programArguments[0]`, but launchd is not the parent (e.g. respawned
    /// helper, fork tree).
    case path
    /// Only the process basename / command name resembles a launchd label —
    /// no path link.
    case heuristic
    /// No link to any known launching mechanism.
    case unknown

    public var displayLabel: String {
        switch self {
        case .exact: "Exact"
        case .path: "Path"
        case .heuristic: "Heuristic"
        case .unknown: "Unknown"
        }
    }
}

/// What launched a process. Carries enough back-reference for the row UI to
/// deep-link to the source plist when one was found.
public enum ProcessLaunchSource: Sendable, Equatable, Hashable {
    /// Linked back to a `LaunchdItem`.
    case launchd(domain: LaunchdDomain, label: String, plistPath: String)
    /// User session helper / login shell — parent is `loginwindow` or PID 1
    /// but no launchd plist matched. Treated as user-controllable.
    case userSession
    /// Foreground / GUI app (parented under `launchd` but presents UI).
    case foregroundApp
    /// The process is a child of another tracked process (its PID lineage
    /// roots at a non-launchd ancestor).
    case childProcess(parentPID: Int32)
    /// Nothing tied this process to a launching mechanism.
    case unknown

    /// On-disk plist path when the source is a launchd item — used by the row
    /// UI for "Reveal launching plist in Finder".
    public var plistPath: String? {
        switch self {
        case let .launchd(_, _, plistPath): plistPath
        default: nil
        }
    }

    /// Short label for badges / row metadata.
    public var displayLabel: String {
        switch self {
        case let .launchd(domain, _, _):
            switch domain {
            case .userAgent: "LaunchAgent (user)"
            case .systemAgent: "LaunchAgent (system)"
            case .systemDaemon: "LaunchDaemon"
            case .startupItem: "StartupItem"
            }
        case .userSession: "User Session"
        case .foregroundApp: "Foreground App"
        case .childProcess: "Child Process"
        case .unknown: "Unknown Source"
        }
    }
}

/// Advisory tags layered on top of a `ProcessItem`'s `safety` level. These are
/// metadata, not classification — multiple can apply to one process.
public enum ProcessReason: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Apple-signed and rooted under `/System/` or `/usr/`.
    case system
    /// Vendor falls into a sensitive category (VPN, password manager, MDM, etc.).
    case sensitiveVendor = "sensitive_vendor"
    /// Binary has no valid signature.
    case unsigned
    /// Process is running as UID 0.
    case rootProcess = "root_process"
    /// The launching launchd plist's executable was not found on disk
    /// (the process is alive but its source is gone — typical for stale
    /// helpers from uninstalled apps).
    case orphaned
    /// Process basename / launchd label belongs to a foreground app.
    case foregroundApp = "foreground_app"

    public var displayLabel: String {
        switch self {
        case .system: "System"
        case .sensitiveVendor: "Sensitive Vendor"
        case .unsigned: "Unsigned"
        case .rootProcess: "Root"
        case .orphaned: "Orphaned"
        case .foregroundApp: "Foreground"
        }
    }
}

/// Which metric the inventory list is currently sorted by.
public enum ProcessSortMetric: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case cpu
    case rss

    public var displayLabel: String {
        switch self {
        case .cpu: "CPU"
        case .rss: "Memory"
        }
    }
}

/// Unified UI model for one process in the inventory.
///
/// Snapshot only — no live updates. The scanner produces a fresh list each
/// scan; rows do not observe per-process changes.
public struct ProcessItem: Sendable, Equatable, Identifiable {
    /// Stable identifier suitable for SwiftUI `ForEach`. Built from
    /// `(pid, executablePath ?? command)` so re-scans of the same long-lived
    /// process keep their expansion / selection state, but a recycled PID
    /// gets a different id when its binary differs.
    public let id: String

    /// Process ID at the time of the snapshot.
    public let pid: Int32

    /// Parent process ID at the time of the snapshot.
    public let parentPID: Int32

    /// Process start time in Unix epoch seconds, captured at snapshot time.
    /// Used by `ProcessActionExecutor` to detect PID recycling between
    /// SIGTERM and the SIGKILL fallback — if the start time changes between
    /// snapshots, the original process is gone and the recycled PID belongs
    /// to an unrelated process that we must not signal.
    public let startTimeUnixSeconds: UInt64

    /// Short command name (`pbi_comm` from `PROC_PIDTBSDINFO`). May be
    /// truncated to 16 bytes by Darwin — that's fine for the row's
    /// "fall back to command" path.
    public let command: String

    /// Owning user UID.
    public let uid: UInt32

    /// Resolved owning user name when the host can look it up; falls back to
    /// the numeric UID otherwise.
    public let owningUser: String

    /// Full executable path from `proc_pidpath`, or `nil` if the call failed
    /// (typical for kernel tasks the caller can't introspect).
    public let executablePath: String?

    /// CPU usage as a fraction of one core. `0.5` means half a core; on
    /// multi-core machines this can exceed `1.0` for multi-threaded processes.
    public let cpuFraction: Double

    /// Resident memory in bytes.
    public let residentBytes: UInt64

    /// Resolved binary identity. `nil` when no executable path was available
    /// or the resolver could not bind it to anything (e.g. unsigned helper
    /// outside any bundle).
    public let identity: BinaryIdentity?

    /// Where this process came from — launchd item, user session, etc.
    public let launchSource: ProcessLaunchSource

    /// How confidently the launch source was determined.
    public let launchConfidence: LaunchSourceConfidence

    /// Trust Layer safety classification.
    public let safety: SafetyLevel

    /// Advisory tags layered on top of `safety`.
    public let reasons: Set<ProcessReason>

    /// One-line deterministic explanation. AI fallback runs on top of this.
    public let explanation: String

    public init(
        id: String,
        pid: Int32,
        parentPID: Int32,
        startTimeUnixSeconds: UInt64,
        command: String,
        uid: UInt32,
        owningUser: String,
        executablePath: String?,
        cpuFraction: Double,
        residentBytes: UInt64,
        identity: BinaryIdentity?,
        launchSource: ProcessLaunchSource,
        launchConfidence: LaunchSourceConfidence,
        safety: SafetyLevel,
        reasons: Set<ProcessReason>,
        explanation: String
    ) {
        self.id = id
        self.pid = pid
        self.parentPID = parentPID
        self.startTimeUnixSeconds = startTimeUnixSeconds
        self.command = command
        self.uid = uid
        self.owningUser = owningUser
        self.executablePath = executablePath
        self.cpuFraction = cpuFraction
        self.residentBytes = residentBytes
        self.identity = identity
        self.launchSource = launchSource
        self.launchConfidence = launchConfidence
        self.safety = safety
        self.reasons = reasons
        self.explanation = explanation
    }

    /// Display name used by the row's primary line. Prefers vendor display
    /// name → bundle name → command.
    public var displayName: String {
        if let identity, let display = identity.vendorDisplayName, !display.isEmpty {
            return display
        }
        if let identity, let bundleName = identity.bundleName, !bundleName.isEmpty {
            return bundleName
        }
        return command
    }
}
