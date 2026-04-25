import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP scan tool handler — errors and dispatcher")
struct MCPScanToolHandlerErrorsTests {

    // MARK: Fixtures

    private static let fixedDate = Date(timeIntervalSince1970: 1_744_819_200) // 2025-04-16 16:00:00 UTC

    private static let serverInfo = MCPServerInfo(name: "gargantua", version: "0.0.1")

    private static func makeResult(
        id: String,
        size: Int64,
        safety: SafetyLevel,
        category: String = "browser_cache",
        path: String? = nil,
        name: String = "Test Item",
        source: String = "TestApp",
        confidence: Int = 95,
        explanation: String = "test explanation",
        lastAccessed: Date? = fixedDate
    ) -> ScanResult {
        ScanResult(
            id: id,
            name: name,
            path: path ?? "/tmp/\(id)",
            size: size,
            safety: safety,
            confidence: confidence,
            explanation: explanation,
            source: SourceAttribution(name: source),
            lastAccessed: lastAccessed,
            category: category
        )
    }

    private func handler(
        scanner: @escaping MCPScanToolHandler.Scanner,
        resolver: @escaping MCPScanToolHandler.ProfileResolver = { _ in .light }
    ) -> MCPScanToolHandler {
        MCPScanToolHandler(scanner: scanner, profileResolver: resolver)
    }

    /// Ergonomic arguments builder that round-trips through JSON so the
    /// handler sees exactly what a dispatcher-routed call would see.
    private func arguments(_ dict: [String: MCPJSONAny]) -> MCPToolArguments {
        MCPToolArguments(dict)
    }

    /// Dry-run true, no other fields set (the minimal valid input).
    private static let minimalArguments: MCPToolArguments = {
        MCPToolArguments(["dry_run": .bool(true)])
    }()

    // MARK: Dry-run enforcement

