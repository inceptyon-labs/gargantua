import Foundation
import GargantuaCore
import GargantuaLicensing

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

private let runtimeOptions = parseRuntimeOptions(log: stderrLog)
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

// Per-connection scan-session caches: `scan` populates the calling
// connection's cache, `clean`/`explain` resolve item_ids only against that
// same connection's cache. In dual-transport (`.both`) mode this keeps client
// A's item_ids unresolvable by client B.
let scanSessionCacheRegistry = MCPScanSessionCacheRegistry()

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
    let pathExclusions = loadPathExclusionPatterns()
    let adapter = try ProfileScanAdapterFactory.make(
        profile: profile,
        staleVersionPinnedPaths: pathExclusions,
        aiModelExcludedPaths: pathExclusions
    )
    return try runBlocking {
        try await adapter.scan(progress: nil)
    }
}

let scanHandler = MCPScanToolHandler(
    scanner: scanRunner,
    profileResolver: scanProfileResolver,
    sessionCacheProvider: { scanSessionCacheRegistry.cache(for: dispatcher.currentCallConnection()) },
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

// Rule-engine classifier for `explain` by path. An accepted absolute path is
// reverse-matched against the active profile's rule set so it gets the same
// Trust Layer verdict a scan would assign — without running a full scan. The
// adapter is rebuilt per call (rare, interactive) so it always reflects the
// current active profile and any edited rule files. A failure (rules dir
// missing, profile store down) returns nil so the provider falls back to the
// AI-pending shell rather than erroring.
private let explainPathClassify: MCPExplainToolHandler.PathClassify = { path in
    do {
        let profile = try loadProfileCatalog().resolve(nil)
        let adapter = try NativeScanAdapter.loadDefaults(profile: profile)
        return adapter.classify(path: path)
    } catch {
        stderrLog("explain path classify failed: \(error)")
        return nil
    }
}
let explainHandler = MCPExplainToolHandler(
    explainProvider: MCPExplainToolHandler.defaultFilesystemProvider(
        receiptLookup: explainReceiptLookup,
        itemLookup: { id in
            scanSessionCacheRegistry.cache(for: dispatcher.currentCallConnection()).lookup(id: id)
        },
        pathClassify: explainPathClassify
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

// MARK: - list_background_items

let listBackgroundItemsHandler = MCPListBackgroundItemsToolHandler(
    scanProvider: { DefaultBackgroundItemScanner().scan() },
    log: stderrLog
)
dispatcher.register(tool: .listBackgroundItems, handler: listBackgroundItemsHandler.toolHandler)

// MARK: - clean (Phase 3)

// Shared infrastructure for Phase 3 destructive tools. The `clean` handler
// is the first consumer; future destructive tools share the rate limiter and
// audit writer so their budgets and forensic trails are cross-cutting.
private let auditWriter = AuditWriter()
private let cleanRateLimiter = MCPRateLimiter() // 1 op / 60s default
private let cleanupEngine = CleanupEngine()
private let cleanNotificationService = MCPCleanNotificationFactory.automatic(
    gracePeriod: 5,
    allowsUnattendedClean: runtimeOptions.allowsUnattendedClean,
    log: stderrLog
)

// Production cleaner. Takes the license gate, posts the user-facing
// notification (PRD §7.4), waits the grace period, then either delegates to
// `CleanupEngine.clean` or short-circuits with an all-failed result if the
// user tapped Cancel. The handler audits either way — a refusal produces an
// entry with `bytesFreed: 0` so forensic tooling sees the attempted op even if
// nothing touched disk.
//
// The gate lives here rather than inside `MCPCleanToolHandler` because the
// handler's `Cleaner` contract is deliberately synchronous while
// `canExecuteDestructiveAction()` is async on an actor; this closure already
// bridges async work through `runBlocking`, so it is the natural seam. Dry runs
// never reach the cleaner, so previews stay available to unlicensed users —
// matching the GUI, where scanning is always free.
private let cleaner: MCPCleanToolHandler.Cleaner = { items, method in
    let authorization: DestructiveActionAuthorization
    switch try runBlocking({ await LicenseGate.shared.authorize(.mcpClean) }) {
    case .failure:
        throw MCPToolError.invalidParams(
            "Gargantua's trial has expired. Destructive MCP operations require a license key; "
                + "scans and dry runs remain available."
        )
    case .success(let granted):
        authorization = granted
    }

    let decision = cleanNotificationService.request(
        items: items,
        method: method,
        clientID: dispatcher.currentCallClientIdentity()?.name
            ?? MCPCleanToolHandler.unknownClientSentinel
    )
    switch decision {
    case .cancelled, .refused:
        let error = if case .refused(let reason) = decision {
            reason
        } else {
            "User cancelled via MCP notification"
        }
        return CleanupResult(
            itemResults: items.map {
                CleanupItemResult(item: $0, succeeded: false, error: error)
            },
            cleanupMethod: method
        )
    case .proceed:
        return try runBlocking {
            await cleanupEngine.clean(items, method: method, authorization: authorization)
        }
    }
}

let cleanHandler = MCPCleanToolHandler(
    sessionCacheProvider: { scanSessionCacheRegistry.cache(for: dispatcher.currentCallConnection()) },
    cleaner: cleaner,
    auditRecorder: { try auditWriter.write($0) },
    rateLimiter: cleanRateLimiter,
    clientIDProvider: { dispatcher.currentCallClientIdentity()?.name },
    // Rate-limit shard. Deliberately the connection, not the declared client
    // name: `initialize` is an ordinary dispatchable method with no
    // once-per-connection guard and last-initialize-wins, so a client that
    // renames itself between cleans would otherwise get a fresh budget every
    // time without even reconnecting. The connection is established by the
    // transport and cannot be re-declared by the peer. The declared name is
    // still what lands in the audit entry, which is where a human-meaningful
    // attribution belongs.
    rateLimitKeyProvider: { String(describing: dispatcher.currentCallConnection()) },
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
        handler: { request, connection in dispatcher.dispatch(request, connection: connection) },
        onConnectionClose: { connection in
            scanSessionCacheRegistry.evict(connection)
            dispatcher.evictClientIdentity(for: connection)
        },
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
    handler: { request in dispatcher.dispatch(request, connection: .stdio) },
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
    // `sseTransport` is a `var`, and a mutable top-level global is @MainActor
    // under Swift 6 — so it needs an explicit capture to snapshot its value for
    // the nonisolated queue. The immutable `let` globals referenced below need
    // no capture now that their types are Sendable. The single assignment in the
    // SSE setup block above happens before this closure is formed, so the
    // snapshot is the final value — same reasoning as the shutdown handler below.
    transportQueue.async { [sseTransport] in
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

private func clientFacingMessage(for error: Error) -> String {
    if let localized = error as? LocalizedError,
       let description = localized.errorDescription,
       !description.isEmpty {
        return description
    }
    return "MCP transport failed."
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
