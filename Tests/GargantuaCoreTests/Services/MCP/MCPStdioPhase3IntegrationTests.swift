import Testing
import Foundation
@testable import GargantuaCore

// End-to-end validation of the Phase 3 MCP server: spins up a real dispatcher
// + handlers + stdio transport over OS pipes, writes JSON-RPC frames into one
// end, reads responses from the other, and asserts the observable behaviour
// — status codes, audit trail, rate-limit enforcement, cancel short-circuit
// — that Task 4's production wiring in `main.swift` promises.
//
// Fakes stop at two boundaries: the scanner produces a synthesized
// `ScanResult` set (we don't want tests to walk the real filesystem), and
// the cleaner returns a deterministic `CleanupResult` (we don't want tests
// to move real files to Trash). Everything between — framing, dispatch,
// handshake, client identity capture, rate limiter, audit recording,
// notification service — is real production code.
//
// Harness (pipes, fakes, line reader) lives in
// `MCPStdioPhase3IntegrationHarness.swift`.

@Suite("MCP stdio Phase 3 integration — pipe-backed")
struct MCPStdioPhase3IntegrationTests {

    private static func initializeRequest(id: Int64, clientName: String) -> MCPRequest {
        MCPRequest(
            id: .int(id),
            method: "initialize",
            params: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string(clientName),
                    "version": .string("0.1"),
                ]),
            ])
        )
    }

    private static func scanRequest(id: Int64) -> MCPRequest {
        MCPRequest(
            id: .int(id),
            method: "tools/call",
            params: .object([
                "name": .string("scan"),
                "arguments": .object([:]),
            ])
        )
    }

    private static func cleanRequest(
        id: Int64,
        itemIDs: [String],
        dryRun: Bool = false
    ) -> MCPRequest {
        var args: [String: MCPJSONAny] = [
            "item_ids": .array(itemIDs.map { .string($0) }),
            "confirm": .bool(true),
        ]
        if dryRun { args["dry_run"] = .bool(true) }
        return MCPRequest(
            id: .int(id),
            method: "tools/call",
            params: .object([
                "name": .string("clean"),
                "arguments": .object(args),
            ])
        )
    }

    @Test("initialize → scan → clean: happy path writes audit with client id")
    func happyPath() throws {
        let server = Phase3StdioTestServer()
        defer { server.shutdown() }

        let initResponse = try server.roundTrip(
            Self.initializeRequest(id: 1, clientName: "claude-code-stdio")
        )
        #expect(initResponse.error == nil)

        let scanResponse = try server.roundTrip(Self.scanRequest(id: 2))
        #expect(scanResponse.error == nil)

        let cleanResponse = try server.roundTrip(
            Self.cleanRequest(id: 3, itemIDs: ["safe-a", "safe-b"])
        )
        #expect(cleanResponse.error == nil)

        let entry = try #require(server.audit.entries.first)
        #expect(entry.clientID == "claude-code-stdio")
        #expect(entry.transport == "mcp")
        #expect(entry.bytesFreed == 30_000)
        #expect(entry.files.count == 2)

        #expect(server.cleanupLog.invocations.count == 1)
        #expect(server.cleanupLog.invocations[0].method == .trash)

        #expect(server.notificationService.callCount == 1)
        #expect(server.notificationService.lastClientID == "test-client")
    }

    @Test("clean with a protected item hard-rejects with invalidParams and no audit")
    func protectedHardReject() throws {
        let server = Phase3StdioTestServer()
        defer { server.shutdown() }

        _ = try server.roundTrip(Self.initializeRequest(id: 1, clientName: "rogue-agent"))
        _ = try server.roundTrip(Self.scanRequest(id: 2))

        let cleanResponse = try server.roundTrip(
            Self.cleanRequest(id: 3, itemIDs: ["safe-a", "protected-c"])
        )
        let error = try #require(cleanResponse.error)
        #expect(error.code == MCPErrorCode.invalidParams)

        #expect(server.cleanupLog.invocations.isEmpty)
        #expect(server.notificationService.callCount == 0)
        #expect(server.audit.entries.isEmpty)
    }

    @Test("second clean inside the rate-limit window is rejected and not audited")
    func rateLimitWindow() throws {
        let server = Phase3StdioTestServer(maxOps: 1, window: 60)
        defer { server.shutdown() }

        _ = try server.roundTrip(Self.initializeRequest(id: 1, clientName: "claude-code-stdio"))
        _ = try server.roundTrip(Self.scanRequest(id: 2))

        let first = try server.roundTrip(Self.cleanRequest(id: 3, itemIDs: ["safe-a"]))
        #expect(first.error == nil)

        let second = try server.roundTrip(Self.cleanRequest(id: 4, itemIDs: ["safe-b"]))
        let error = try #require(second.error)
        #expect(error.code == MCPErrorCode.invalidParams)
        #expect(error.message.contains("rate limit") || error.message.contains("Cool-down"))

        // Exactly one audit entry — the allowed clean. The rejected one was
        // stopped before the cleaner/audit path by design.
        #expect(server.audit.entries.count == 1)
        #expect(server.cleanupLog.invocations.count == 1)
    }

    @Test("user cancel via notification short-circuits and audits 0 bytes freed")
    func userCancelShortCircuits() throws {
        let server = Phase3StdioTestServer(notificationDecision: .cancelled)
        defer { server.shutdown() }

        _ = try server.roundTrip(Self.initializeRequest(id: 1, clientName: "claude-code-stdio"))
        _ = try server.roundTrip(Self.scanRequest(id: 2))

        let cleanResponse = try server.roundTrip(Self.cleanRequest(id: 3, itemIDs: ["safe-a"]))
        #expect(cleanResponse.error == nil, "cancel is a successful response at the protocol layer")

        #expect(server.cleanupLog.invocations.isEmpty)
        #expect(server.notificationService.callCount == 1)

        let entry = try #require(server.audit.entries.first)
        #expect(entry.bytesFreed == 0)
        #expect(entry.transport == "mcp")
        #expect(entry.clientID == "claude-code-stdio")
    }

    @Test("dry-run skips notification service and rate limiter")
    func dryRunBypass() throws {
        let server = Phase3StdioTestServer(
            notificationDecision: .cancelled,
            maxOps: 1,
            window: 60
        )
        defer { server.shutdown() }

        _ = try server.roundTrip(Self.initializeRequest(id: 1, clientName: "dry-run-client"))
        _ = try server.roundTrip(Self.scanRequest(id: 2))

        // Two dry runs in quick succession must both succeed: no rate-limit
        // budget consumed, notification service untouched.
        for id in Int64(3)...Int64(4) {
            let resp = try server.roundTrip(
                Self.cleanRequest(id: id, itemIDs: ["safe-a"], dryRun: true)
            )
            #expect(resp.error == nil)
        }

        #expect(server.notificationService.callCount == 0)
        #expect(server.audit.entries.isEmpty)
        #expect(server.cleanupLog.invocations.isEmpty)
    }
}
