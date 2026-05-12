import Foundation
import Testing
@testable import GargantuaCore

extension BackgroundItemActionExecutorTests {
    @Test("User-domain disable shells out bootout + disable with gui/<uid>/<label> targets")
    func userDomainDisableShellsOut() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let launchctl = FakeLaunchctl()
        let (executor, writer) = makeExecutor(launchctl: launchctl, auditDir: dir)

        let outcome = await executor.disable(makeItem())

        #expect(outcome.succeeded)
        #expect(launchctl.calls.count == 2)
        #expect(launchctl.calls[0] == ["bootout", "gui/501/com.acme.tool"])
        #expect(launchctl.calls[1] == ["disable", "gui/501/com.acme.tool"])

        let entries = try writer.readEntries()
        #expect(entries.count == 1)
        #expect(entries[0].command == "disable")
        #expect(entries[0].kind == .command)
        #expect(entries[0].tool == "launchctl")
        #expect(entries[0].cleanupMethod == .toolNative)
        #expect(entries[0].commandArguments == ["disable", "gui/501/com.acme.tool"])
    }

    @Test("Disable failure on bootout records bootout's args/exit, not the disable that never ran")
    func disableFailureRecordsFailingSubcommand() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let launchctl = FakeLaunchctl()
        // Real bootout failure (not the tolerated 36).
        launchctl.setExit(5, forSubcommand: "bootout", stderr: "no permission")
        let (executor, writer) = makeExecutor(launchctl: launchctl, auditDir: dir)

        let outcome = await executor.disable(makeItem())

        #expect(!outcome.succeeded)
        let entries = try writer.readEntries()
        #expect(entries.count == 1)
        // The audit must reflect bootout (the failing step), not disable.
        #expect(entries[0].commandArguments?.first == "bootout")
        #expect(entries[0].commandExitCode == 5)
    }

    @Test("Disable tolerates bootout exit 36 (job not loaded)")
    func disableToleratesNotLoaded() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let launchctl = FakeLaunchctl()
        launchctl.setExit(36, forSubcommand: "bootout")
        let (executor, _) = makeExecutor(launchctl: launchctl, auditDir: dir)

        let outcome = await executor.disable(makeItem())
        #expect(outcome.succeeded)
    }

    @Test("System-domain disable routes through privileged helper, not launchctl")
    func systemDomainDisableUsesHelper() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let launchctl = FakeLaunchctl()
        let helper = FakeHelper()
        let (executor, _) = makeExecutor(launchctl: launchctl, helper: helper, auditDir: dir)

        let item = makeItem(
            source: .launchDaemon,
            plistPath: "/Library/LaunchDaemons/com.acme.tool.plist"
        )
        let outcome = await executor.disable(item)

        #expect(outcome.succeeded)
        #expect(launchctl.calls.isEmpty, "system-domain ops must not shell out directly")
        #expect(helper.calls.map(\.operation) == [.bootoutDaemon, .disableDaemon])
        #expect(helper.calls.allSatisfy { $0.label == "com.acme.tool" })
    }

    @Test("Login items refuse mutating actions")
    func loginItemsRefused() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (executor, writer) = makeExecutor(auditDir: dir)
        let item = makeItem(source: .loginItem, plistPath: nil)

        let outcome = await executor.disable(item)

        #expect(!outcome.succeeded)
        #expect(outcome.error?.contains("System Settings") == true)
        let entries = try writer.readEntries()
        #expect(entries.isEmpty, "refused actions must not write audit entries")
    }

    @Test("Protected items refuse all mutating actions")
    func protectedItemsRefused() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (executor, _) = makeExecutor(auditDir: dir)
        let item = makeItem(safety: .protected_)

        let disable = await executor.disable(item)
        let enable = await executor.enable(item)
        let delete = await executor.delete(item, confirmedAt: .fullModal)

        #expect(!disable.succeeded)
        #expect(!enable.succeeded)
        #expect(!delete.succeeded)
    }
}
