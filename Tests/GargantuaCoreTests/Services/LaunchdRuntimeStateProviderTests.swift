import Foundation
import Testing
@testable import GargantuaCore

@Suite("LaunchdRuntimeStateProvider")
struct LaunchdRuntimeStateProviderTests {

    // MARK: - Fake

    private struct Scripted {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Scripts `LaunchctlResult`s by argument-vector prefix. Matches the
    /// longest scripted prefix that the actual invocation starts with, so a
    /// test can script `["print-disabled", "gui/501"]` without also pinning
    /// exact trailing arguments where it doesn't matter.
    final class FakeLaunchctl: LaunchctlRunning, @unchecked Sendable {
        nonisolated(unsafe) private var _calls: [[String]] = []
        nonisolated(unsafe) private var _scripts: [[String]: Scripted] = [:]
        private let lock = NSLock()

        var calls: [[String]] { lock.withLock { _calls } }
        var callCount: Int { lock.withLock { _calls.count } }

        func script(prefix: [String], exitCode: Int32 = 0, stdout: String = "", stderr: String = "") {
            lock.withLock { _scripts[prefix] = Scripted(exitCode: exitCode, stdout: stdout, stderr: stderr) }
        }

        func run(_ arguments: [String]) -> LaunchctlResult {
            lock.withLock { _calls.append(arguments) }
            let scripts = lock.withLock { _scripts }
            let matched = scripts
                .filter { arguments.starts(with: $0.key) }
                .max { $0.key.count < $1.key.count }
            guard let scripted = matched?.value else {
                return LaunchctlResult(arguments: arguments, exitCode: 0, stdout: "", stderr: "")
            }
            return LaunchctlResult(
                arguments: arguments,
                exitCode: scripted.exitCode,
                stdout: scripted.stdout,
                stderr: scripted.stderr
            )
        }
    }

    // MARK: - Fixtures (captured live via `launchctl`)

    private static let listFixture = """
    PID\tStatus\tLabel
    878\t0\tapplication.com.microsoft.VSCode.1002026983.1002026989
    -\t0\tcom.apple.SafariHistoryServiceAgent
    -\t-9\tcom.apple.progressd
    """

    private static let printDisabledFixture = """
    \tdisabled services = {
    \t\t"com.docker.helper" => enabled
    \t\t"com.bjango.istatmenus.agent" => disabled
    \t\t"com.avast.userinit" => true
    \t}
    """

    private static let printFixture = """
    gui/501/com.bjango.istatmenus-setapp.agent = {
    \tactive count = 4
    \tpath = /Users/Jason/Library/LaunchAgents/com.bjango.istatmenus-setapp.agent.plist
    \ttype = LaunchAgent
    \tstate = running

    \tprogram = /Users/.../iStat Menus Helper
    \tpid = 5036
    \truns = 1
    }
    """

    // MARK: - parseList

    @Test("parseList extracts pid, exit status, and label; skips the header row")
    func parseListFixture() {
        let result = DefaultLaunchdRuntimeStateProvider.parseList(Self.listFixture)
        #expect(result.count == 3)

        let vsCode = result["application.com.microsoft.VSCode.1002026983.1002026989"]
        #expect(vsCode?.pid == 878)
        #expect(vsCode?.lastExitStatus == 0)

        let safari = result["com.apple.SafariHistoryServiceAgent"]
        #expect(safari?.pid == nil)
        #expect(safari?.lastExitStatus == 0)

        let progressd = result["com.apple.progressd"]
        #expect(progressd?.pid == nil)
        #expect(progressd?.lastExitStatus == -9)
    }

    @Test("parseList returns empty for empty input")
    func parseListEmpty() {
        #expect(DefaultLaunchdRuntimeStateProvider.parseList("").isEmpty)
    }

    @Test("parseList skips malformed lines but keeps well-formed ones")
    func parseListGarbage() {
        let input = "PID\tStatus\tLabel\nmalformed line without tabs\n1\t2\n879\t0\tcom.example.good\n"
        let result = DefaultLaunchdRuntimeStateProvider.parseList(input)
        #expect(result.count == 1)
        #expect(result["com.example.good"]?.pid == 879)
    }

