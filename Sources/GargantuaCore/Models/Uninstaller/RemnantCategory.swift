import Foundation

/// Classification of files that an installed app leaves on disk.
///
/// Each category corresponds to a well-known macOS location family
/// (see `Library/Application Support`, `Library/Caches`, launch-agent
/// directories, etc.). The category drives a *default* SafetyLevel that
/// YAML remnant rules may override per-rule.
public enum RemnantCategory: String, Codable, Sendable, CaseIterable {
    /// `~/Library/Application Support/{AppName}/` and the sandboxed equivalent.
    case supportFiles = "support_files"

    /// `~/Library/Caches/{bundleID}/` and `~/Library/Caches/{AppName}/`.
    case caches

    /// `~/Library/Preferences/{bundleID}.plist` and scoped defaults domains.
    case preferences

    /// `~/Library/Containers/{bundleID}/` — sandbox container (user data).
    case containers

    /// `~/Library/Group Containers/{groupID}/` — shared-group sandbox data.
    case groupContainers = "group_containers"

    /// `~/Library/LaunchAgents/*.plist` and `/Library/LaunchAgents/*.plist`.
    case launchAgents = "launch_agents"

    /// `/Library/LaunchDaemons/*.plist` — system-wide daemons (admin).
    case launchDaemons = "launch_daemons"

    /// `~/Library/Logs/{AppName}/` and `/Library/Logs/{AppName}/`.
    case logs

    /// `~/Library/Saved Application State/{bundleID}.savedState/`.
    case savedState = "saved_state"

    /// Shared cookies and site-data partitions keyed to the app.
    case cookies

    /// WebKit / web-app storage partitions (IndexedDB, local storage).
    case webData = "web_data"

    /// Installed helper tools, privileged helpers, kernel extensions.
    case helpers

    /// Anything the rule author cannot classify into a better bucket.
    case other

    /// Default Trust Layer safety for this category before YAML overrides.
    ///
    /// After uninstall, caches/logs/saved state are generally safe to remove.
    /// Preferences, containers, launch agents carry user data or touch
    /// system integration, so default to `review`. Launch daemons run
    /// system-wide and default to `protected`.
    public var defaultSafety: SafetyLevel {
        switch self {
        case .supportFiles, .caches, .logs, .savedState, .webData:
            return .safe
        case .preferences, .containers, .groupContainers, .cookies,
             .launchAgents, .helpers, .other:
            return .review
        case .launchDaemons:
            return .protected_
        }
    }
}
