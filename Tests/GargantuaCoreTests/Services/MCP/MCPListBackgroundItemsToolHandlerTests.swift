import Testing
import Foundation
@testable import GargantuaCore

// MARK: - Shared Fixtures

enum MCPListBackgroundItemsTestFixtures {
    static let userAgentRuntime = LaunchdRuntimeState(
        isLoaded: true,
        pid: 42,
        lastExitStatus: 0,
        disabledOverride: false
    )

    static let userAgentItem = BackgroundItem(
        id: "user-agent-1",
        label: "com.example.agent",
        source: .userLaunchAgent,
        plistPath: "/Users/dev/Library/LaunchAgents/com.example.agent.plist",
        executablePath: "/tmp/example-agent",
        identity: nil,
        safety: .review,
        reasons: [.suspiciousExecutablePath, .unsigned],
        explanation: "Executable lives in a world-writable temp dir.",
        isOrphaned: false,
        runtime: userAgentRuntime
    )

    static let loginItem = BackgroundItem(
        id: "login-item-1",
        label: "com.example.LoginHelper",
        source: .loginItem,
        plistPath: nil,
        executablePath: nil,
        identity: nil,
        safety: .safe,
        reasons: [],
        explanation: "Modern login item; no additional evidence.",
        isOrphaned: false,
        runtime: nil
    )

    static let protectedDaemon = BackgroundItem(
        id: "daemon-1",
        label: "com.apple.protecteddaemon",
        source: .launchDaemon,
        plistPath: "/Library/LaunchDaemons/com.apple.protecteddaemon.plist",
        executablePath: "/usr/libexec/protecteddaemon",
        identity: nil,
        safety: .protected_,
        reasons: [.system],
        explanation: "Apple-signed system daemon.",
        isOrphaned: false,
        runtime: nil
    )

    static let sampleScan = BackgroundItemScan(
        items: [userAgentItem, loginItem, protectedDaemon],
        loginItemsNeedPrivileges: true,
        unparseableCount: 3,
        scannedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    static let emptyArguments = MCPToolArguments([:])

    static func decodeOutput(_ result: MCPToolCallResult) throws -> MCPListBackgroundItemsOutput {
        let payload = try #require(result.structuredContent, "structured content missing")
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(MCPListBackgroundItemsOutput.self, from: data)
    }

    static func makeHandler(
        provider: @escaping @Sendable () throws -> BackgroundItemScan
    ) -> MCPListBackgroundItemsToolHandler {
        MCPListBackgroundItemsToolHandler(scanProvider: provider)
    }
}

// MARK: - Full List & Summary Tests

@Suite("MCP list_background_items tool handler")
struct MCPListBackgroundItemsToolHandlerTests {
    private let fixtures = MCPListBackgroundItemsTestFixtures.self

    // MARK: Full list

    @Test("maps all scanned items into the output payload")
    func mapsAllItems() throws {
        let subject = fixtures.makeHandler(provider: { MCPListBackgroundItemsTestFixtures.sampleScan })
        let output = try fixtures.decodeOutput(try subject.handle(fixtures.emptyArguments))
        #expect(output.items.count == 3)
        #expect(output.loginItemsNeedPrivileges == true)
        #expect(output.unparseableCount == 3)
    }

    @Test("safety is the SafetyLevel raw value")
    func safetyRawValues() throws {
        let subject = fixtures.makeHandler(provider: { MCPListBackgroundItemsTestFixtures.sampleScan })
        let output = try fixtures.decodeOutput(try subject.handle(fixtures.emptyArguments))
        let userAgent = try #require(output.items.first { $0.label == "com.example.agent" })
        let login = try #require(output.items.first { $0.label == "com.example.LoginHelper" })
        let daemon = try #require(output.items.first { $0.label == "com.apple.protecteddaemon" })
        #expect(userAgent.safety == "review")
        #expect(login.safety == "safe")
        #expect(daemon.safety == "protected")
    }

