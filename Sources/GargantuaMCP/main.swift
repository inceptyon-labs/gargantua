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

private let runtimeOptions = parseRuntimeOptions()
private let storedSSEConfiguration = MCPSSEConfigurationStore().load()
private let effectiveTransportMode = runtimeOptions.transportMode
    ?? (storedSSEConfiguration.isEnabled ? .both : .stdio)
private let tokenManager = MCPBearerTokenManager()

let serverStatusStore = MCPServerStatusStore(persistence: MCPServerStatusPersistence())
serverStatusStore.markRunning(transportMode: effectiveTransportMode.statusMode)

let dispatcher = MCPRequestDispatcher(
    serverInfo: MCPServerInfo(name: "gargantua", version: mcpServerVersion),
    tools: MCPPhase2Tools.all + MCPPhase3Tools.all,
    log: stderrLog,
    statusReporter: serverStatusStore
)

// Shared scan session cache: `scan` populates it on every successful scan,
// `clean` reads it to resolve `item_ids` back into `ScanResult` values. A
// single cache instance per process keeps the handlers decoupled from each
// other — they communicate only through the cache's `replace(with:)` /
// `lookupAll(ids:)` surface.
let scanSessionCache = MCPScanSessionCache()

private func loadProfileCatalog() throws -> MCPProfileCatalog {
    do {
        return try runBlocking {
            try await MainActor.run {
                let persistence = try PersistenceController()
                return try persistence.fetchMCPProfileCatalog()
            }
        }
    } catch let error as MCPToolError {
        throw error
    } catch {
        stderrLog("profile catalog load failed: \(error)")
        throw MCPToolError.internalError("Profile store unavailable.")
    }
}

// MARK: - scan

// Resolve profile identifiers through the same SwiftData-backed catalog the
// GUI uses. Omitting `profile` follows the persisted active profile; explicit
// unknown IDs are rejected with `-32602 invalidParams`.
private let scanProfileResolver: MCPScanToolHandler.ProfileResolver = { requested in
    try loadProfileCatalog().resolve(requested)
}

