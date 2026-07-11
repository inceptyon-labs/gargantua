import Foundation

/// One batched pass over launchd's runtime facts, captured up front so
/// `state(label:source:snapshot:)` can be a pure in-memory merge for every row
/// in the list instead of shelling out per-row.
public struct LaunchdRuntimeSnapshot: Sendable, Equatable {
    /// A single row from `launchctl list`.
    public struct ListedJob: Sendable, Equatable {
        public let pid: Int?
        public let lastExitStatus: Int?

        public init(pid: Int?, lastExitStatus: Int?) {
            self.pid = pid
            self.lastExitStatus = lastExitStatus
        }
    }

    /// Label -> job, from `launchctl list`.
    public let guiJobs: [String: ListedJob]
    /// Label -> disabled, from `launchctl print-disabled gui/<uid>`.
    public let guiOverrides: [String: Bool]
    /// Label -> disabled, from `launchctl print-disabled system`.
    public let systemOverrides: [String: Bool]
    /// `false` when `launchctl list` itself failed, so callers can tell
    /// "not running" apart from "we don't know".
    public let guiListAvailable: Bool

    public init(
        guiJobs: [String: ListedJob],
        guiOverrides: [String: Bool],
        systemOverrides: [String: Bool],
        guiListAvailable: Bool
    ) {
        self.guiJobs = guiJobs
        self.guiOverrides = guiOverrides
        self.systemOverrides = systemOverrides
        self.guiListAvailable = guiListAvailable
    }

    public static let empty = LaunchdRuntimeSnapshot(
        guiJobs: [:],
        guiOverrides: [:],
        systemOverrides: [:],
        guiListAvailable: false
    )
}

/// Batched launchd runtime facts (`snapshot`/`state`) plus lazy per-item
/// deep detail (`printDetail`) for the Background Items review pane.
///
/// Every method is best-effort: a failed or malformed `launchctl` call
/// degrades to `nil` fields, never an error. Runtime state is display
/// metadata only — it must never feed `SafetyLevel` classification.
public protocol LaunchdRuntimeStateProviding: Sendable {
    /// Run the small, fixed set of batch commands (`list`, two
    /// `print-disabled` calls) once per scan pass.
    func snapshot() -> LaunchdRuntimeSnapshot
    /// Lazy `launchctl print <domain>/<label>` for a single row, run only on
    /// row expand.
    func printDetail(label: String, source: BackgroundItemSource) -> LaunchdRuntimeDetail?
    /// Pure merge of a previously captured snapshot for one item. No I/O.
    func state(label: String, source: BackgroundItemSource, snapshot: LaunchdRuntimeSnapshot) -> LaunchdRuntimeState?
}

public struct DefaultLaunchdRuntimeStateProvider: LaunchdRuntimeStateProviding {
    private let launchctl: any LaunchctlRunning
    private let userIDProvider: @Sendable () -> uid_t?

    public init(
        launchctl: any LaunchctlRunning = DefaultLaunchctlRunner(),
        userIDProvider: @escaping @Sendable () -> uid_t? = { getuid() }
    ) {
        self.launchctl = launchctl
        self.userIDProvider = userIDProvider
    }

    // MARK: - Snapshot

    public func snapshot() -> LaunchdRuntimeSnapshot {
        let listResult = launchctl.run(["list"])
        let guiListAvailable = listResult.succeeded
        let guiJobs = guiListAvailable ? Self.parseList(listResult.stdout) : [:]

        // print-disabled needs a concrete uid; skip it (empty overrides)
        // rather than guessing when the caller can't tell us who's logged in.
        var guiOverrides: [String: Bool] = [:]
        if let uid = userIDProvider() {
            let guiDisabled = launchctl.run(["print-disabled", "gui/\(uid)"])
            if guiDisabled.succeeded {
                guiOverrides = Self.parsePrintDisabled(guiDisabled.stdout)
            }
        }

        let systemDisabled = launchctl.run(["print-disabled", "system"])
        let systemOverrides = systemDisabled.succeeded ? Self.parsePrintDisabled(systemDisabled.stdout) : [:]

        return LaunchdRuntimeSnapshot(
            guiJobs: guiJobs,
            guiOverrides: guiOverrides,
            systemOverrides: systemOverrides,
            guiListAvailable: guiListAvailable
        )
    }

    // MARK: - State merge