    @Test("reasons are sorted, not Set iteration order")
    func reasonsSorted() throws {
        let subject = fixtures.makeHandler(provider: { MCPListBackgroundItemsTestFixtures.sampleScan })
        let output = try fixtures.decodeOutput(try subject.handle(fixtures.emptyArguments))
        let userAgent = try #require(output.items.first { $0.label == "com.example.agent" })
        #expect(userAgent.reasons == ["suspicious_executable_path", "unsigned"])
    }

    @Test("runtime maps field-for-field, including pid")
    func runtimeMapped() throws {
        let subject = fixtures.makeHandler(provider: { MCPListBackgroundItemsTestFixtures.sampleScan })
        let output = try fixtures.decodeOutput(try subject.handle(fixtures.emptyArguments))
        let userAgent = try #require(output.items.first { $0.label == "com.example.agent" })
        let runtime = try #require(userAgent.runtime)
        #expect(runtime.isLoaded == true)
        #expect(runtime.pid == 42)
        #expect(runtime.lastExitStatus == 0)
        #expect(runtime.disabledOverride == false)
    }

    @Test("runtime is nil for items with no runtime facts")
    func runtimeNilForLoginItem() throws {
        let subject = fixtures.makeHandler(provider: { MCPListBackgroundItemsTestFixtures.sampleScan })
        let output = try fixtures.decodeOutput(try subject.handle(fixtures.emptyArguments))
        let login = try #require(output.items.first { $0.label == "com.example.LoginHelper" })
        #expect(login.runtime == nil)
    }

    @Test("source maps to snake_case wire values")
    func sourceSnakeCase() throws {
        let subject = fixtures.makeHandler(provider: { MCPListBackgroundItemsTestFixtures.sampleScan })
        let output = try fixtures.decodeOutput(try subject.handle(fixtures.emptyArguments))
        let userAgent = try #require(output.items.first { $0.label == "com.example.agent" })
        let login = try #require(output.items.first { $0.label == "com.example.LoginHelper" })
        let daemon = try #require(output.items.first { $0.label == "com.apple.protecteddaemon" })
        #expect(userAgent.source == "user_launch_agent")
        #expect(login.source == "login_item")
        #expect(daemon.source == "launch_daemon")
    }

    // MARK: Summary

    @Test("unfiltered summary counts by safety level")
    func unfilteredSummary() throws {
        let subject = fixtures.makeHandler(provider: { MCPListBackgroundItemsTestFixtures.sampleScan })
        let result = try subject.handle(fixtures.emptyArguments)
        guard case .text(let summary) = result.content.first else {
            Issue.record("content[0] should be text")
            return
        }
        #expect(summary.contains("3 background items"))
        #expect(summary.contains("1 safe"))
        #expect(summary.contains("1 review"))
        #expect(summary.contains("1 protected"))
    }

    // MARK: Determinism

    @Test("two calls produce identical reasons arrays")
    func deterministicReasonsAcrossCalls() throws {
        let subject = fixtures.makeHandler(provider: { MCPListBackgroundItemsTestFixtures.sampleScan })
        let first = try fixtures.decodeOutput(try subject.handle(fixtures.emptyArguments))
        let second = try fixtures.decodeOutput(try subject.handle(fixtures.emptyArguments))
        let firstReasons = try #require(first.items.first { $0.label == "com.example.agent" }).reasons
        let secondReasons = try #require(second.items.first { $0.label == "com.example.agent" }).reasons
        #expect(firstReasons == secondReasons)
    }

    @Test("MCPPhase2Tools.all advertises list_background_items")
    func phase2AdvertisesTool() {
        #expect(MCPPhase2Tools.all.contains { $0.name == .listBackgroundItems })
    }

    @Test("MCPPhase3Tools.all does not advertise list_background_items")
    func phase3DoesNotAdvertiseTool() {
        #expect(!MCPPhase3Tools.all.contains { $0.name == .listBackgroundItems })
    }
}

// MARK: - Label Filter Tests

@Suite("MCP list_background_items — label filter")
struct MCPListBackgroundItemsLabelFilterTests {
    private let fixtures = MCPListBackgroundItemsTestFixtures.self

