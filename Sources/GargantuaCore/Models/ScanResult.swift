import Foundation

/// A single item discovered during a scan, carrying full Trust Layer metadata.
public struct ScanResult: Codable, Sendable, Identifiable {
    /// Unique identifier for this scan item (e.g., "chrome_cache_001").
    public let id: String

    /// Human-readable name (e.g., "Chrome Browser Cache").
    public let name: String

    /// Absolute file path.
    public let path: String

    /// Size in bytes.
    public let size: Int64

    /// Trust Layer safety classification.
    public var safety: SafetyLevel

    /// Confidence percentage (0–100) in the safety classification.
    public let confidence: Int

    /// One-line explanation of what this item is and why it's classified this way.
    public let explanation: String

    /// Source attribution — which app or system process created this.
    public let source: SourceAttribution

    /// When this file was last accessed.
    public let lastAccessed: Date?

    /// Scan category (e.g., "browser_cache", "dev_artifacts").
    public let category: String

    /// Tags for filtering and grouping.
    public let tags: [String]

    /// Whether this item can be regenerated (e.g., caches).
    public let regenerates: Bool

    /// Command to regenerate, if applicable (e.g., "npm install").
    public let regenerateCommand: String?

    /// Set when a running app holds this item open (e.g. a browser's cache while
    /// the browser runs). The item is surfaced but locked; quitting the app
    /// unblocks it. `nil` when nothing blocks removal.
    public var blockedByApp: BlockedApp?

    /// The owning rule's `skip_if_process_running` identifiers. Checked again at
    /// clean time, so an owner started after the scan still protects the item.
    /// `nil` when the rule names none.
    public var ownerProcesses: [String]?

    /// Where `path`'s parent directory chain resolved at scan time. Recorded
    /// by the scan pipeline so the pre-delete `SymlinkSwapGuard` can tell a
    /// legitimate symlink ancestor that already existed when the item was
    /// found (e.g. a symlinked scan root like `~/dev` → `/Volumes/Ext/dev`)
    /// from one swapped in after the scan. `nil` when the producing surface
    /// didn't record it; the guard then rejects any symlink ancestor.
    public var scanTimeResolvedParent: String?

    public init(
        id: String,
        name: String,
        path: String,
        size: Int64,
        safety: SafetyLevel,
        confidence: Int,
        explanation: String,
        source: SourceAttribution,
        lastAccessed: Date? = nil,
        category: String,
        tags: [String] = [],
        regenerates: Bool = false,
        regenerateCommand: String? = nil,
        blockedByApp: BlockedApp? = nil,
        ownerProcesses: [String]? = nil,
        scanTimeResolvedParent: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.safety = safety
        self.confidence = confidence
        self.explanation = explanation
        self.source = source
        self.lastAccessed = lastAccessed
        self.category = category
        self.tags = tags
        self.regenerates = regenerates
        self.regenerateCommand = regenerateCommand
        self.blockedByApp = blockedByApp
        self.ownerProcesses = ownerProcesses
        self.scanTimeResolvedParent = scanTimeResolvedParent
    }

    /// Returns a copy with the parent-chain resolution recorded, for the
    /// pre-delete symlink-swap guard. Must be called while the filesystem
    /// still reflects scan time — i.e. by the scan pipeline as results are
    /// returned, not at clean time. Non-filesystem items (command actions)
    /// and already-recorded results pass through unchanged.
    public func recordingScanTimeAncestry() -> ScanResult {
        guard scanTimeResolvedParent == nil, path.hasPrefix("/") else { return self }
        var copy = self
        copy.scanTimeResolvedParent = URL(fileURLWithPath: path)
            .standardizedFileURL
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .path
        return copy
    }
}

/// The running app that currently blocks an item from being removed.
public struct BlockedApp: Codable, Sendable, Equatable {
    /// Bundle identifier to terminate (e.g. "com.brave.Browser").
    public let bundleID: String
    /// Friendly name for the UI (e.g. "Brave Browser").
    public let name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Attribution for the app or process that created a scan item.
public struct SourceAttribution: Codable, Sendable, Equatable {
    /// Display name (e.g., "Google Chrome").
    public let name: String

    /// macOS bundle identifier, if known (e.g., "com.google.Chrome").
    public let bundleID: String?

    /// Whether the source binary's code signature should be verified.
    public let verifySignature: Bool

    public init(name: String, bundleID: String? = nil, verifySignature: Bool = false) {
        self.name = name
        self.bundleID = bundleID
        self.verifySignature = verifySignature
    }
}
