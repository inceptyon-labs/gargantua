import Foundation

/// Resolves where a running process came from by walking a confidence ladder
/// against the `LaunchdItemIndex`:
///
///   exact   — parent PID is launchd (1) AND a launchd item's executable
///             path matches the process's `proc_pidpath`.
///   path    — a launchd item's executable path matches the process's path,
///             regardless of who the process is parented under (helpers
///             relaunched out-of-band, fork trees, etc.).
///   heuristic — only the process basename / command name resembles a
///               launchd label; no path link.
///   unknown — nothing matches.
///
/// Pure function: takes pre-enumerated launchd items and returns the source
/// + confidence. No I/O, no globals; tests drive it from constants.
public struct ProcessLaunchSourceMatcher: Sendable {

    public init() {}

    public func match(
        executablePath: String?,
        command: String,
        parentPID: Int32,
        launchdItems: [LaunchdItem]
    ) -> (source: ProcessLaunchSource, confidence: LaunchSourceConfidence) {
        // 1. Path match — strongest signal. We try `Program` first then
        //    `programArguments[0]`, and only treat absolute paths as
        //    matchable; relative argv[0]s would create false positives across
        //    every process whose binary happens to share a common name.
        if let executablePath, !executablePath.isEmpty {
            for item in launchdItems {
                guard let plist = item.plist else { continue }
                if pathMatches(executablePath, plist: plist) {
                    let isLaunchdParent = (parentPID == 1)
                    return (
                        .launchd(domain: item.domain, label: plist.label, plistPath: item.plistPath),
                        isLaunchdParent ? .exact : .path
                    )
                }
            }
        }

        // 2. Heuristic match — process command name appears in a launchd
        //    label. Only fires when nothing matched by path.
        let commandLower = command.lowercased()
        if !commandLower.isEmpty {
            for item in launchdItems {
                guard let plist = item.plist else { continue }
                if labelResembles(plist.label, command: commandLower) {
                    return (
                        .launchd(domain: item.domain, label: plist.label, plistPath: item.plistPath),
                        .heuristic
                    )
                }
            }
        }

        // 3. Parent-based fallback. Parented under launchd (PID 1) but no
        //    plist matched: treat as user session helper. Otherwise it's a
        //    child of another process the inventory will surface separately.
        if parentPID == 1 {
            return (.userSession, .unknown)
        }
        if parentPID > 0 {
            return (.childProcess(parentPID: parentPID), .unknown)
        }
        return (.unknown, .unknown)
    }

    // MARK: - Helpers

    private func pathMatches(_ executablePath: String, plist: LaunchdPlist) -> Bool {
        if let program = plist.program, !program.isEmpty, program == executablePath {
            return true
        }
        if let argv0 = plist.programArguments.first,
           argv0.hasPrefix("/"),
           argv0 == executablePath {
            return true
        }
        return false
    }

    /// Returns `true` when the process command name and a launchd label share
    /// a meaningful overlap. We require the label to either end with the
    /// command (e.g. label `com.acme.helper` for command `helper`) or to
    /// match it exactly. Substring-anywhere would over-match — `com.apple.security`
    /// would tag every process named `security`.
    private func labelResembles(_ label: String, command: String) -> Bool {
        let labelLower = label.lowercased()
        if labelLower == command { return true }
        // Reverse-DNS labels: trailing component must match.
        if let lastDot = labelLower.lastIndex(of: ".") {
            let trailing = labelLower[labelLower.index(after: lastDot)...]
            if trailing == command { return true }
        }
        return false
    }
}
