import Foundation

/// Where on disk a launchd plist was sourced from.
///
/// The same `Label` can legitimately exist in multiple domains and refer to
/// distinct entities (a per-user agent and a system daemon, for example), so
/// dedupe must always include the domain.
public enum LaunchdDomain: String, Sendable, Equatable, Hashable, Codable {
    /// `~/Library/LaunchAgents/` — runs as the logged-in user.
    case userAgent = "user_agent"
    /// `/Library/LaunchAgents/` — runs as the user, installed system-wide.
    case systemAgent = "system_agent"
    /// `/Library/LaunchDaemons/` — runs as root, no user session required.
    case systemDaemon = "system_daemon"
    /// `/Library/StartupItems/` — legacy launchd entries.
    case startupItem = "startup_item"
}

/// Calendar-based start schedule (subset of `StartCalendarInterval` keys).
public struct LaunchdCalendarInterval: Sendable, Equatable, Codable {
    public let minute: Int?
    public let hour: Int?
    public let day: Int?
    public let weekday: Int?
    public let month: Int?

    public init(
        minute: Int? = nil,
        hour: Int? = nil,
        day: Int? = nil,
        weekday: Int? = nil,
        month: Int? = nil
    ) {
        self.minute = minute
        self.hour = hour
        self.day = day
        self.weekday = weekday
        self.month = month
    }
}

/// Parsed shape of a single `launchd` job plist.
///
/// Only the keys the Background Activity Review surface needs are extracted —
/// other keys (e.g. `EnvironmentVariables`, `LimitLoadToSessionType`) are
/// preserved in the raw dict for callers that need richer inspection.
public struct LaunchdPlist: Sendable, Equatable {
    /// `Label` — the canonical identifier of the job.
    public let label: String

    /// `Program` — single executable path. Mutually exclusive with the first
    /// element of `programArguments` in well-formed plists, but we accept both.
    public let program: String?

    /// `ProgramArguments` — argv vector, with `[0]` being the executable.
    public let programArguments: [String]

    /// `MachServices` keys — Mach service names this job advertises.
    public let machServices: [String]

    /// `Sockets` keys — top-level socket group names. The contents of each
    /// group (host/port/protocol/path) aren't extracted in this foundation
    /// pass.
    public let sockets: [String]

    /// `KeepAlive` — `true` for `<true/>` *or* a non-empty conditions dict
    /// (which is itself a directive to keep the job alive under conditions).
    public let keepAlive: Bool

    /// `RunAtLoad` — `true` if the job should run when launchd loads it.
    public let runAtLoad: Bool

    /// `StartInterval` — if set, the job runs every N seconds.
    public let startInterval: Int?

    /// `StartCalendarInterval` — calendar-based triggers. The plist allows
    /// either a single dict or an array of dicts; both are normalized here.
    public let startCalendarInterval: [LaunchdCalendarInterval]

    /// `WatchPaths` — paths whose modification triggers the job.
    public let watchPaths: [String]

    /// `QueueDirectories` — directories whose non-emptiness triggers the job.
    public let queueDirectories: [String]

    /// `Disabled` — if `true`, launchd will not load this job. Note: the
    /// authoritative disabled state is `launchctl print-disabled`, not this
    /// key, but the key is still useful to surface.
    public let disabled: Bool

    public init(
        label: String,
        program: String? = nil,
        programArguments: [String] = [],
        machServices: [String] = [],
        sockets: [String] = [],
        keepAlive: Bool = false,
        runAtLoad: Bool = false,
        startInterval: Int? = nil,
        startCalendarInterval: [LaunchdCalendarInterval] = [],
        watchPaths: [String] = [],
        queueDirectories: [String] = [],
        disabled: Bool = false
    ) {
        self.label = label
        self.program = program
        self.programArguments = programArguments
        self.machServices = machServices
        self.sockets = sockets
        self.keepAlive = keepAlive
        self.runAtLoad = runAtLoad
        self.startInterval = startInterval
        self.startCalendarInterval = startCalendarInterval
        self.watchPaths = watchPaths
        self.queueDirectories = queueDirectories
        self.disabled = disabled
    }

    /// First-choice executable path: `Program` if set, else `programArguments[0]`.
    public var executablePath: String? {
        if let program, !program.isEmpty { return program }
        return programArguments.first
    }
}

/// One entry in a `LaunchdItemIndex` enumeration.
///
/// `parseError` is non-nil for plist files we found on disk but couldn't
/// parse (corrupt, wrong root type, missing `Label`). Surfacing them rather
/// than silently dropping lets the UI tell the user "we saw 4 launchd items
/// we couldn't read" instead of showing a falsely complete inventory.
public struct LaunchdItem: Sendable, Equatable {
    public let domain: LaunchdDomain
    public let plistPath: String
    public let plist: LaunchdPlist?
    public let parseError: String?

    public init(
        domain: LaunchdDomain,
        plistPath: String,
        plist: LaunchdPlist? = nil,
        parseError: String? = nil
    ) {
        self.domain = domain
        self.plistPath = plistPath
        self.plist = plist
        self.parseError = parseError
    }
}
