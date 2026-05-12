import Foundation
import Testing
@testable import GargantuaCore

@Suite("BackgroundItemActionExecutor")
@MainActor
struct BackgroundItemActionExecutorTests {

    // MARK: - Stubs

    final class FakeLaunchctl: LaunchctlRunning, @unchecked Sendable {
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

    final class FakeHelper: PrivilegedBackgroundItemHelping, @unchecked Sendable {
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

    final class FakeTrasher: BackgroundItemTrashing, @unchecked Sendable {
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

    func makeExecutor(
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

    func makeItem(
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

    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
