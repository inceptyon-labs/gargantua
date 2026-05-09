import Foundation
import Testing
@testable import GargantuaCore

@Suite("BackgroundItemActionExecutor")
@MainActor
struct BackgroundItemActionExecutorTests {

    // MARK: - Stubs

    private final class FakeLaunchctl: LaunchctlRunning, @unchecked Sendable {
        nonisolated(unsafe) private var _calls: [[String]] = []
        nonisolated(unsafe) private var _exitCodes: [String: Int32] = [:]
        nonisolated(unsafe) private var _stderrs: [String: String] = [:]
        private let lock = NSLock()

        var calls: [[String]] { lock.withLock { _calls } }

        func setExit(_ code: Int32, forSubcommand subcommand: String, stderr: String = "") {
            lock.withLock {
                _exitCodes[subcommand] = code
                _stderrs[subcommand] = stderr
            }
        }

        func run(_ arguments: [String]) -> LaunchctlResult {
            lock.withLock { _calls.append(arguments) }
            let subcommand = arguments.first ?? ""
            let exit = lock.withLock { _exitCodes[subcommand] } ?? 0
            let stderr = lock.withLock { _stderrs[subcommand] } ?? ""
            return LaunchctlResult(arguments: arguments, exitCode: exit, stdout: "", stderr: stderr)
        }
    }

    private final class FakeHelper: PrivilegedBackgroundItemHelping, @unchecked Sendable {
        nonisolated(unsafe) private var _calls: [PrivilegedBackgroundItemRequest] = []
        nonisolated(unsafe) private var _responder: ((PrivilegedBackgroundItemRequest) -> PrivilegedBackgroundItemResponse) = { request in
            PrivilegedBackgroundItemResponse(id: request.id, succeeded: true, exitCode: 0)
        }
        private let lock = NSLock()

        var calls: [PrivilegedBackgroundItemRequest] { lock.withLock { _calls } }

        func setResponder(_ responder: @escaping (PrivilegedBackgroundItemRequest) -> PrivilegedBackgroundItemResponse) {
            lock.withLock { _responder = responder }
        }

        func perform(_ request: PrivilegedBackgroundItemRequest) async -> PrivilegedBackgroundItemResponse {
            lock.withLock { _calls.append(request) }
            let responder = lock.withLock { _responder }
            return responder(request)
        }
    }

    private final class FakeTrasher: BackgroundItemTrashing, @unchecked Sendable {
        nonisolated(unsafe) private var _trashed: [String] = []
        nonisolated(unsafe) private var _shouldThrow = false
        private let lock = NSLock()

        var trashed: [String] { lock.withLock { _trashed } }

        func setShouldThrow(_ shouldThrow: Bool) {
            lock.withLock { _shouldThrow = shouldThrow }
        }

        func trash(_ path: String) throws -> String? {
            try lock.withLock {
                if _shouldThrow { throw NSError(domain: "test", code: 1) }
                _trashed.append(path)
                return "/Users/me/.Trash/" + URL(fileURLWithPath: path).lastPathComponent
            }
        }
    }

    // MARK: - Fixtures

    private func makeExecutor(
        launchctl: FakeLaunchctl = FakeLaunchctl(),
        helper: FakeHelper = FakeHelper(),
        trasher: FakeTrasher = FakeTrasher(),
        userID: uid_t? = 501,
        auditDir: URL
    ) -> (DefaultBackgroundItemActionExecutor, AuditWriter) {
        let writer = AuditWriter(logDirectory: auditDir)
        let executor = DefaultBackgroundItemActionExecutor(
            launchctl: launchctl,
            helper: helper,
            trasher: trasher,
            audit: writer,
            userIDProvider: { userID },
            now: { Date(timeIntervalSince1970: 1_715_000_000) }
        )
        return (executor, writer)
    }

    private func makeItem(
        label: String = "com.acme.tool",
        source: BackgroundItemSource = .userLaunchAgent,
        plistPath: String? = "/Users/me/Library/LaunchAgents/com.acme.tool.plist",
        safety: SafetyLevel = .review,
        reasons: Set<BackgroundItemReason> = []
    ) -> BackgroundItem {
        BackgroundItem(
            id: "userAgent|\(label)|\(plistPath ?? "")",
            label: label,
            source: source,
            plistPath: plistPath,
            executablePath: "/usr/local/bin/\(label)",
            identity: nil,
            safety: safety,
            reasons: reasons,
            explanation: "Test item",
            isOrphaned: false
        )
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Disable

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

    // MARK: - Enable

    @Test("User-domain enable runs launchctl enable + bootstrap from plist")
    func enableRebootstraps() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let launchctl = FakeLaunchctl()
        let (executor, writer) = makeExecutor(launchctl: launchctl, auditDir: dir)

        let outcome = await executor.enable(makeItem())

        #expect(outcome.succeeded)
        #expect(launchctl.calls.count == 2)
        #expect(launchctl.calls[0].first == "enable")
        #expect(launchctl.calls[1].first == "bootstrap")

        let entries = try writer.readEntries()
        #expect(entries.first?.command == "enable")
    }

