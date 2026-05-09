import Foundation

/// Errors produced by `LaunchdPlistParser`.
public enum LaunchdPlistParserError: Error, Equatable, Sendable {
    /// The file at the given path could not be read off disk.
    case unreadable(String)
    /// The file is larger than the parser's size cap; refused to read.
    case oversized(path: String, size: Int)
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
    /// Maximum plist file size we'll attempt to parse, in bytes. launchd plists
    /// are kilobyte-scale in practice; this cap keeps a hostile or pathological
    /// plist from exhausting memory during enumeration. 1 MiB is ~100x larger
    /// than the largest plists observed in the wild.
    public static let maxPlistSize: Int = 1 << 20

    public init() {}

    public func parse(plistURL: URL) throws -> LaunchdPlist {
        let attrs = try? FileManager.default.attributesOfItem(atPath: plistURL.path)
        if let size = (attrs?[.size] as? NSNumber)?.intValue, size > Self.maxPlistSize {
            throw LaunchdPlistParserError.oversized(path: plistURL.path, size: size)
        }
        guard let data = try? Data(contentsOf: plistURL) else {
            throw LaunchdPlistParserError.unreadable(plistURL.path)
        }
        if data.count > Self.maxPlistSize {
            throw LaunchdPlistParserError.oversized(path: plistURL.path, size: data.count)
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
        let bundleProgram = dict["BundleProgram"] as? String

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
            if let bool = Self.coerceBool(raw) {
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

        let runAtLoad = Self.coerceBool(dict["RunAtLoad"]) ?? false
        let startInterval = Self.coerceInt(dict["StartInterval"])

        let startCalendarInterval = parseCalendarIntervals(dict["StartCalendarInterval"])

        let watchPaths = (dict["WatchPaths"] as? [String]) ?? []
        let queueDirectories = (dict["QueueDirectories"] as? [String]) ?? []
        let disabled = Self.coerceBool(dict["Disabled"]) ?? false

        return LaunchdPlist(
            label: label,
            program: program,
            programArguments: programArguments,
            bundleProgram: bundleProgram,
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
            minute: Self.coerceInt(dict["Minute"]),
            hour: Self.coerceInt(dict["Hour"]),
            day: Self.coerceInt(dict["Day"]),
            weekday: Self.coerceInt(dict["Weekday"]),
            month: Self.coerceInt(dict["Month"])
        )
    }

    /// Property lists round-trip booleans through `NSNumber`, so a `<true/>`
    /// element bridges back as `Bool` cleanly — but a numeric `<integer>0</integer>`
    /// won't cast to `Bool` directly. Some legacy plists encode booleans as
    /// `0` / `1` integers; coerce both shapes.
    private static func coerceBool(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        if let bool = value as? Bool { return bool }
        if let int = value as? Int { return int != 0 }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    /// Coerce numeric plist values that may bridge as `Int`, `Int64`, or
    /// `NSNumber` depending on the plist format.
    private static func coerceInt(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