private func loadPathExclusionPatterns() -> Set<String> {
    (try? runBlocking {
        try await MainActor.run {
            let persistence = try PersistenceController()
            return Set(try persistence.fetchExclusionEntries().map(\.pattern))
        }
    }) ?? []
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
//
// Command-action and stale-version adapters surface alongside path rules via
// the default profile pipeline. Optional adapter failures never break the path
// scan; an empty optional result list is the worst case.
private let scanRunner: MCPScanToolHandler.Scanner = { profile in
    let adapter = try ProfileScanAdapterFactory.make(
        profile: profile,
        staleVersionPinnedPaths: loadPathExclusionPatterns()
    )
    return try runBlocking {
        try await adapter.scan(progress: nil)
    }
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

// Default explain provider: AI-free shell backed by filesystem metadata,
// enriched with pkgutil receipt provenance when available so MCP clients
// can render audit-grade explanations like "Owned by package
// com.docker.docker (v4.30.0) installed 2025-12-04". The provider lives
// in `GargantuaCore` (see `MCPExplainToolHandler.defaultFilesystemProvider`)
// so its behavior has direct test coverage and the boundary for swapping
// to an AI-backed source (`AIInferenceEngine`) is a single factory call.
//
// One expander instance is shared across all explain calls so its
// `pkgutil --pkgs` cache (populated by the receipt-based scanner) stays
// warm across requests. Per-path lookups call `--file-info` directly and
// are not cached.
private let receiptExpander = PackageReceiptExpander()
private let explainReceiptLookup: MCPExplainToolHandler.ReceiptLookup = { path in
    receiptExpander.lookupReceipts(forPath: path)
}
let explainHandler = MCPExplainToolHandler(
    explainProvider: MCPExplainToolHandler.defaultFilesystemProvider(
        receiptLookup: explainReceiptLookup
    ),
    log: stderrLog
)
dispatcher.register(tool: .explain, handler: explainHandler.toolHandler)

// MARK: - list_profiles

// Default profiles provider: all persisted built-in and custom profiles,
// plus the persisted active profile identifier.
private let persistedProfilesProvider: MCPListProfilesToolHandler.ProfilesProvider = {
    try loadProfileCatalog().snapshot
}

let listProfilesHandler = MCPListProfilesToolHandler(
    profilesProvider: persistedProfilesProvider,
    log: stderrLog
)
dispatcher.register(tool: .listProfiles, handler: listProfilesHandler.toolHandler)

// MARK: - clean (Phase 3)

// Shared infrastructure for Phase 3 destructive tools. The `clean` handler
// is the first consumer; future destructive tools share the rate limiter and
// audit writer so their budgets and forensic trails are cross-cutting.
private let auditWriter = AuditWriter()
private let cleanRateLimiter = MCPRateLimiter() // 1 op / 60s default
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

var sseTransport: MCPSSETransport?

if effectiveTransportMode.includesSSE {
    var sseConfiguration = storedSSEConfiguration
    if let port = runtimeOptions.ssePort {
        sseConfiguration.port = MCPSSEServerConfiguration.normalizedPort(port)
    }
    if let bindScope = runtimeOptions.bindScope {
        sseConfiguration.bindScope = bindScope
    }
    sseConfiguration.isEnabled = true

    let configuredToken = runtimeOptions.bearerToken
    let tokenProvider: MCPSSETransport.TokenProvider = {
        if let configuredToken { return configuredToken }
        return try tokenManager.readToken()
    }

    let transport = MCPSSETransport(
        configuration: sseConfiguration,
        tokenProvider: tokenProvider,
        handler: { request in dispatcher.dispatch(request) },
        log: stderrLog,
        queue: DispatchQueue(label: "com.gargantua.mcp.sse", qos: .userInitiated)
    )

    do {
        try transport.start()
        sseTransport = transport
    } catch {
        let message = clientFacingMessage(for: error)
        serverStatusStore.recordError(message)
        stderrLog("SSE transport failed to start: \(message)")
        if effectiveTransportMode == .sse {
            exit(1)
        }
    }
}

let stdioTransport = MCPStdioTransport(
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

if effectiveTransportMode.includesStdio {
    transportQueue.async {
        stdioTransport.run()
        if effectiveTransportMode.includesSSE, sseTransport != nil {
            serverStatusStore.markRunning(transportMode: .sse)
        } else {
            serverStatusStore.markStopped()
            // EOF on stdin — the client disconnected. Tear down the process so
            // whatever launched us (claude-code, mcp inspector, etc.) sees a clean
            // exit.
            exit(0)
        }
    }
}

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

// MARK: - Runtime options

private enum MCPRuntimeTransportMode: String {
    case stdio
    case sse
    case both

    var includesStdio: Bool { self == .stdio || self == .both }
    var includesSSE: Bool { self == .sse || self == .both }

    var statusMode: MCPServerTransportMode {
        switch self {
        case .stdio: return .stdio
        case .sse: return .sse
        case .both: return .stdioAndSSE
        }
    }
}

private struct MCPRuntimeOptions {
    var transportMode: MCPRuntimeTransportMode?
    var ssePort: Int?
    var bindScope: MCPServerBindScope?
    var bearerToken: String?
}

private func parseRuntimeOptions() -> MCPRuntimeOptions {
    var options = MCPRuntimeOptions()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--stdio":
            options.transportMode = .stdio
        case "--sse":
            options.transportMode = .sse
        case "--both":
            options.transportMode = .both
        case "--transport":
            options.transportMode = parseTransportArgument(iterator.next())
        case "--port":
            options.ssePort = parsePortArgument(iterator.next())
        case "--bind":
            options.bindScope = parseBindArgument(iterator.next())
        case "--token":
            options.bearerToken = parseTokenArgument(iterator.next())
        case "--help", "-h":
            printRuntimeHelp()
            exit(0)
        default:
            stderrLog("unknown argument \(argument)")
            printRuntimeHelp()
            exit(64)
        }
    }
    return options
}

private func parseTransportArgument(_ value: String?) -> MCPRuntimeTransportMode {
    guard let value,
          let mode = MCPRuntimeTransportMode(rawValue: value.lowercased())
    else {
        stderrLog("invalid --transport value; expected stdio, sse, or both")
        exit(64)
    }
    return mode
}

private func parsePortArgument(_ value: String?) -> Int {
    guard let value, let port = Int(value) else {
        stderrLog("invalid --port value")
        exit(64)
    }
    return port
}

private func parseBindArgument(_ value: String?) -> MCPServerBindScope {
    guard let value,
          let scope = MCPServerBindScope(rawValue: value.lowercased())
    else {
        stderrLog("invalid --bind value; expected localhost or lan")
        exit(64)
    }
    return scope
}

private func parseTokenArgument(_ value: String?) -> String {
    guard let value, MCPBearerTokenValidator.isPlausible(value) else {
        stderrLog("invalid --token value")
        exit(64)
    }
    return MCPBearerTokenValidator.normalized(value)
}

private func printRuntimeHelp() {
    let help = """
    GargantuaMCP options:
      --transport stdio|sse|both   Select MCP transport. Defaults to stdio, or both when SSE is enabled in Settings.
      --stdio                      Shortcut for --transport stdio.
      --sse                        Shortcut for --transport sse.
      --both                       Shortcut for --transport both.
      --port 7493                  Override the SSE port.
      --bind localhost|lan         Bind SSE to 127.0.0.1 or all interfaces.
      --token TOKEN                Bearer token override for LAN SSE.

    Security:
      GargantuaMCP serves plain HTTP. For network clients, keep --bind localhost
      and terminate HTTPS in a reverse proxy that forwards to 127.0.0.1:7493.
      Use --bind lan only on trusted networks, with a bearer token and a TLS
      proxy in front of the port.
    """
    FileHandle.standardError.write(Data("\(help)\n".utf8))
}

private func clientFacingMessage(for error: Error) -> String {
    if let localized = error as? LocalizedError,
       let description = localized.errorDescription,
       !description.isEmpty {
        return description
    }
    return "MCP transport failed."
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

// MARK: - Graceful shutdown

//
// Install DispatchSource signal handlers so SIGTERM (Docker stop, launchd
// unload, systemd shutdown) and SIGINT (^C) cancel the SSE listener and
// mark the status store stopped before the process exits. Without this,
// the kernel kills the process while StatusStore still says "running",
// which leaves stale status entries that mislead the Settings UI until
// the next launch.
//
// The capture list snapshots `sseTransport` at install time, so the
// handler reads the final value assigned during SSE setup above without
// crossing thread boundaries on a top-level var.
private let shutdownQueue = DispatchQueue(
    label: "com.gargantua.mcp.shutdown",
    qos: .userInitiated
)
private let shutdownSources: [DispatchSourceSignal] = [SIGTERM, SIGINT].map { signo in
    // Mask the default disposition so DispatchSource owns delivery.
    signal(signo, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signo, queue: shutdownQueue)
    source.setEventHandler { [sseTransport, serverStatusStore] in
        sseTransport?.stop()
        serverStatusStore.markStopped()
        exit(0)
    }
    source.resume()
    return source
}
// Reference shutdownSources so ARC keeps the DispatchSource handles alive
// for the lifetime of the process.
withExtendedLifetime(shutdownSources) {}

dispatchMain()