    @Test("label filter hit returns exactly one matching item")
    func labelFilterHit() throws {
        let subject = fixtures.makeHandler(provider: { MCPListBackgroundItemsTestFixtures.sampleScan })
        let arguments = MCPToolArguments(["label": .string("com.example.agent")])
        let result = try subject.handle(arguments)
        #expect(result.isError == false)
        let output = try fixtures.decodeOutput(result)
        #expect(output.items.count == 1)
        #expect(output.items[0].label == "com.example.agent")
    }

    @Test("label filter miss is a successful empty result, not a failure")
    func labelFilterMiss() throws {
        let subject = fixtures.makeHandler(provider: { MCPListBackgroundItemsTestFixtures.sampleScan })
        let arguments = MCPToolArguments(["label": .string("com.nonexistent.item")])
        let result = try subject.handle(arguments)
        #expect(result.isError == false)
        let output = try fixtures.decodeOutput(result)
        #expect(output.items.isEmpty)
        guard case .text(let summary) = result.content.first else {
            Issue.record("content[0] should be text")
            return
        }
        #expect(summary.contains("No item matching"))
        #expect(summary.contains("com.nonexistent.item"))
    }

    @Test("label filter reaches items beyond the 100-item wire cap")
    func labelFilterReachesPastCap() throws {
        let overflow = (0 ..< 120).map { index in
            BackgroundItem(
                id: "agent-\(index)",
                label: "com.example.agent\(index)",
                source: .userLaunchAgent,
                plistPath: "/Users/dev/Library/LaunchAgents/com.example.agent\(index).plist",
                executablePath: "/usr/local/bin/agent\(index)",
                identity: nil,
                safety: .review,
                reasons: [],
                explanation: "Agent \(index).",
                isOrphaned: false,
                runtime: nil
            )
        }
        let scan = BackgroundItemScan(
            items: overflow,
            loginItemsNeedPrivileges: false,
            unparseableCount: 0,
            scannedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let arguments = MCPToolArguments(["label": .string("com.example.agent115")])
        let output = try fixtures.decodeOutput(try fixtures.makeHandler(provider: { scan }).handle(arguments))
        #expect(output.items.count == 1)
        #expect(output.items.first?.label == "com.example.agent115")
    }

    @Test("duplicate labels across domains return every match")
    func duplicateLabelAcrossDomains() throws {
        let userCopy = BackgroundItem(
            id: "dup-user",
            label: "com.example.dup",
            source: .userLaunchAgent,
            plistPath: "/Users/dev/Library/LaunchAgents/com.example.dup.plist",
            executablePath: "/usr/local/bin/dup",
            identity: nil,
            safety: .review,
            reasons: [],
            explanation: "User copy.",
            isOrphaned: false,
            runtime: nil
        )
        let systemCopy = BackgroundItem(
            id: "dup-system",
            label: "com.example.dup",
            source: .launchDaemon,
            plistPath: "/Library/LaunchDaemons/com.example.dup.plist",
            executablePath: "/usr/local/bin/dup",
            identity: nil,
            safety: .review,
            reasons: [],
            explanation: "System copy.",
            isOrphaned: false,
            runtime: nil
        )
        let scan = BackgroundItemScan(
            items: [userCopy, systemCopy],
            loginItemsNeedPrivileges: false,
            unparseableCount: 0,
            scannedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let arguments = MCPToolArguments(["label": .string("com.example.dup")])
        let output = try fixtures.decodeOutput(try fixtures.makeHandler(provider: { scan }).handle(arguments))
        #expect(output.items.count == 2)
        #expect(Set(output.items.map(\.source)) == ["user_launch_agent", "launch_daemon"])
    }

    @Test("single-item result summarizes with the item's label, singular")
    func singleItemSummaryNamesTheItem() throws {
        let subject = fixtures.makeHandler(provider: { MCPListBackgroundItemsTestFixtures.sampleScan })
        let arguments = MCPToolArguments(["label": .string("com.example.agent")])
        let result = try subject.handle(arguments)
        guard case .text(let summary) = result.content.first else {
            Issue.record("expected text summary")
            return
        }
        #expect(summary.contains("1 background item:"))
        #expect(summary.contains("com.example.agent (review)"))
    }

    @Test("non-string label fails decoding instead of being silently ignored")
    func nonStringLabelThrows() {
        let subject = fixtures.makeHandler(provider: { MCPListBackgroundItemsTestFixtures.sampleScan })
        let arguments = MCPToolArguments(["label": .int(5)])
        #expect(throws: (any Error).self) {
            _ = try subject.handle(arguments)
        }
    }
}

// MARK: - Provider Error Tests

@Suite("MCP list_background_items — provider errors")
struct MCPListBackgroundItemsProviderErrorTests {
    private let fixtures = MCPListBackgroundItemsTestFixtures.self

