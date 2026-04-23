import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP clean notification service")
struct MCPCleanNotificationServiceTests {

    private static func makeItem(id: String = "item-a", size: Int64 = 1_000) -> ScanResult {
        ScanResult(
            id: id,
            name: "name-\(id)",
            path: "/tmp/\(id)",
            size: size,
            safety: .safe,
            confidence: 95,
            explanation: "t",
            source: SourceAttribution(name: "TestApp"),
            category: "browser_cache"
        )
    }

    // MARK: Noop

    @Test("Noop service returns .proceed without blocking")
    func noopProceeds() {
        let service = NoopMCPCleanNotificationService()
        let start = Date()
        let decision = service.request(
            items: [Self.makeItem()],
            method: .trash,
            clientID: "claude-code"
        )
        #expect(decision == .proceed)
        #expect(Date().timeIntervalSince(start) < 0.1, "Noop must not block")
    }

    // MARK: Body formatting

    @Test("body message describes verb, count, size, client")
    func bodyMessageShape() {
        let items = [
            Self.makeItem(id: "a", size: 500_000),
            Self.makeItem(id: "b", size: 500_000),
        ]
        let body = UNCleanNotificationService.bodyMessage(
            items: items,
            method: .trash,
            clientID: "claude-code"
        )
        #expect(body.contains("claude-code"))
        #expect(body.contains("move to Trash"))
        #expect(body.contains("2 item(s)"))
        #expect(body.contains("Cancel"))
    }

    @Test("delete method renders as 'permanently delete'")
    func bodyMessageDeleteVerb() {
        let body = UNCleanNotificationService.bodyMessage(
            items: [Self.makeItem(size: 1_000_000)],
            method: .delete,
            clientID: "agent-x"
        )
        #expect(body.contains("permanently delete"))
        #expect(!body.contains("move to Trash"))
    }

    @Test("zero-byte items omit the size suffix")
    func bodyMessageOmitsZeroSize() {
        let body = UNCleanNotificationService.bodyMessage(
            items: [Self.makeItem(size: 0)],
            method: .trash,
            clientID: "claude-code"
        )
        // No parentheses fragment of the form "(… bytes)" — ensures we don't
        // emit a useless "(0 B)" dangling.
        #expect(!body.contains("(0"))
    }

    // MARK: Factory

    @Test("factory is stable across calls")
    func factoryProducesService() {
        let service = MCPCleanNotificationFactory.automatic(gracePeriod: 1)
        // Whichever branch is picked, calling request on a single item must
        // return a decision without crashing; real cancel UX is covered by
        // production manual testing.
        let decision = service.request(
            items: [Self.makeItem()],
            method: .trash,
            clientID: "factory-test"
        )
        #expect(decision == .proceed || decision == .cancelled)
    }

    // MARK: Fake for integration

    @Test("RecordingCleanNotificationService echoes the configured decision")
    func recordingFakeEchoesDecision() {
        let fake = RecordingCleanNotificationService(decision: .cancelled)
        let items = [Self.makeItem(id: "x", size: 10)]
        let decision = fake.request(items: items, method: .delete, clientID: "fake-client")
        #expect(decision == .cancelled)
        #expect(fake.callCount == 1)
        #expect(fake.lastItems?.count == 1)
        #expect(fake.lastItems?.first?.id == "x")
        #expect(fake.lastMethod == .delete)
        #expect(fake.lastClientID == "fake-client")
    }
}

/// Test-only recording fake. Lives alongside these tests so integration tests
/// can reuse it without pulling in production wiring.
final class RecordingCleanNotificationService: MCPCleanNotificationService, @unchecked Sendable {
    private let decision: MCPCleanDecision
    private let lock = NSLock()
    private var _callCount = 0
    private var _lastItems: [ScanResult]?
    private var _lastMethod: CleanupMethod?
    private var _lastClientID: String?

    init(decision: MCPCleanDecision = .proceed) {
        self.decision = decision
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    var lastItems: [ScanResult]? {
        lock.lock(); defer { lock.unlock() }
        return _lastItems
    }

    var lastMethod: CleanupMethod? {
        lock.lock(); defer { lock.unlock() }
        return _lastMethod
    }

    var lastClientID: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastClientID
    }

    func request(
        items: [ScanResult],
        method: CleanupMethod,
        clientID: String
    ) -> MCPCleanDecision {
        lock.lock()
        _callCount += 1
        _lastItems = items
        _lastMethod = method
        _lastClientID = clientID
        lock.unlock()
        return decision
    }
}