    // MARK: - parsePrintDisabled

    @Test("parsePrintDisabled maps disabled/enabled/true/false to booleans")
    func parsePrintDisabledFixture() {
        let result = DefaultLaunchdRuntimeStateProvider.parsePrintDisabled(Self.printDisabledFixture)
        #expect(result.count == 3)
        #expect(result["com.docker.helper"] == false)
        #expect(result["com.bjango.istatmenus.agent"] == true)
        #expect(result["com.avast.userinit"] == true)
    }

    @Test("parsePrintDisabled returns empty for garbage input")
    func parsePrintDisabledGarbage() {
        let garbage = "\tdisabled services = {\n\tnot a quoted line\n\t\"unterminated => disabled\n\t}\n"
        #expect(DefaultLaunchdRuntimeStateProvider.parsePrintDisabled(garbage).isEmpty)
    }

    // MARK: - parsePrint

    @Test("parsePrint extracts state, pid; missing keys stay nil")
    func parsePrintFixture() {
        let detail = DefaultLaunchdRuntimeStateProvider.parsePrint(Self.printFixture)
        #expect(detail.isLoaded == true)
        #expect(detail.state == "running")
        #expect(detail.pid == 5036)
        #expect(detail.lastExitStatus == nil)
    }

    @Test("parsePrint on empty stdout yields all-nil fields but isLoaded true")
    func parsePrintEmpty() {
        let detail = DefaultLaunchdRuntimeStateProvider.parsePrint("")
        #expect(detail.isLoaded == true)
        #expect(detail.state == nil)
        #expect(detail.pid == nil)
        #expect(detail.lastExitStatus == nil)
    }

    @Test("parsePrint accepts the 'last exit status' alias and treats non-numeric values as nil")
    func parsePrintExitStatusAlias() {
        let numeric = DefaultLaunchdRuntimeStateProvider.parsePrint(
            "gui/501/com.example.agent = {\n\tlast exit status = 0\n}\n"
        )
        #expect(numeric.lastExitStatus == 0)

        let nonNumeric = DefaultLaunchdRuntimeStateProvider.parsePrint(
            "gui/501/com.example.agent = {\n\tlast exit code = (never exited)\n}\n"
        )
        #expect(nonNumeric.lastExitStatus == nil)
    }

    // MARK: - snapshot()

    @Test("snapshot degrades isLoaded to nil (not false) when launchctl list fails")
    func snapshotListFailureDegradesIsLoaded() {
        let fake = FakeLaunchctl()
        fake.script(prefix: ["list"], exitCode: 1, stdout: "", stderr: "some failure")
        fake.script(
            prefix: ["print-disabled", "gui/501"],
            stdout: "\t\"com.example.agent\" => disabled\n"
        )
        fake.script(prefix: ["print-disabled", "system"], stdout: "")
        let provider = DefaultLaunchdRuntimeStateProvider(launchctl: fake, userIDProvider: { 501 })

        let snapshot = provider.snapshot()
        #expect(snapshot.guiListAvailable == false)
        #expect(snapshot.guiJobs.isEmpty)

        // Override is present so the merged state isn't collapsed to nil,
        // letting us assert isLoaded specifically stayed nil (unknown),
        // not false (known not running).
        let state = provider.state(label: "com.example.agent", source: .userLaunchAgent, snapshot: snapshot)
        #expect(state?.isLoaded == nil)
        #expect(state?.disabledOverride == true)
    }

    @Test("snapshot merges list rows, gui overrides, and system overrides on success")
    func snapshotSuccessMergesValues() {
        let fake = FakeLaunchctl()
        fake.script(prefix: ["list"], stdout: Self.listFixture)
        fake.script(prefix: ["print-disabled", "gui/501"], stdout: Self.printDisabledFixture)
        fake.script(
            prefix: ["print-disabled", "system"],
            stdout: "\tdisabled services = {\n\t\t\"com.daemon.thing\" => disabled\n\t}\n"
        )
        let provider = DefaultLaunchdRuntimeStateProvider(launchctl: fake, userIDProvider: { 501 })

        let snapshot = provider.snapshot()
        #expect(snapshot.guiListAvailable == true)
        #expect(snapshot.guiJobs.count == 3)
        #expect(snapshot.guiOverrides["com.bjango.istatmenus.agent"] == true)
        #expect(snapshot.systemOverrides["com.daemon.thing"] == true)
    }

