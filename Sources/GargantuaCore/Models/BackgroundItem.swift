import Foundation

/// Where a `BackgroundItem` came from.
public enum BackgroundItemSource: Sendable, Equatable, Hashable, Codable {
    /// `~/Library/LaunchAgents` — runs as the logged-in user.
    case userLaunchAgent
    /// `/Library/LaunchAgents` — runs as the user, system-installed.
    case systemLaunchAgent
    /// `/Library/LaunchDaemons` — runs as root.
    case launchDaemon
    /// `/Library/StartupItems` — legacy.
    case startupItem
    /// Modern login item (SMAppService / `Background Task Management`).
    /// Read-only; control deep-links to System Settings → Login Items.
    case loginItem
}

extension BackgroundItemSource {
    /// Map a `LaunchdDomain` to the matching `BackgroundItemSource` so the UI
    /// model can be built without callers re-implementing the mapping.
    public init(domain: LaunchdDomain) {
        switch domain {
        case .userAgent: self = .userLaunchAgent
        case .systemAgent: self = .systemLaunchAgent
        case .systemDaemon: self = .launchDaemon
        case .startupItem: self = .startupItem
        }
    }

    /// Short label used in row metadata ("LaunchAgent", "Login Item", etc.).
    public var displayLabel: String {
        switch self {
        case .userLaunchAgent: "LaunchAgent (user)"
        case .systemLaunchAgent: "LaunchAgent (system)"
        case .launchDaemon: "LaunchDaemon"
        case .startupItem: "StartupItem"
        case .loginItem: "Login Item"
        }
    }
}

/// Reasons / tags layered on top of `SafetyLevel`. A `BackgroundItem` can carry
/// any combination of these — they are advisory metadata, not classification.
public enum BackgroundItemReason: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// The plist points at a binary that no longer exists on disk.
    case orphaned
    /// Binary has no valid signature (or signature could not be evaluated).
    case unsigned
    /// Apple-signed and located under `/System/` or `/usr/`, or `com.apple.*`.
    case system
    /// Vendor falls into a sensitive category (VPN, password manager, MDM, etc.).
    case sensitiveVendor = "sensitive_vendor"
    /// The launchd item declares `Disabled = true`.
    case disabledFlag = "disabled_flag"
    /// Item registered itself as a Mach service or socket — it's listening.
    case listensForRequests = "listens_for_requests"
    /// Item runs at load (boot/login) or has a keep-alive directive.
    case persistentlyRunning = "persistently_running"
    /// Item is scheduled to run on an interval or calendar.
    case scheduled
    /// Item was installed by an `.app` whose bundle was not found.
    case orphanedVendor = "orphaned_vendor"

    /// Human-readable label for tag chips.
    public var displayLabel: String {
        switch self {
        case .orphaned: "Orphaned"
        case .unsigned: "Unsigned"
        case .system: "System"
        case .sensitiveVendor: "Sensitive Vendor"
        case .disabledFlag: "Disabled"
        case .listensForRequests: "Listens"
        case .persistentlyRunning: "Always Running"
        case .scheduled: "Scheduled"
        case .orphanedVendor: "Orphaned Vendor"
        }
    }
}

/// Unified UI model for the Background Items review pane.
///
/// Combines launchd plist items and modern login items into a single record so
/// the row list doesn't have to switch on source kind for every render.
/// Read-only — no actions live here. Mutations land in task 3.
public struct BackgroundItem: Sendable, Equatable, Identifiable {
    /// Stable identifier suitable for SwiftUI `ForEach` and selection state.
    /// Built from `(source, label, plistPath)` so re-scans produce stable IDs.
    public let id: String

    /// `Label` (for launchd items) or display label (for login items).
    public let label: String

    /// Where this item came from.
    public let source: BackgroundItemSource

    /// On-disk plist path for launchd items, or a synthetic identifier for
    /// login items (e.g. the BTM dump path, or `nil` if not surfaced).
    public let plistPath: String?

    /// First-choice executable path: `Program` or `programArguments[0]`.
    /// `nil` for SMAppService-backed items (BundleProgram needs a bundle path
    /// the plist doesn't store) or for login items where only the bundle is
    /// known.
    public let executablePath: String?

    /// Resolved binary identity, or `nil` if no executable could be located.
    /// Carries vendor classification, signing identity, sensitive-category set.
    public let identity: BinaryIdentity?

    /// Trust Layer safety classification.
    public let safety: SafetyLevel

    /// Advisory tags layered on top of `safety`. Order is not significant.
    public let reasons: Set<BackgroundItemReason>

    /// One-line deterministic explanation. Always populated; AI fallback runs
    /// on top of this when the user requests it.
    public let explanation: String

    /// `true` when the executable referenced by the plist no longer exists on
    /// disk. Carried separately from `reasons` because the row's right-side
    /// vendor column rendering depends on it.
    public let isOrphaned: Bool

    public init(
        id: String,
        label: String,
        source: BackgroundItemSource,
        plistPath: String?,
        executablePath: String?,
        identity: BinaryIdentity?,
        safety: SafetyLevel,
        reasons: Set<BackgroundItemReason>,
        explanation: String,
        isOrphaned: Bool
    ) {
        self.id = id
        self.label = label
        self.source = source
        self.plistPath = plistPath
        self.executablePath = executablePath
        self.identity = identity
        self.safety = safety
        self.reasons = reasons
        self.explanation = explanation
        self.isOrphaned = isOrphaned
    }

    /// Display name used by the row's primary line. Prefers vendor display
    /// name when known, then bundle name, then label.
    public var displayName: String {
        if let identity, let display = identity.vendorDisplayName, !display.isEmpty {
            return display
        }
        if let identity, let bundleName = identity.bundleName, !bundleName.isEmpty {
            return bundleName
        }
        return label
    }
}
