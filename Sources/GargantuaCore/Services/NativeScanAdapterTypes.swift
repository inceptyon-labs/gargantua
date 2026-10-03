import AppKit
import Foundation

/// Abstraction over running-process detection for rule guards.
public protocol RunningProcessChecking: Sendable {
    func isRunning(identifier: String) -> Bool
}

/// Production process checker backed by AppKit's running application list and,
/// for command-line tools, the process table.
public struct DefaultRunningProcessChecker: RunningProcessChecking {
    public init() {}

    public func isRunning(identifier: String) -> Bool {
        let needle = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }

        let appMatch = NSWorkspace.shared.runningApplications.contains { app in
            let bundleID = app.bundleIdentifier?.lowercased()
            let localizedName = app.localizedName?.lowercased()
            let executableName = app.executableURL?
                .deletingPathExtension()
                .lastPathComponent
                .lowercased()

            return bundleID == needle
                || localizedName == needle
                || executableName == needle
        }
        if appMatch { return true }

        // Identifiers with a dot are bundle IDs, never executable names.
        guard !needle.contains(".") else { return false }

        // CLI tools such as `codex` never appear in runningApplications, so
        // they are matched by executable name across every process.
        return ProcessTable.pids().contains { pid in
            guard pid > 0, let path = ProcessTable.executablePath(for: pid) else { return false }
            return (path as NSString).lastPathComponent.lowercased() == needle
        }
    }
}