    @Test("snapshot skips the gui print-disabled call when the uid is unknown")
    func snapshotSkipsGuiOverridesWithoutUID() {
        let fake = FakeLaunchctl()
        fake.script(prefix: ["list"], stdout: Self.listFixture)
        fake.script(prefix: ["print-disabled", "system"], stdout: "")
        let provider = DefaultLaunchdRuntimeStateProvider(launchctl: fake, userIDProvider: { nil })

        let snapshot = provider.snapshot()
        #expect(snapshot.guiOverrides.isEmpty)
        #expect(snapshot.guiListAvailable == true)
        #expect(fake.calls.contains { $0.first == "list" })
        #expect(fake.calls.contains { $0 == ["print-disabled", "system"] })
        #expect(!fake.calls.contains { $0.first == "print-disabled" && $0.last?.hasPrefix("gui/") == true })
    }

    // MARK: - state()

    @Test("state merges pid, exit status, and override for a user launch agent")
    func stateAgentMergesFields() {
        let snapshot = LaunchdRuntimeSnapshot(
            guiJobs: ["com.example.agent": LaunchdRuntimeSnapshot.ListedJob(pid: 42, lastExitStatus: 0)],
            guiOverrides: ["com.example.agent": true],
            systemOverrides: [:],
            guiListAvailable: true
        )
        let provider = DefaultLaunchdRuntimeStateProvider(launchctl: FakeLaunchctl(), userIDProvider: { 501 })

        let state = provider.state(label: "com.example.agent", source: .userLaunchAgent, snapshot: snapshot)
        #expect(state?.isLoaded == true)
        #expect(state?.pid == 42)
        #expect(state?.lastExitStatus == 0)
        #expect(state?.disabledOverride == true)
    }

    @Test("state for a launch daemon exposes only disabledOverride")
    func stateDaemonOnlyOverride() {
        let snapshot = LaunchdRuntimeSnapshot(
            guiJobs: [:],
            guiOverrides: [:],
            systemOverrides: ["com.example.daemon": false],
            guiListAvailable: true
        )
        let provider = DefaultLaunchdRuntimeStateProvider(launchctl: FakeLaunchctl(), userIDProvider: { 501 })

        let state = provider.state(label: "com.example.daemon", source: .launchDaemon, snapshot: snapshot)
        #expect(state?.isLoaded == nil)
        #expect(state?.pid == nil)
        #expect(state?.lastExitStatus == nil)
        #expect(state?.disabledOverride == false)
    }

    @Test("state returns nil for login items and startup items")
    func stateNilForUncontrollableSources() {
        let provider = DefaultLaunchdRuntimeStateProvider(launchctl: FakeLaunchctl(), userIDProvider: { 501 })
        #expect(provider.state(label: "x", source: .loginItem, snapshot: .empty) == nil)
        #expect(provider.state(label: "x", source: .startupItem, snapshot: .empty) == nil)
    }

    @Test("state returns nil when every field would be nil")
    func stateNilWhenAllFieldsNil() {
        let provider = DefaultLaunchdRuntimeStateProvider(launchctl: FakeLaunchctl(), userIDProvider: { 501 })
        let state = provider.state(label: "com.example.unknown", source: .userLaunchAgent, snapshot: .empty)
        #expect(state == nil)
    }

    // MARK: - printDetail()

    @Test("printDetail returns isLoaded false when launchctl reports the service was not found")
    func printDetailNotFound() {
        let fake = FakeLaunchctl()
        fake.script(
            prefix: ["print", "gui/501/com.example.agent"],
            exitCode: 113,
            stdout: "",
            stderr: "Could not find service \"com.example.agent\" in domain for user gui: 501"
        )
        let provider = DefaultLaunchdRuntimeStateProvider(launchctl: fake, userIDProvider: { 501 })

        let detail = provider.printDetail(label: "com.example.agent", source: .userLaunchAgent)
        #expect(detail == LaunchdRuntimeDetail(isLoaded: false, state: nil, pid: nil, lastExitStatus: nil))
    }

