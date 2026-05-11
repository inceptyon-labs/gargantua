import Foundation

/// Caller-supplied view-model for the EventHorizon console.
///
/// Decouples the console from any specific phase enum so the same chrome can
/// be driven by Smart Uninstaller, Deep Clean, Dev Purge, etc. Each tool
/// derives a context from its own phase and passes it in.
public struct EventHorizonContext: Equatable {
    /// Top-bar label, e.g. `"ENDURANCE · UNINSTALL SEQUENCE"` or
    /// `"ENDURANCE · DEEP CLEAN SWEEP"`.
    public let header: String
    /// Inline target identifier shown after `TARGET:`, e.g. an app name or
    /// a profile name. Pass `"—"` when no target makes sense.
    public let target: String
    /// Subtitle line under the header (italic, paired with the activity disk).
    /// When `subtitlePool` is non-empty and `isInProgress` is true, the console
    /// rotates through the pool instead of showing this static value.
    public let subtitle: String
    /// Rotating pool of status lines shown during active work. Cycled every
    /// few seconds so the UI signals ongoing activity even between log events.
    /// Leave empty to show the static `subtitle` only.
    public let subtitlePool: [String]
    /// Whether the console is still working — drives the spinning indicator
    /// and the trailing animated ellipsis.
    public let isInProgress: Bool
    /// Whether the console is in the destructive phase — gates the spaghettify
    /// swallow effect on `.match` events.
    public let isExecuting: Bool
    /// Stable identity for `onChange` reset hooks. Distinct values trigger a
    /// re-anchoring of the executing-baseline and clear the swallowed set.
    public let phaseKey: String

    public init(
        header: String,
        target: String,
        subtitle: String,
        subtitlePool: [String] = [],
        isInProgress: Bool,
        isExecuting: Bool,
        phaseKey: String
    ) {
        self.header = header
        self.target = target
        self.subtitle = subtitle
        self.subtitlePool = subtitlePool
        self.isInProgress = isInProgress
        self.isExecuting = isExecuting
        self.phaseKey = phaseKey
    }
}
