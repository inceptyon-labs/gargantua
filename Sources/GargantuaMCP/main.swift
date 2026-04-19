import Foundation
import GargantuaCore

// Phase 2 stdio MCP server entry point.
//
// Framing lives in `MCPStdioTransport`; protocol dispatch lives in
// `MCPRequestDispatcher`. This entry point wires them together, routes log
// output to stderr (stdout is reserved for protocol traffic), and registers
// the Phase 2 tool handlers.
//
// Currently registered: `scan` (gargantua-sbg6). The remaining tools
// (`analyze`, `explain`, `list_profiles`, `status`) land in follow-up Tasks;
// until then they still return JSON-RPC internal error 'Tool not implemented'.

private let mcpServerVersion = "0.1.0"

FileHandle.standardError.write(Data(
    "Gargantua MCP server — Phase 2\n".utf8
))
FileHandle.standardError.write(Data(
    "Registered tools:\n".utf8
))
for tool in MCPPhase2Tools.all {
    FileHandle.standardError.write(Data(
        "  - \(tool.name.rawValue): \(tool.description)\n".utf8
    ))
}

private let stderrLog: @Sendable (String) -> Void = { message in
    FileHandle.standardError.write(Data("[mcp] \(message)\n".utf8))
}

let dispatcher = MCPRequestDispatcher(
    serverInfo: MCPServerInfo(name: "gargantua", version: mcpServerVersion),
    tools: MCPPhase2Tools.all,
    log: stderrLog
)

// MARK: - scan

// The Phase 2 MCP server is a standalone CLI; it doesn't have access to the
// app's persisted "active profile" yet. Default to `.light` (the safest
// built-in) when no profile is requested. Profiles advertised in the schema
// `enum` that we can't honor today (`custom`) also fall back to `.light`
// rather than erroring, so a client using the schema verbatim still works.
//
// Unknown profile names get rejected with `-32602 invalidParams`.
private let scanProfileResolver: MCPScanToolHandler.ProfileResolver = { requested in
    guard let name = requested else { return .light }
    switch name {
    case "developer":
        return .developer
    case "light":
        return .light
    case "deep":
        return .deep
    case "custom":
        // Phase 2 has no persisted custom profile surface; fall back to the
        // safest default and log for operators.
        stderrLog("scan: 'custom' profile requested but not yet supported; using 'light'")
        return .light
    default:
        throw MCPToolError.invalidParams(
            "Unknown profile '\(name)'. Expected one of: developer, light, deep, custom."
        )
    }
}

// Bridges `NativeScanAdapter.scan()` (async) into the synchronous `Scanner`
// contract. The transport processes one request at a time, so blocking the
// transport thread during a scan is acceptable; the semaphore wait parks
// this thread while the detached Task runs on the cooperative pool.
//
// Errors from `loadDefaults` (rules directory missing) and `scan()` (IO
// failures) are let bubble up as plain errors so the handler wraps them in
// a tool-domain `.failure(...)` result, not a JSON-RPC error. The call
// itself was well-formed; execution failed. `ScanAdapterError` already
// conforms to `LocalizedError` with a user-facing message.
private let scanRunner: MCPScanToolHandler.Scanner = { profile in
    let adapter = try NativeScanAdapter.loadDefaults(profile: profile)
    return try runBlocking { try await adapter.scan() }
}

let scanHandler = MCPScanToolHandler(
    scanner: scanRunner,
    profileResolver: scanProfileResolver
)
dispatcher.register(tool: .scan, handler: scanHandler.toolHandler)

// MARK: - Transport

let transport = MCPStdioTransport(
    source: StandardInputMessageSource(),
    sink: StandardOutputMessageSink(),
    handler: { request in dispatcher.dispatch(request) },
    log: stderrLog
)

transport.run()

// MARK: - Async-to-sync bridge

/// Runs an async operation from a synchronous context, blocking the caller
/// until the operation completes. Uses a detached Task so the operation
/// executes on the cooperative thread pool, not the waiting thread.
///
/// Only intended for the transport's request-handling thread, which already
/// serialises requests one at a time.
private func runBlocking<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
) throws -> T {
    let holder = ResultHolder<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let value = try await operation()
            holder.set(.success(value))
        } catch {
            holder.set(.failure(error))
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try holder.get().get()
}

/// Lock-guarded storage for the result of `runBlocking`'s detached Task.
/// Needed because Swift's strict concurrency forbids capturing a mutable
/// local from a `@Sendable` closure.
private final class ResultHolder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?

    func set(_ v: Result<T, Error>) {
        lock.lock()
        value = v
        lock.unlock()
    }

    /// Precondition: caller has already waited on the signalling semaphore,
    /// so `value` is guaranteed to be set.
    func get() -> Result<T, Error> {
        lock.lock()
        defer { lock.unlock() }
        guard let value else {
            preconditionFailure("ResultHolder accessed before the detached Task signalled completion")
        }
        return value
    }
}