    @Test("dry_run: false is rejected as invalidParams")
    func dryRunFalseRejected() throws {
        let subject = handler(scanner: { _ in [] })
        do {
            _ = try subject.handle(arguments([
                "dry_run": .bool(false),
            ]))
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams {
            // Expected — MCPScanInput rejects dry_run=false at decode.
        }
    }

    @Test("omitted dry_run defaults to true and scan runs")
    func omittedDryRunAllowed() throws {
        let invoked = ScanErrorsCapturedFlag()
        let subject = handler(
            scanner: { _ in
                invoked.value = true
                return []
            }
        )
        _ = try subject.handle(arguments([:]))
        #expect(invoked.value == true)
    }

    // MARK: Scanner errors

    @Test("scanner throwing a LocalizedError surfaces the localized description in .failure")
    func scannerLocalizedErrorExposedVerbatim() throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "boom happened" }
        }
        let subject = handler(scanner: { _ in throw Boom() })
        let result = try subject.handle(Self.minimalArguments)
        #expect(result.isError == true)
        guard case .text(let message) = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(message.contains("Scan failed"))
        #expect(message.contains("boom happened"))
    }

    @Test("scanner throwing a plain Error does not leak its reflection to the client")
    func scannerGenericErrorIsSanitized() throws {
        struct SecretPathLeak: Error {
            let path = "/Users/victim/Library/Secrets"
        }
        let captured = ScanErrorsCapturedLog()
        let subject = MCPScanToolHandler(
            scanner: { _ in throw SecretPathLeak() },
            profileResolver: { _ in .light },
            log: { captured.append($0) }
        )
        let result = try subject.handle(Self.minimalArguments)
        #expect(result.isError == true)
        guard case .text(let message) = result.content.first else {
            Issue.record("expected text content")
            return
        }
        // Client never sees the reflection of a non-LocalizedError error.
        #expect(!message.contains("SecretPathLeak"))
        #expect(!message.contains("/Users/victim"))
        #expect(message.contains("internal error"))
        // But the raw detail IS logged to stderr for operators.
        #expect(captured.joined.contains("SecretPathLeak"))
    }

    @Test("scanner throwing MCPToolError.invalidParams rethrows for dispatcher")
    func scannerInvalidParamsRethrown() throws {
        let subject = handler(
            scanner: { _ in throw MCPToolError.invalidParams("bad categories") }
        )
        do {
            _ = try subject.handle(Self.minimalArguments)
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message == "bad categories")
        }
    }

    @Test("scanner throwing MCPToolError.internalError rethrows for dispatcher")
    func scannerInternalErrorRethrown() throws {
        let subject = handler(
            scanner: { _ in throw MCPToolError.internalError("rules missing") }
        )
        do {
            _ = try subject.handle(Self.minimalArguments)
            Issue.record("handler should have thrown")
        } catch MCPToolError.internalError(let message) {
            #expect(message == "rules missing")
        }
    }

    // MARK: Malformed arguments

    @Test("unknown fields on arguments are ignored")
    func unknownFieldsIgnored() throws {
        let invoked = ScanErrorsCapturedFlag()
        let subject = handler(
            scanner: { _ in
                invoked.value = true
                return []
            }
        )
        _ = try subject.handle(arguments([
            "dry_run": .bool(true),
            "garbage_field": .string("whatever"),
        ]))
        #expect(invoked.value == true)
    }

    @Test("categories of wrong type is rejected as invalidParams")
    func categoriesWrongType() throws {
        let subject = handler(scanner: { _ in [] })
        do {
            _ = try subject.handle(arguments([
                "dry_run": .bool(true),
                "categories": .string("browser_cache"),
            ]))
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams {
            // Expected — decode fails with type mismatch.
        }
    }

    // MARK: Dispatcher integration

    @Test("registering with dispatcher routes tools/call to the handler")
    func dispatcherIntegration() throws {
        let dispatcher = MCPRequestDispatcher(serverInfo: Self.serverInfo)
        let invoked = ScanErrorsCapturedFlag()
        let subject = handler(
            scanner: { _ in
                invoked.value = true
                return [Self.makeResult(id: "item-1", size: 1_024, safety: .safe)]
            }
        )
        dispatcher.register(tool: .scan, handler: subject.toolHandler)

        let request = MCPRequest(
            id: .int(7),
            method: "tools/call",
            params: .object([
                "name": .string("scan"),
                "arguments": .object(["dry_run": .bool(true)]),
            ])
        )
        let response = try #require(dispatcher.dispatch(request))
        #expect(response.error == nil)
        #expect(invoked.value == true)
        // Result envelope is the MCPToolCallResult {content, structuredContent, isError?}
        guard case .object(let envelope) = response.result else {
            Issue.record("result should be an object")
            return
        }
        guard case .array(let content) = envelope["content"] else {
            Issue.record("content must be an array")
            return
        }
        #expect(!content.isEmpty)
        #expect(envelope["structuredContent"] != nil)
        #expect(envelope["isError"] == nil) // omitted on success
    }

    @Test("dispatcher maps handler invalidParams to JSON-RPC -32602")
    func dispatcherMapsInvalidParams() throws {
        let dispatcher = MCPRequestDispatcher(serverInfo: Self.serverInfo)
        let subject = handler(scanner: { _ in [] })
        dispatcher.register(tool: .scan, handler: subject.toolHandler)

        let request = MCPRequest(
            id: .int(8),
            method: "tools/call",
            params: .object([
                "name": .string("scan"),
                "arguments": .object([
                    "dry_run": .bool(false), // should be rejected at decode
                ]),
            ])
        )
        let response = try #require(dispatcher.dispatch(request))
        let error = try #require(response.error)
        #expect(error.code == MCPErrorCode.invalidParams)
    }

    @Test("dispatcher reports tool-domain .failure as isError=true, not JSON-RPC error")
    func dispatcherPropagatesDomainFailure() throws {
        let dispatcher = MCPRequestDispatcher(serverInfo: Self.serverInfo)
        struct Boom: Error {}
        let subject = handler(scanner: { _ in throw Boom() })
        dispatcher.register(tool: .scan, handler: subject.toolHandler)

        let request = MCPRequest(
            id: .int(9),
            method: "tools/call",
            params: .object([
                "name": .string("scan"),
                "arguments": .object(["dry_run": .bool(true)]),
            ])
        )
        let response = try #require(dispatcher.dispatch(request))
        #expect(response.error == nil) // tool-domain errors don't use JSON-RPC error slot
        guard case .object(let envelope) = response.result else {
            Issue.record("result should be an object")
            return
        }
        #expect(envelope["isError"] == .bool(true))
    }
}

// MARK: - Test capture helpers

// Swift Testing closures need `@Sendable`, and simple Bools/strings/arrays
// aren't cheap to thread-safely capture inline. These tiny reference types
// give tests a shared cell to write into without dragging in `@MainActor`.

private final class ScanErrorsCapturedFlag: @unchecked Sendable {
    var value: Bool = false
}

private final class ScanErrorsCapturedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var joined: String {
        lock.lock()
        defer { lock.unlock() }
        return entries.joined(separator: "\n")
    }
}
