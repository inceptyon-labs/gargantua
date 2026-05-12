import Foundation
import Testing
@testable import GargantuaCore

extension BackgroundItemActionExecutorTests {
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
