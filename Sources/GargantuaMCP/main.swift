import Foundation
import GargantuaCore

// Phase 3 stdio MCP server entry point.
//
// Framing lives in `MCPStdioTransport`; protocol dispatch lives in
// `MCPRequestDispatcher`. This entry point wires them together, routes log
// output to stderr (stdout is reserved for protocol traffic), and registers
// both Phase 2 (read-only) and Phase 3 (destructive) tool handlers.
//
// Phase 2 tools: `scan`, `analyze`, `status`, `explain`, `list_profiles`.
// Phase 3 tools: `clean`.
//
// Threading model (Task 4 `gargantua-uxdr`): the transport's blocking read
// loop runs on a background queue, not the main thread. The main thread
// pumps a run loop via `dispatchMain()`. This matters because the `clean`
// tool's production cleaner wraps `CleanupEngine.clean` — which is
// `@MainActor` because it calls `NSWorkspace.shared.recycle` — inside the
// synchronous `runBlocking` bridge. If the transport ran on main, the
// bridge's `semaphore.wait()` would park the main thread, and the detached
// Task inside would deadlock trying to hop back to MainActor for the
// recycle call. Moving the transport off main avoids that entirely: the
// background transport thread parks itself on the semaphore while the
// detached Task hops to MainActor freely.

private let mcpServerVersion = "0.1.0"

FileHandle.standardError.write(Data(
    "Gargantua MCP server — Phase 3\n".utf8
))
FileHandle.standardError.write(Data(
    "Registered tools:\n".utf8
))
for tool in MCPPhase2Tools.all + MCPPhase3Tools.all {
    FileHandle.standardError.write(Data(
        "  - \(tool.name.rawValue): \(tool.description)\n".utf8
    ))
}

private let stderrLog: @Sendable (String) -> Void = { message in
    FileHandle.standardError.write(Data("[mcp] \(message)\n".utf8))
}

let dispatcher = MCPRequestDispatcher(
    serverInfo: MCPServerInfo(name: "gargantua", version: mcpServerVersion),
    tools: MCPPhase2Tools.all + MCPPhase3Tools.all,
    log: stderrLog
)

// Shared scan session cache: `scan` populates it on every successful scan,
// `clean` reads it to resolve `item_ids` back into `ScanResult` values. A
// single cache instance per process keeps the handlers decoupled from each
// other — they communicate only through the cache's `replace(with:)` /
// `lookupAll(ids:)` surface.
let scanSessionCache = MCPScanSessionCache()

// MARK: - scan

// The Phase 2 MCP server is a standalone CLI; it doesn't have access to the
// app's persisted "active profile" yet. Default to `.light` (the safest
// built-in) when no profile is requested. "custom" is advertised by the
// schema (PRD §7.3) but has no wiring yet — reject it explicitly so clients
// can't get a silent profile downgrade; support will arrive with the
// persisted-profile bridge in a follow-up.
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
        throw MCPToolError.invalidParams(
            "'custom' profile is not yet supported via MCP; use 'developer', 'light', or 'deep'."
        )
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
    profileResolver: scanProfileResolver,
    sessionCache: scanSessionCache,
    log: stderrLog
)
dispatcher.register(tool: .scan, handler: scanHandler.toolHandler)

// MARK: - analyze + status

// One shared collector for both tools; it is a value type with no state and
// cheap to call. `collect()` is async, so bridge to sync at each handler's
// provider closure via the same `runBlocking` helper the scan runner uses.
private let systemMetricCollector = SystemMetricCollector()

private let analyzeMetricsProvider: MCPAnalyzeToolHandler.MetricsProvider = {
    try runBlocking { await systemMetricCollector.collect() }
}

let analyzeHandler = MCPAnalyzeToolHandler(
    metricsProvider: analyzeMetricsProvider,
    log: stderrLog
)
dispatcher.register(tool: .analyze, handler: analyzeHandler.toolHandler)

private let statusSnapshotProvider: MCPStatusToolHandler.SnapshotProvider = {
    let metrics = try runBlocking { await systemMetricCollector.collect() }
    return SystemStatusSnapshot(
        metrics: metrics,
        uptime: ProcessInfo.processInfo.systemUptime,
        coreCount: ProcessInfo.processInfo.activeProcessorCount
    )
}

let statusHandler = MCPStatusToolHandler(
    snapshotProvider: statusSnapshotProvider,
    log: stderrLog
)
dispatcher.register(tool: .status, handler: statusHandler.toolHandler)