    // MARK: - Delete

    @Test("Delete refuses on items not yet disabled")
    func deleteRefusesIfNotDisabled() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let trasher = FakeTrasher()
        let (executor, writer) = makeExecutor(trasher: trasher, auditDir: dir)

        let outcome = await executor.delete(makeItem(reasons: []), confirmedAt: .summaryDialog)

        #expect(!outcome.succeeded)
        #expect(outcome.error?.contains("Disable") == true)
        #expect(trasher.trashed.isEmpty)
        let entries = try writer.readEntries()
        #expect(entries.isEmpty)
    }

    @Test("Delete on user-domain disabled item trashes plist and writes audit")
    func deleteUserDomainTrashesAndAudits() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let trasher = FakeTrasher()
        let (executor, writer) = makeExecutor(trasher: trasher, auditDir: dir)
        let item = makeItem(reasons: [.disabledFlag])

        let outcome = await executor.delete(item, confirmedAt: .summaryDialog)

        #expect(outcome.succeeded)
        #expect(trasher.trashed == [item.plistPath!])
        let entries = try writer.readEntries()
        #expect(entries.count == 1)
        #expect(entries[0].command == "delete")
        #expect(entries[0].kind == .path)
        #expect(entries[0].cleanupMethod == .trash)
        #expect(entries[0].confirmationMethod == .summaryDialog)
    }

    @Test("Delete on system launch agent routes trash through helper, not direct trasher")
    func deleteSystemAgentUsesHelperTrash() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = FakeHelper()
        let trasher = FakeTrasher()
        let (executor, _) = makeExecutor(helper: helper, trasher: trasher, auditDir: dir)
        let item = makeItem(
            source: .systemLaunchAgent,
            plistPath: "/Library/LaunchAgents/com.acme.tool.plist",
            reasons: [.disabledFlag]
        )

        let outcome = await executor.delete(item, confirmedAt: .summaryDialog)

        #expect(outcome.succeeded)
        #expect(trasher.trashed.isEmpty, "root-owned plists must not bypass the helper")
        #expect(helper.calls.map(\.operation) == [.trashLaunchPlist])
        #expect(helper.calls.first?.plistPath == "/Library/LaunchAgents/com.acme.tool.plist")
    }

    @Test("Delete on system-domain item routes through helper trash op")
    func deleteSystemDomainUsesHelper() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = FakeHelper()
        let trasher = FakeTrasher()
        let (executor, writer) = makeExecutor(helper: helper, trasher: trasher, auditDir: dir)
        let item = makeItem(
            source: .launchDaemon,
            plistPath: "/Library/LaunchDaemons/com.acme.tool.plist",
            reasons: [.disabledFlag]
        )

        let outcome = await executor.delete(item, confirmedAt: .summaryDialog)

        #expect(outcome.succeeded)
        #expect(trasher.trashed.isEmpty, "system-domain delete must not use the user trasher")
        #expect(helper.calls.map(\.operation) == [.trashLaunchPlist])
        #expect(helper.calls.first?.plistPath == item.plistPath)
        let entries = try writer.readEntries()
        #expect(entries.count == 1)
        #expect(entries[0].command == "delete")
    }

    @Test("Delete records audit failure when trasher throws")
    func deleteRecordsFailure() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let trasher = FakeTrasher()
        trasher.setShouldThrow(true)
        let (executor, writer) = makeExecutor(trasher: trasher, auditDir: dir)
        let item = makeItem(reasons: [.disabledFlag])

        let outcome = await executor.delete(item, confirmedAt: .summaryDialog)

        #expect(!outcome.succeeded)
        // Failure is still audit-worthy: we want forensic evidence that a
        // delete was attempted even when the trash op blew up.
        let entries = try writer.readEntries()
        #expect(entries.count == 1)
    }

    @Test("Delete fails if the helper rejects the request")
    func deleteHonorsHelperFailure() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = FakeHelper()
        helper.setResponder { request in
            PrivilegedBackgroundItemResponse(
                id: request.id,
                succeeded: false,
                error: "helper said no"
            )
        }
        let (executor, _) = makeExecutor(helper: helper, auditDir: dir)
        let item = makeItem(
            source: .launchDaemon,
            plistPath: "/Library/LaunchDaemons/com.acme.tool.plist",
            reasons: [.disabledFlag]
        )

        let outcome = await executor.delete(item, confirmedAt: .fullModal)

        #expect(!outcome.succeeded)
        #expect(outcome.error == "helper said no")
    }
}