    public func state(
        label: String,
        source: BackgroundItemSource,
        snapshot: LaunchdRuntimeSnapshot
    ) -> LaunchdRuntimeState? {
        switch source {
        case .userLaunchAgent, .systemLaunchAgent:
            let job = snapshot.guiJobs[label]
            // A missing job when the list itself failed means "unknown", not
            // "not running" — only collapse to `false` when the list succeeded.
            let isLoaded: Bool? = snapshot.guiListAvailable ? (job != nil) : nil
            return nilIfAllFieldsNil(
                LaunchdRuntimeState(
                    isLoaded: isLoaded,
                    pid: job?.pid,
                    lastExitStatus: job?.lastExitStatus,
                    disabledOverride: snapshot.guiOverrides[label]
                )
            )
        case .launchDaemon:
            // The system domain isn't readable unprivileged in a batch pass;
            // only the override DB (world-readable) is available here.
            return nilIfAllFieldsNil(
                LaunchdRuntimeState(
                    isLoaded: nil,
                    pid: nil,
                    lastExitStatus: nil,
                    disabledOverride: snapshot.systemOverrides[label]
                )
            )
        case .startupItem, .loginItem:
            return nil
        }
    }

    private func nilIfAllFieldsNil(_ state: LaunchdRuntimeState) -> LaunchdRuntimeState? {
        let allNil = state.isLoaded == nil
            && state.pid == nil
            && state.lastExitStatus == nil
            && state.disabledOverride == nil
        return allNil ? nil : state
    }

    // MARK: - Print detail

    public func printDetail(label: String, source: BackgroundItemSource) -> LaunchdRuntimeDetail? {
        guard let domain = domainSpec(for: source) else { return nil }
        let result = launchctl.run(["print", "\(domain)/\(label)"])
        if result.succeeded {
            return Self.parsePrint(result.stdout)
        }
        if (result.stdout + result.stderr).contains("Could not find service") {
            return LaunchdRuntimeDetail(isLoaded: false, state: nil, pid: nil, lastExitStatus: nil)
        }
        return nil
    }

    private func domainSpec(for source: BackgroundItemSource) -> String? {
        switch source {
        case .userLaunchAgent, .systemLaunchAgent:
            guard let uid = userIDProvider() else { return nil }
            return "gui/\(uid)"
        case .launchDaemon:
            return "system"
        case .startupItem, .loginItem:
            return nil
        }
    }

    // MARK: - Parsers

    //
    // Pure string -> value. Tolerant: malformed lines are skipped, never
    // thrown/crashed on, so a launchd output-format quirk degrades a single
    // field to nil instead of losing the whole snapshot.

    /// `launchctl list` — tab-separated `PID\tStatus\tLabel` rows behind a
    /// header line.
    static func parseList(_ stdout: String) -> [String: LaunchdRuntimeSnapshot.ListedJob] {
        var lines = stdout.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return [:] }
        lines.removeFirst() // header: "PID\tStatus\tLabel"

        var result: [String: LaunchdRuntimeSnapshot.ListedJob] = [:]
        for rawLine in lines {
            let columns = rawLine.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 3 else { continue }
            let pidColumn = String(columns[0])
            let statusColumn = String(columns[1])
            let label = String(columns[2])
            let pid = pidColumn == "-" ? nil : Int(pidColumn)
            let lastExitStatus = Int(statusColumn)
            result[label] = LaunchdRuntimeSnapshot.ListedJob(pid: pid, lastExitStatus: lastExitStatus)
        }
        return result
    }

    /// `launchctl print-disabled <domain>` — lines shaped
    /// `"com.foo.bar" => disabled` (also `enabled`/`true`/`false`).
    static func parsePrintDisabled(_ stdout: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\"") else { continue }
            let remainder = String(line.dropFirst())
            guard let closeQuoteIndex = remainder.firstIndex(of: "\"") else { continue }
            let label = String(remainder[remainder.startIndex ..< closeQuoteIndex])
            guard !label.isEmpty else { continue }
            let afterLabel = String(remainder[remainder.index(after: closeQuoteIndex)...])
            guard let arrowRange = afterLabel.range(of: "=>") else { continue }
            let valueText = String(afterLabel[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            let token = valueText.split(separator: " ").first.map(String.init) ?? valueText
            switch token.lowercased() {
            case "disabled", "true":
                result[label] = true
            case "enabled", "false":
                result[label] = false
            default:
                continue
            }
        }
        return result
    }

    /// `launchctl print <domain>/<label>` — `key = value` lines. Only the
    /// keys we care about are extracted; everything else (including the
    /// header/braces) is ignored.
    static func parsePrint(_ stdout: String) -> LaunchdRuntimeDetail {
        var state: String?
        var pid: Int?
        var lastExitStatus: Int?

        for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard let equalsRange = line.range(of: "=") else { continue }
            let key = String(line[line.startIndex ..< equalsRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let value = String(line[equalsRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            switch key.lowercased() {
            case "state":
                state = value
            case "pid":
                pid = Int(value)
            case "last exit code", "last exit status":
                lastExitStatus = Int(value)
            default:
                continue
            }
        }

        return LaunchdRuntimeDetail(isLoaded: true, state: state, pid: pid, lastExitStatus: lastExitStatus)
    }
}