// MARK: - explain

// Default explain provider: AI-free shell backed by filesystem metadata.
// The provider lives in `GargantuaCore` (see
// `MCPExplainToolHandler.defaultFilesystemProvider`) so its behavior has
// direct test coverage and the boundary for swapping to an AI-backed
// source (`AIInferenceEngine`) is a single factory call.
let explainHandler = MCPExplainToolHandler(
    explainProvider: MCPExplainToolHandler.defaultFilesystemProvider(),
    log: stderrLog
)
dispatcher.register(tool: .explain, handler: explainHandler.toolHandler)

// MARK: - list_profiles

// Default profiles provider: the three built-in profiles, with `active`
// pinned to "light" (same safest built-in the scan handler falls back to
// when no profile is requested). Persisted user profiles and the app's
// real active-profile selection land with the persisted-profile bridge
// in a follow-up.
private let builtInProfilesProvider: MCPListProfilesToolHandler.ProfilesProvider = {
    ProfilesSnapshot(profiles: CleanupProfile.builtIn, active: "light")
}

let listProfilesHandler = MCPListProfilesToolHandler(
    profilesProvider: builtInProfilesProvider,
    log: stderrLog
)
dispatcher.register(tool: .listProfiles, handler: listProfilesHandler.toolHandler)

// MARK: - clean (Phase 3)

// Shared infrastructure for Phase 3 destructive tools. The `clean` handler
// is the first consumer; future destructive tools share the rate limiter and
// audit writer so their budgets and forensic trails are cross-cutting.
private let auditWriter = AuditWriter()
private let cleanRateLimiter = MCPRateLimiter()          // 1 op / 60s default
private let cleanupEngine = CleanupEngine()
private let cleanNotificationService = MCPCleanNotificationFactory.automatic(
    gracePeriod: 5,
    log: stderrLog
)

// Production cleaner. Posts the user-facing notification (PRD §7.4), waits
// the grace period, then either delegates to `CleanupEngine.clean` or
// short-circuits with an all-failed result if the user tapped Cancel. The
// handler audits either way — cancel produces an entry with `bytesFreed: 0`
// so forensic tooling sees the attempted op even if nothing touched disk.
private let cleaner: MCPCleanToolHandler.Cleaner = { items, method in
    let decision = cleanNotificationService.request(
        items: items,
        method: method,
        clientID: dispatcher.currentClientIdentity()?.name
            ?? MCPCleanToolHandler.unknownClientSentinel
    )
    switch decision {
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
        return try runBlocking { await cleanupEngine.clean(items, method: method) }
    }
}

let cleanHandler = MCPCleanToolHandler(
    sessionCache: scanSessionCache,
    cleaner: cleaner,
    auditRecorder: { try auditWriter.write($0) },
    rateLimiter: cleanRateLimiter,
    clientIDProvider: { dispatcher.currentClientIdentity()?.name },
    log: stderrLog
)
dispatcher.register(tool: .clean, handler: cleanHandler.toolHandler)

// MARK: - Transport

let transport = MCPStdioTransport(
    source: StandardInputMessageSource(),
    sink: StandardOutputMessageSink(),
    handler: { request in dispatcher.dispatch(request) },
    log: stderrLog
)

// Run the transport off the main thread so the clean path (which hops to
// MainActor inside `CleanupEngine.clean`) does not deadlock when the
// `runBlocking` bridge parks the caller. Main thread pumps `dispatchMain()`,
// which never returns — the process stays alive until the transport
// finishes, at which point we `exit(0)` from the transport queue.
private let transportQueue = DispatchQueue(
    label: "com.gargantua.mcp.transport",
    qos: .userInitiated
)

transportQueue.async {
    transport.run()
    // EOF on stdin — the client disconnected. Tear down the process so
    // whatever launched us (claude-code, mcp inspector, etc.) sees a clean
    // exit.
    exit(0)
}

dispatchMain()

// MARK: - Async-to-sync bridge

/// Runs an async operation from a synchronous context, blocking the caller
/// until the operation completes. Uses a detached Task so the operation
/// executes on the cooperative thread pool, not the waiting thread.
///
/// Only intended for the transport's request-handling thread, which already
/// serialises requests one at a time. Do NOT call from the main thread: the
/// detached Task may hop to MainActor internally, and parking the main
/// thread on the semaphore would deadlock.
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
