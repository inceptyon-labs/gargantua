import Foundation

/// Errors produced by `LaunchdPlistParser`.
public enum LaunchdPlistParserError: Error, Equatable, Sendable {
    /// The file at the given path could not be read off disk.
    case unreadable(String)
    /// The plist parsed but the root was not a dictionary.
    case rootNotDictionary
    /// The plist is missing the required `Label` key.
    case missingLabel
}

/// Parses a launchd job plist (XML, binary, or JSON-encoded) into `LaunchdPlist`.
public protocol LaunchdPlistParsing: Sendable {
    /// Parses the plist file at `plistURL`. Throws on read errors and on
    /// well-formed plists that aren't valid launchd jobs.
    func parse(plistURL: URL) throws -> LaunchdPlist

    /// Parses an already-decoded plist dictionary. Useful for tests.
    func parse(dictionary: [String: Any]) throws -> LaunchdPlist
}

/// Default parser using `PropertyListSerialization`.
public struct DefaultLaunchdPlistParser: LaunchdPlistParsing {
    public init() {}

    public func parse(plistURL: URL) throws -> LaunchdPlist {
        guard let data = try? Data(contentsOf: plistURL) else {
            throw LaunchdPlistParserError.unreadable(plistURL.path)
        }
        let raw = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dict = raw as? [String: Any] else {
            throw LaunchdPlistParserError.rootNotDictionary
        }
        return try parse(dictionary: dict)
    }

    public func parse(dictionary dict: [String: Any]) throws -> LaunchdPlist {
        guard let label = dict["Label"] as? String, !label.isEmpty else {
            throw LaunchdPlistParserError.missingLabel
        }

        let program = dict["Program"] as? String
        let programArguments = (dict["ProgramArguments"] as? [String]) ?? []

        let machServices: [String]
        if let raw = dict["MachServices"] as? [String: Any] {
            machServices = raw.keys.sorted()
        } else {
            machServices = []
        }

        let sockets: [String]
        if let raw = dict["Sockets"] as? [String: Any] {
            sockets = raw.keys.sorted()
        } else {
            sockets = []
        }

        let keepAlive: Bool
        if let raw = dict["KeepAlive"] {
            if let bool = raw as? Bool {
                keepAlive = bool
            } else if let conditions = raw as? [String: Any], !conditions.isEmpty {
                // Non-empty conditions dict means launchd is asked to keep it
                // alive under those conditions — treat as keep-alive on.
                keepAlive = true
            } else {
                keepAlive = false
            }
        } else {
            keepAlive = false
        }

        let runAtLoad = (dict["RunAtLoad"] as? Bool) ?? false
        let startInterval = dict["StartInterval"] as? Int

        let startCalendarInterval = parseCalendarIntervals(dict["StartCalendarInterval"])

        let watchPaths = (dict["WatchPaths"] as? [String]) ?? []
        let queueDirectories = (dict["QueueDirectories"] as? [String]) ?? []
        let disabled = (dict["Disabled"] as? Bool) ?? false

        return LaunchdPlist(
            label: label,
            program: program,
            programArguments: programArguments,
            machServices: machServices,
            sockets: sockets,
            keepAlive: keepAlive,
            runAtLoad: runAtLoad,
            startInterval: startInterval,
            startCalendarInterval: startCalendarInterval,
            watchPaths: watchPaths,
            queueDirectories: queueDirectories,
            disabled: disabled
        )
    }

    private func parseCalendarIntervals(_ raw: Any?) -> [LaunchdCalendarInterval] {
        if let dict = raw as? [String: Any] {
            return [calendarInterval(from: dict)]
        }
        if let array = raw as? [[String: Any]] {
            return array.map(calendarInterval(from:))
        }
        return []
    }

    private func calendarInterval(from dict: [String: Any]) -> LaunchdCalendarInterval {
        LaunchdCalendarInterval(
            minute: dict["Minute"] as? Int,
            hour: dict["Hour"] as? Int,
            day: dict["Day"] as? Int,
            weekday: dict["Weekday"] as? Int,
            month: dict["Month"] as? Int
        )
    }
}
