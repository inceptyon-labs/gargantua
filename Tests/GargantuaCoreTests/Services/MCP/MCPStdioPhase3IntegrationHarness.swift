import Testing
import Foundation
@testable import GargantuaCore

// Harness for the Phase 3 MCP pipe-backed stdio integration tests. The tests
// themselves live in `MCPStdioPhase3IntegrationTests.swift`; this file keeps
// the plumbing (pipes, fakes, line reader) out of the test body so the
// `@Suite` struct stays under the lint's type-body-length threshold.

/// All the wiring for a running test MCP server. Owns the pipes, transport,
/// and background queue so callers just send frames and assert.
final class Phase3StdioTestServer: @unchecked Sendable {
    let dispatcher: MCPRequestDispatcher
    let sessionCache: MCPScanSessionCache
    let rateLimiter: MCPRateLimiter
    let audit: Phase3AuditCapture
    let cleanupLog: Phase3CleanupLog
    let notificationService: RecordingCleanNotificationService

    private let clientToServer: Pipe
    private let serverToClient: Pipe
    private let transport: MCPStdioTransport
    private let runQueue = DispatchQueue(label: "mcp-test-transport")
    private var completed = DispatchSemaphore(value: 0)
    private let clockHolder: Phase3TimeHolder

    init(
        initialDate: Date = Date(),
        notificationDecision: MCPCleanDecision = .proceed,
        maxOps: Int = 1,
        window: TimeInterval = 60,
        cleanResult: Phase3CleanupLog.Plan = .allSucceed
    ) {
        self.clientToServer = Pipe()
        self.serverToClient = Pipe()
        self.sessionCache = MCPScanSessionCache()
        self.audit = Phase3AuditCapture()
        self.cleanupLog = Phase3CleanupLog(plan: cleanResult)
        self.notificationService = RecordingCleanNotificationService(
            decision: notificationDecision
        )

        let holder = Phase3TimeHolder(now: initialDate)
        self.clockHolder = holder
        self.rateLimiter = MCPRateLimiter(
            window: window,
            maxOps: maxOps,
            clock: { holder.now }
        )

        let tools = MCPPhase2Tools.all + MCPPhase3Tools.all
        let dispatcher = MCPRequestDispatcher(
            serverInfo: MCPServerInfo(name: "gargantua-test", version: "0.0.1"),
            tools: tools
        )
        self.dispatcher = dispatcher

        // scan handler — fake scanner populates the session cache.
        let scanHandler = MCPScanToolHandler(
            scanner: { _ in Phase3ScanFixture.results() },
            profileResolver: { _ in .light },
            sessionCache: sessionCache
        )
        dispatcher.register(tool: .scan, handler: scanHandler.toolHandler)

        // clean handler — full Phase 3 production wiring, but the `Cleaner`
        // calls the notification service + cleanup log instead of the real
        // CleanupEngine.
        let notifications = notificationService
        let log = cleanupLog
        let cleaner: MCPCleanToolHandler.Cleaner = { items, method in
            switch notifications.request(items: items, method: method, clientID: "test-client") {
            case .cancelled:
                return CleanupResult(
                    itemResults: items.map {
                        CleanupItemResult(
                            item: $0,
                            succeeded: false,
                            error: "User cancelled via MCP notification"
                        )
                    },
                    cleanupMethod: method
                )
            case .proceed:
                return log.perform(items: items, method: method)
            }
        }

        let cleanHandler = MCPCleanToolHandler(
            sessionCache: sessionCache,
            cleaner: cleaner,
            auditRecorder: { [audit] entry in try audit.record(entry) },
            rateLimiter: rateLimiter,
            clientIDProvider: { dispatcher.currentClientIdentity()?.name }
        )
        dispatcher.register(tool: .clean, handler: cleanHandler.toolHandler)

        let source = Phase3PipeMessageSource(handle: clientToServer.fileHandleForReading)
        let sink = Phase3PipeMessageSink(handle: serverToClient.fileHandleForWriting)
        self.transport = MCPStdioTransport(
            source: source,
            sink: sink,
            handler: { dispatcher.dispatch($0) }
        )

        runQueue.async { [transport, completed, serverToClient] in
            transport.run()
            try? serverToClient.fileHandleForWriting.close()
            completed.signal()
        }
    }

    /// Advance the rate limiter's virtual clock. Used by rate-limit tests to
    /// exit the window without real sleeping.
    func advanceClock(by seconds: TimeInterval) {
        clockHolder.advance(by: seconds)
    }

    /// Send a request frame and block until the response arrives.
    func roundTrip(_ request: MCPRequest, timeout: TimeInterval = 5) throws -> MCPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)
        clientToServer.fileHandleForWriting.write(data)
        clientToServer.fileHandleForWriting.write(Data([0x0A]))

        guard let line = Phase3LineReader.readLine(
            from: serverToClient.fileHandleForReading,
            timeout: timeout
        ) else {
            throw Phase3StdioTestError.responseTimeout
        }
        return try JSONDecoder().decode(MCPResponse.self, from: Data(line.utf8))
    }

    /// Close the client's write end, letting the transport see EOF and exit
    /// cleanly. Tests call this in their cleanup.
    func shutdown() {
        try? clientToServer.fileHandleForWriting.close()
        _ = completed.wait(timeout: .now() + 2)
        try? serverToClient.fileHandleForReading.close()
        try? clientToServer.fileHandleForReading.close()
    }
}

