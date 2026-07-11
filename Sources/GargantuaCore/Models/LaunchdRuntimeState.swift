import Foundation

/// Best-effort launchd runtime facts for one background item. Every field is
/// optional because every source degrades independently. Runtime state is
/// display metadata — it must NEVER feed SafetyLevel classification.
public struct LaunchdRuntimeState: Sendable, Equatable {
    public let isLoaded: Bool?
    public let pid: Int?
    public let lastExitStatus: Int?
    /// launchd override-DB state (`launchctl print-disabled`), not the plist Disabled key.
    public let disabledOverride: Bool?

    public init(
        isLoaded: Bool?,
        pid: Int?,
        lastExitStatus: Int?,
        disabledOverride: Bool?
    ) {
        self.isLoaded = isLoaded
        self.pid = pid
        self.lastExitStatus = lastExitStatus
        self.disabledOverride = disabledOverride
    }
}

/// Deep facts from a lazy `launchctl print <domain>/<label>` on row expand.
public struct LaunchdRuntimeDetail: Sendable, Equatable {
    public let isLoaded: Bool?
    public let state: String?
    public let pid: Int?
    public let lastExitStatus: Int?

    public init(
        isLoaded: Bool?,
        state: String?,
        pid: Int?,
        lastExitStatus: Int?
    ) {
        self.isLoaded = isLoaded
        self.state = state
        self.pid = pid
        self.lastExitStatus = lastExitStatus
    }
}

extension LaunchdRuntimeState {
    /// "Running (PID 5036)" / "Loaded" / "Not loaded" / `nil` when every
    /// field is unknown — the caller omits the Runtime row in that case.
    public var runtimeDisplay: String? {
        if let pid {
            return "Running (PID \(pid))"
        }
        if let isLoaded {
            return isLoaded ? "Loaded" : "Not loaded"
        }
        return nil
    }
}

extension LaunchdRuntimeDetail {
    /// Prefers the deep `state` text ("running" -> "Running (PID 5036)",
    /// capitalized-first), else falls back to the same pid/isLoaded rules as
    /// `LaunchdRuntimeState.runtimeDisplay`.
    public var runtimeDisplay: String? {
        if let state {
            let capitalized = state.prefix(1).uppercased() + state.dropFirst()
            if let pid {
                return "\(capitalized) (PID \(pid))"
            }
            return capitalized
        }
        if let pid {
            return "Running (PID \(pid))"
        }
        if let isLoaded {
            return isLoaded ? "Loaded" : "Not loaded"
        }
        return nil
    }
}