    @Test("printDetail returns nil for other launchctl failures")
    func printDetailOtherFailure() {
        let fake = FakeLaunchctl()
        fake.script(prefix: ["print", "gui/501/com.example.agent"], exitCode: 1, stdout: "", stderr: "Bad request.")
        let provider = DefaultLaunchdRuntimeStateProvider(launchctl: fake, userIDProvider: { 501 })

        #expect(provider.printDetail(label: "com.example.agent", source: .userLaunchAgent) == nil)
    }

    @Test("printDetail parses a successful print into a detail struct")
    func printDetailSuccess() {
        let fake = FakeLaunchctl()
        fake.script(prefix: ["print", "gui/501/com.bjango.istatmenus-setapp.agent"], stdout: Self.printFixture)
        let provider = DefaultLaunchdRuntimeStateProvider(launchctl: fake, userIDProvider: { 501 })

        let detail = provider.printDetail(label: "com.bjango.istatmenus-setapp.agent", source: .userLaunchAgent)
        #expect(detail?.isLoaded == true)
        #expect(detail?.state == "running")
        #expect(detail?.pid == 5036)
    }

    @Test("printDetail uses the system domain for launch daemons")
    func printDetailDaemonUsesSystemDomain() {
        let fake = FakeLaunchctl()
        fake.script(prefix: ["print", "system/com.example.daemon"], stdout: Self.printFixture)
        let provider = DefaultLaunchdRuntimeStateProvider(launchctl: fake, userIDProvider: { 501 })

        let detail = provider.printDetail(label: "com.example.daemon", source: .launchDaemon)
        #expect(detail?.isLoaded == true)
        #expect(fake.calls.contains(["print", "system/com.example.daemon"]))
    }

    @Test("printDetail returns nil for login items without invoking launchctl")
    func printDetailLoginItemSkipsRunner() {
        let fake = FakeLaunchctl()
        let provider = DefaultLaunchdRuntimeStateProvider(launchctl: fake, userIDProvider: { 501 })

        let detail = provider.printDetail(label: "com.example.login", source: .loginItem)
        #expect(detail == nil)
        #expect(fake.callCount == 0)
    }

    @Test("parsePrint ignores state/pid keys inside nested sub-blocks")
    func parsePrintIgnoresNestedBlocks() {
        let stdout = """
        gui/501/com.example.agent = {
        \tactive count = 4
        \tevent trigger = {
        \t\tstate = waiting
        \t\tpid = 99
        \t}
        \tstate = running
        \tpid = 5036
        }
        """
        let detail = DefaultLaunchdRuntimeStateProvider.parsePrint(stdout)
        #expect(detail.state == "running")
        #expect(detail.pid == 5036)
    }

    @Test("parsePrint takes no job-level values when they exist only in sub-blocks")
    func parsePrintNestedOnlyValuesStayNil() {
        let stdout = """
        gui/501/com.example.agent = {
        \tspawn constraints = {
        \t\tstate = throttled
        \t}
        }
        """
        let detail = DefaultLaunchdRuntimeStateProvider.parsePrint(stdout)
        #expect(detail.state == nil)
        #expect(detail.pid == nil)
        #expect(detail.isLoaded == true)
    }

    @Test("parsePrintDisabled honors escaped quotes inside labels")
    func parsePrintDisabledEscapedQuotes() {
        let stdout = """
        \tdisabled services = {
        \t\t"com.example.we\\"ird" => disabled
        \t\t"com.example.plain" => enabled
        \t}
        """
        let parsed = DefaultLaunchdRuntimeStateProvider.parsePrintDisabled(stdout)
        #expect(parsed["com.example.we\"ird"] == true)
        #expect(parsed["com.example.plain"] == false)
    }
}