// MARK: - Virtual clock

/// Holds the virtual clock for `MCPRateLimiter` injection.
final class Phase3TimeHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(now: Date) { self._now = now }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return _now
    }
    func advance(by seconds: TimeInterval) {
        lock.lock()
        _now = _now.addingTimeInterval(seconds)
        lock.unlock()
    }
}

// MARK: - Deterministic scan fixture

/// Items "safe-a" / "safe-b" are safe; "protected-c" is protected.
enum Phase3ScanFixture {
    static func results() -> [ScanResult] {
        [
            ScanResult(
                id: "safe-a",
                name: "cache-a",
                path: "/tmp/cache/a",
                size: 10_000,
                safety: .safe,
                confidence: 95,
                explanation: "Browser cache",
                source: SourceAttribution(name: "Safari"),
                category: "browser_cache"
            ),
            ScanResult(
                id: "safe-b",
                name: "cache-b",
                path: "/tmp/cache/b",
                size: 20_000,
                safety: .safe,
                confidence: 95,
                explanation: "Browser cache",
                source: SourceAttribution(name: "Safari"),
                category: "browser_cache"
            ),
            ScanResult(
                id: "protected-c",
                name: "docs",
                path: "/Users/test/Documents",
                size: 1_000_000,
                safety: .protected_,
                confidence: 100,
                explanation: "User documents",
                source: SourceAttribution(name: "System"),
                category: "user_docs"
            ),
        ]
    }
}

// MARK: - Cleanup log fake

/// Records requested cleans and returns a pre-configured result.
final class Phase3CleanupLog: @unchecked Sendable {
    enum Plan: Sendable {
        case allSucceed
        case allFail(reason: String)
    }

    private let lock = NSLock()
    private var _invocations: [(items: [ScanResult], method: CleanupMethod)] = []
    private let plan: Plan

    init(plan: Plan) { self.plan = plan }

    var invocations: [(items: [ScanResult], method: CleanupMethod)] {
        lock.lock(); defer { lock.unlock() }
        return _invocations
    }

    func perform(items: [ScanResult], method: CleanupMethod) -> CleanupResult {
        lock.lock(); _invocations.append((items, method)); lock.unlock()

        let itemResults: [CleanupItemResult]
        switch plan {
        case .allSucceed:
            itemResults = items.map { CleanupItemResult(item: $0, succeeded: true) }
        case .allFail(let reason):
            itemResults = items.map {
                CleanupItemResult(item: $0, succeeded: false, error: reason)
            }
        }
        return CleanupResult(itemResults: itemResults, cleanupMethod: method)
    }
}

// MARK: - Audit capture

final class Phase3AuditCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AuditEntry] = []

    func record(_ entry: AuditEntry) throws {
        lock.lock(); storage.append(entry); lock.unlock()
    }

    var entries: [AuditEntry] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

// MARK: - Pipe-backed source/sink

final class Phase3PipeMessageSource: MCPMessageSource, @unchecked Sendable {
    private let handle: FileHandle
    private var buffer = Data()
    private let lock = NSLock()

    init(handle: FileHandle) { self.handle = handle }

    func readLine() -> String? {
        while true {
            lock.lock()
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<nl]
                let rest = buffer[(nl + 1)...]
                buffer = Data(rest)
                lock.unlock()
                return String(data: line, encoding: .utf8)
            }
            lock.unlock()

            let chunk = handle.availableData
            if chunk.isEmpty {
                lock.lock()
                let remaining = buffer
                buffer.removeAll()
                lock.unlock()
                if remaining.isEmpty { return nil }
                return String(data: remaining, encoding: .utf8)
            }
            lock.lock()
            buffer.append(chunk)
            lock.unlock()
        }
    }
}

final class Phase3PipeMessageSink: MCPMessageSink, @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(handle: FileHandle) { self.handle = handle }

    func writeLine(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        handle.write(Data((line + "\n").utf8))
    }
}

// MARK: - Line reader with timeout

enum Phase3LineReader {
    private static let buffersLock = NSLock()
    nonisolated(unsafe) private static var buffers: [ObjectIdentifier: Data] = [:]

    static func readLine(from handle: FileHandle, timeout: TimeInterval) -> String? {
        let id = ObjectIdentifier(handle)
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            buffersLock.lock()
            var buffer = buffers[id] ?? Data()
            buffersLock.unlock()

            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<nl]
                let rest = buffer[(nl + 1)...]
                buffersLock.lock()
                buffers[id] = Data(rest)
                buffersLock.unlock()
                return String(data: line, encoding: .utf8)
            }

            if Date() >= deadline { return nil }

            let remaining = deadline.timeIntervalSinceNow
            let chunk = readAvailable(from: handle, deadline: min(remaining, 0.5))
            if chunk.isEmpty { continue }
            buffer.append(chunk)
            buffersLock.lock()
            buffers[id] = buffer
            buffersLock.unlock()
        }
    }

    private static func readAvailable(from handle: FileHandle, deadline: TimeInterval) -> Data {
        let box = DataBox()
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let data = handle.availableData
            box.value = data
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + max(0.05, deadline))
        return box.value
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Data = Data()
        var value: Data {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
    }
}

enum Phase3StdioTestError: Error { case responseTimeout }