    @Test("provider throwing a plain error surfaces as .failure")
    func providerGenericErrorFails() throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "scan failed" }
        }
        let subject = fixtures.makeHandler(provider: { throw Boom() })
        let result = try subject.handle(fixtures.emptyArguments)
        #expect(result.isError == true)
        guard case .text(let message) = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(message.contains("List background items failed"))
        #expect(message.contains("scan failed"))
    }

    @Test("provider throwing MCPToolError.internalError rethrows for dispatcher")
    func providerInternalErrorRethrown() throws {
        let subject = fixtures.makeHandler(provider: {
            throw MCPToolError.internalError("scanner misconfigured")
        })
        #expect(throws: MCPToolError.internalError("scanner misconfigured")) {
            try subject.handle(fixtures.emptyArguments)
        }
    }
}

// MARK: - Wire Output & Registry Tests

@Suite("MCP list_background_items — wire output")
struct MCPListBackgroundItemsWireOutputTests {
    private let fixtures = MCPListBackgroundItemsTestFixtures.self

    @Test("wire output caps items and reports the real total")
    func wireOutputCapsItems() throws {
        let overflow = (0 ..< 120).map { index in
            BackgroundItem(
                id: "agent-\(index)",
                label: "com.example.agent\(index)",
                source: .userLaunchAgent,
                plistPath: "/Users/dev/Library/LaunchAgents/com.example.agent\(index).plist",
                executablePath: "/usr/local/bin/agent\(index)",
                identity: nil,
                safety: .review,
                reasons: [],
                explanation: "Agent \(index).",
                isOrphaned: false,
                runtime: nil
            )
        }
        let scan = BackgroundItemScan(
            items: overflow,
            loginItemsNeedPrivileges: false,
            unparseableCount: 0,
            scannedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let result = try fixtures.makeHandler(provider: { scan }).handle(fixtures.emptyArguments)
        let output = try fixtures.decodeOutput(result)
        #expect(output.items.count == MCPListBackgroundItemsToolHandler.maxItemsInWireOutput)
        #expect(output.totalItems == 120)
        guard case .text(let summary) = result.content.first else {
            Issue.record("expected text summary")
            return
        }
        #expect(summary.contains("120 background items"))
        #expect(summary.contains("Showing first 100"))
    }

    @Test("long explanations are trimmed with an ellipsis on the wire")
    func explanationsTrimmed() throws {
        let longExplanation = String(repeating: "x", count: 400)
        let item = BackgroundItem(
            id: "agent-long",
            label: "com.example.long",
            source: .userLaunchAgent,
            plistPath: "/Users/dev/Library/LaunchAgents/com.example.long.plist",
            executablePath: "/usr/local/bin/long",
            identity: nil,
            safety: .review,
            reasons: [],
            explanation: longExplanation,
            isOrphaned: false,
            runtime: nil
        )
        let scan = BackgroundItemScan(
            items: [item],
            loginItemsNeedPrivileges: false,
            unparseableCount: 0,
            scannedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let result = try fixtures.makeHandler(provider: { scan }).handle(fixtures.emptyArguments)
        let output = try fixtures.decodeOutput(result)
        let wire = try #require(output.items.first?.explanation)
        #expect(wire.count == MCPListBackgroundItemsToolHandler.maxExplanationCharsInWireOutput + 1)
        #expect(wire.hasSuffix("\u{2026}"))
    }
}
