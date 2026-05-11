import AppKit
import Foundation

/// Abstraction over running-process detection for rule guards.
public protocol RunningProcessChecking: Sendable {
    func isRunning(identifier: String) -> Bool
}

/// Production process checker backed by AppKit's running application list.
public struct DefaultRunningProcessChecker: RunningProcessChecking {
    public init() {}

    public func isRunning(identifier: String) -> Bool {
        let needle = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }

        return NSWorkspace.shared.runningApplications.contains { app in
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
    }
}
