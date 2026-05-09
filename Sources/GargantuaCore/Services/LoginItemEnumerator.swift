import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "LoginItemEnumerator")

/// One modern login item / SMAppService record.
public struct LoginItemRecord: Sendable, Equatable {
    /// Display name reported by Background Task Management. May be the app
    /// name, the registering bundle name, or the login item label.
    public let name: String

    /// Bundle identifier that registered the item, if surfaced.
    public let bundleIdentifier: String?

    /// Resolved file URL for the registering bundle / executable, when present.
    public let url: URL?

    /// `Team Identifier` reported by Background Task Management.
    public let teamIdentifier: String?

    public init(
        name: String,
        bundleIdentifier: String? = nil,
        url: URL? = nil,
        teamIdentifier: String? = nil
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.url = url
        self.teamIdentifier = teamIdentifier
    }
}

/// Result of an enumeration pass. Carries a `needsPrivileges` flag so the UI
/// can hint that a richer list is available with `sudo sfltool dumpbtm`
/// without throwing on the no-output case.
public struct LoginItemEnumeration: Sendable, Equatable {
    public let records: [LoginItemRecord]
    public let needsPrivileges: Bool

    public init(records: [LoginItemRecord], needsPrivileges: Bool) {
        self.records = records
        self.needsPrivileges = needsPrivileges
    }

    public static let empty = LoginItemEnumeration(records: [], needsPrivileges: false)
}

/// Enumerates modern login items (SMAppService / Background Task Management).
public protocol LoginItemEnumerating: Sendable {
    func enumerate() -> LoginItemEnumeration
}

/// Default implementation backed by `/usr/bin/sfltool dumpbtm`.
///
/// macOS Sonoma+ requires root for the full dump; without it `sfltool` either
/// returns no records or refuses outright. Both cases collapse to
/// `LoginItemEnumeration(records: [], needsPrivileges: true)` so the UI can
/// surface the deep-link to System Settings rather than pretend the list is
/// authoritatively empty.
public struct DefaultLoginItemEnumerator: LoginItemEnumerating {
    public typealias Runner = @Sendable () -> (output: String, exitCode: Int32)

    private let runner: Runner

    public init(runner: @escaping Runner = DefaultLoginItemEnumerator.runSfltool) {
        self.runner = runner
    }

    public func enumerate() -> LoginItemEnumeration {
        let result = runner()
        let parsed = SfltoolDumpbtmParser.parse(result.output)

        // `needsPrivileges` is true when sfltool returned no usable output
        // AND something went wrong (non-zero exit OR completely empty output).
        // A successful run that genuinely produced zero records leaves the
        // flag false so the footer doesn't mislead users on a clean machine.
        let exitedCleanly = result.exitCode == 0
        let producedAnyOutput = !result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let needsPrivs = parsed.isEmpty && (!exitedCleanly || !producedAnyOutput)
        return LoginItemEnumeration(records: parsed, needsPrivileges: needsPrivs)
    }

    /// Production runner. Spawns `/usr/bin/sfltool dumpbtm` and captures
    /// stdout. Failures collapse to empty output rather than throwing — the
    /// caller's "best effort" contract treats the absence of records the same
    /// as the absence of permissions.
    @Sendable
    public static func runSfltool() -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sfltool")
        process.arguments = ["dumpbtm"]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        // Discard stderr — we don't surface it, and the default Pipe()'s
        // 64 KB buffer would deadlock the child if sfltool ever flooded
        // diagnostics there. /dev/null has unlimited capacity.
        process.standardError = FileHandle(forWritingAtPath: "/dev/null") ?? FileHandle.standardError

        do {
            try process.run()
        } catch {
            logger.warning("Failed to launch sfltool: \(String(describing: error), privacy: .public)")
            return ("", -1)
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output, process.terminationStatus)
    }
}

/// Permissive parser for `sfltool dumpbtm` text output.
///
/// `sfltool dumpbtm` emits a series of records separated by lines of `==`.
/// Each record contains `Key: Value` lines. The parser is intentionally lax:
/// it pulls Name / Identifier / URL / Team Identifier when present and skips
/// anything it doesn't understand. Format changes across macOS releases stay
/// recoverable as long as the field labels don't change.
public enum SfltoolDumpbtmParser {

    public static func parse(_ output: String) -> [LoginItemRecord] {
        let separator = "=========================================="
        let blocks: [String]
        if output.contains(separator) {
            blocks = output.components(separatedBy: separator)
        } else {
            // Fallback: blank-line separated blocks.
            blocks = output.components(separatedBy: "\n\n")
        }

        var records: [LoginItemRecord] = []
        for block in blocks {
            if let record = parseBlock(block) {
                records.append(record)
            }
        }
        return records
    }

    private static func parseBlock(_ block: String) -> LoginItemRecord? {
        var name: String?
        var bundleIdentifier: String?
        var url: URL?
        var teamIdentifier: String?

        for rawLine in block.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            switch key {
            case "Name", "Display Name":
                name = stripQuotes(value)
            case "Identifier", "Bundle Identifier":
                bundleIdentifier = stripQuotes(value)
            case "URL":
                let cleaned = stripQuotes(value)
                if let parsed = URL(string: cleaned) {
                    url = parsed
                }
            case "Team Identifier", "Team":
                teamIdentifier = stripQuotes(value)
            default:
                continue
            }
        }

        let display = name ?? bundleIdentifier
        guard let display, !display.isEmpty else { return nil }
        return LoginItemRecord(
            name: display,
            bundleIdentifier: bundleIdentifier,
            url: url,
            teamIdentifier: teamIdentifier
        )
    }

    private static func stripQuotes(_ value: String) -> String {
        var v = value
        if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }
}
