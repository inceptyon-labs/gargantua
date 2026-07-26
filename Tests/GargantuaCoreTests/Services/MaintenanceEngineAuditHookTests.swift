import Testing
import Foundation
@testable import GargantuaCore

/// Records whether/which scheduled audit hook fired, for dispatcher tests.
private final class SpyAuditHook: ScheduledScanAgentAuditHook, @unchecked Sendable {
    private let lock = NSLock()
    private var _ran = false
    var ran: Bool {
        lock.lock(); defer { lock.unlock() }
        return _ran
    }
    func run(summary _: ScheduledScanSummary) async {
        lock.withLock { _ran = true }
    }
}

@Suite("Maintenance engine audit wiring")
struct MaintenanceEngineAuditHookTests {

    private static func makeDefaults() -> UserDefaults {
        let suiteName = "maint-engine-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private static func makeSummary() -> ScheduledScanSummary {
        ScheduledScanSummary(date: Date(timeIntervalSince1970: 0), profileID: "light", itemCount: 3, reclaimableBytes: 42)
    }

    @Test(".maintenance supports both Claude Code and Codex")
    func maintenanceSupportsCodex() {
        #expect(AIUseCase.maintenance.canUse(.codex))
        #expect(AIUseCase.maintenance.canUse(.claudeCode))
        #expect(AIUseCase.maintenance.disabledReason(for: .codex) == nil)
        // Engines that genuinely can't run agentic work stay disabled.
        #expect(AIUseCase.maintenance.canUse(.cloud) == false)
        #expect(AIUseCase.maintenance.canUse(.template) == false)
    }

    @Test("Dispatcher routes to Codex when maintenance is assigned to Codex")
    func dispatchesToCodex() async {
        let defaults = Self.makeDefaults()
        AIEngineAssignments.set(.codex, for: .maintenance, in: defaults)

        let claude = SpyAuditHook()
        let codex = SpyAuditHook()
        let hook = MaintenanceEngineAuditHook(defaults: defaults, claudeHook: claude, codexHook: codex)
        await hook.run(summary: Self.makeSummary())

        #expect(codex.ran)
        #expect(claude.ran == false)
    }

    @Test("Dispatcher defaults to Claude Code when nothing is assigned")
    func defaultsToClaude() async {
        let defaults = Self.makeDefaults()

        let claude = SpyAuditHook()
        let codex = SpyAuditHook()
        let hook = MaintenanceEngineAuditHook(defaults: defaults, claudeHook: claude, codexHook: codex)
        await hook.run(summary: Self.makeSummary())

        #expect(claude.ran)
        #expect(codex.ran == false)
    }

    @Test("One dispatcher re-reads the assignment on every run")
    func reReadsAssignmentEachRun() async {
        let defaults = Self.makeDefaults()
        let claude = SpyAuditHook()
        let codex = SpyAuditHook()
        let hook = MaintenanceEngineAuditHook(defaults: defaults, claudeHook: claude, codexHook: codex)

        // First run: nothing assigned → Claude.
        await hook.run(summary: Self.makeSummary())
        #expect(claude.ran)
        #expect(codex.ran == false)

        // Reassign to Codex, same dispatcher instance: next run goes to Codex.
        AIEngineAssignments.set(.codex, for: .maintenance, in: defaults)
        await hook.run(summary: Self.makeSummary())
        #expect(codex.ran)
    }

    @Test("Disabled Codex config makes the scheduled hook a no-op")
    func disabledCodexHookDoesNotExec() async {
        let defaults = Self.makeDefaults()
        let store = CodexAgentConfigurationStore(defaults: defaults)
        store.save(CodexAgentConfiguration(isEnabled: false, runAfterScheduledScans: true))

        let spawned = UncheckedSendableBox(false)
        let runner = CodexOneShotRunner(processFactory: {
            spawned.value = true
            return Process()
        })
        let hook = CodexScheduledAgentAuditHook(configurationStore: store, runner: runner)
        await hook.run(summary: Self.makeSummary())

        #expect(spawned.value == false)
    }

    @Test("Opted-out Codex config (enabled but runAfterScheduledScans off) is a no-op")
    func optedOutCodexHookDoesNotExec() async {
        let defaults = Self.makeDefaults()
        let store = CodexAgentConfigurationStore(defaults: defaults)
        store.save(CodexAgentConfiguration(isEnabled: true, runAfterScheduledScans: false))

        let spawned = UncheckedSendableBox(false)
        let runner = CodexOneShotRunner(processFactory: {
            spawned.value = true
            return Process()
        })
        let hook = CodexScheduledAgentAuditHook(configurationStore: store, runner: runner)
        await hook.run(summary: Self.makeSummary())

        #expect(spawned.value == false)
    }
}
