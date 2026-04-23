import Foundation

// Handler for the MCP `clean` tool (PRD §7.3 / §7.4). Takes a set of item
// IDs produced by a prior `scan`, resolves them against the scan-session
// cache, enforces the Phase 3 safety guardrails that can be checked at the
// handler layer, and delegates the actual removal to an injected `Cleaner`
// closure that wraps `CleanupEngine.clean`.
//
// Guardrails implemented here (PRD §7.4):
// - Unknown `item_ids` → `invalidParams`. A stale ID is a client bug, not a
//   silent no-op.
// - Any `safety == .protected_` item → whole request `invalidParams`. Matches
//   the PRD's "protected hard-reject": the server never destroys a protected
//   item even if the caller asked nicely and set `confirm: true`.
// - `confirm: true` is enforced at the type boundary by `MCPCleanInput`. Any
//   payload missing it or with `confirm: false` is rejected during decode,
//   which the dispatcher surfaces as `-32602 invalidParams`. That gives the
//   PRD's "review items require confirm" guardrail for free — reviews can
//   never reach this handler without an explicit affirmative.
// - `dry_run: true` short-circuits before `Cleaner` runs, returning a plan
//   shaped like a successful run so agents can preview impact. Dry runs are
//   deliberately exempt from the rate limiter and do not write audit entries
//   — they don't touch the disk, so the attack surface the guardrails exist
//   to cover isn't present.
// - Rate limit: by default, 1 clean op per 60 seconds per MCP client. Tripped
//   requests return `invalidParams` with a retry-after hint. The scope
//   (per-client) is enforced via `clientIDProvider`; unknown clients fall
//   back to the literal `"unknown"` key so they share a budget and cannot
//   bypass the limit by omitting `clientInfo`.
// - Audit: every non-dry-run invocation — success *or* failure — writes an
//   entry through the injected `auditRecorder`. The entry's UUID is what
//   `MCPCleanOutput.auditID` reports, so clients can cross-reference the
//   wire response against the persisted trail.
//
// Not implemented here (future tasks):
// - User notification + cancel window (Task 4 `gargantua-uxdr`).

/// Tool handler for `clean`.
public struct MCPCleanToolHandler: Sendable {

    /// Synchronous cleanup backend. Receives the resolved items and the
    /// caller's method choice and returns the aggregate `CleanupResult`.
    /// Throwing `MCPToolError` propagates with the appropriate JSON-RPC code;
    /// any other thrown error is surfaced to the client as a tool-domain
    /// `.failure(...)` result.
    ///
    /// Task 4 wiring note: `CleanupEngine.clean` is `@MainActor`, and the
    /// stdio transport currently runs on the main thread (see
    /// `GargantuaMCP/main.swift`). Wrapping the engine call in `runBlocking`
    /// the way `scan` does would deadlock — `runBlocking` parks the main
    /// thread on a semaphore while the detached Task it spawns tries to hop
    /// back to the main actor. The scan path avoids this because
    /// `NativeScanAdapter.scan` is not `@MainActor`. Task 4 must either run
    /// the transport off the main thread, or refactor `CleanupEngine.clean`
    /// to a non-`@MainActor` entry point, before adopting this typealias in
    /// production. The sync shape is preserved here so that refactor has a
    /// stable handler contract to target.
    public typealias Cleaner = @Sendable (_ items: [ScanResult], _ method: CleanupMethod) throws -> CleanupResult

    /// Produces the audit entry UUID for a call. Default returns a fresh
    /// `UUID()`; tests inject a deterministic UUID so the wire response and
    /// any persisted audit entry can be asserted against a known value.
    public typealias AuditIDGenerator = @Sendable () -> UUID

    /// Resolves the MCP client identity for the current request. `nil` means
    /// the client did not complete `initialize` or did not advertise
    /// `clientInfo.name`; the handler falls back to the sentinel
    /// `"unknown"` for both audit attribution and rate-limit sharding.
    public typealias ClientIDProvider = @Sendable () -> String?

    /// Persists an `AuditEntry`. Production wiring plugs in
    /// `AuditWriter.write(_:)`. Tests can capture calls for assertion.
    /// Throwing is non-fatal — the handler logs and continues so audit
    /// flakiness cannot mask a successful destructive operation.
    public typealias AuditRecorder = @Sendable (_ entry: AuditEntry) throws -> Void

    private let sessionCache: MCPScanSessionCache
    private let cleaner: Cleaner
    private let auditIDGenerator: AuditIDGenerator
    private let auditRecorder: AuditRecorder?
    private let rateLimiter: MCPRateLimiter?
    private let clientIDProvider: ClientIDProvider
    private let log: MCPDispatcherLog?

    public init(
        sessionCache: MCPScanSessionCache,
        cleaner: @escaping Cleaner,
        auditIDGenerator: @escaping AuditIDGenerator = { UUID() },
        auditRecorder: AuditRecorder? = nil,
        rateLimiter: MCPRateLimiter? = nil,
        clientIDProvider: @escaping ClientIDProvider = { nil },
        log: MCPDispatcherLog? = nil
    ) {
        self.sessionCache = sessionCache
        self.cleaner = cleaner
        self.auditIDGenerator = auditIDGenerator
        self.auditRecorder = auditRecorder
        self.rateLimiter = rateLimiter
        self.clientIDProvider = clientIDProvider
        self.log = log
    }

    /// Bridges this handler to the `MCPToolHandler` shape the dispatcher
    /// expects. Register with:
    /// `dispatcher.register(tool: .clean, handler: handler.toolHandler)`.
    public var toolHandler: MCPToolHandler {
        let this = self
        return { arguments in try this.handle(arguments) }
    }

    /// Sentinel client identifier used when the dispatcher has not captured
    /// a `clientInfo.name` yet. Exposed so tests and forensic tooling can
    /// filter audit entries that lack a proper attribution.
    public static let unknownClientSentinel = "unknown"

    /// Execute the handler against a decoded arguments payload. Exposed for
    /// unit tests that want to bypass the dispatcher.
    public func handle(_ arguments: MCPToolArguments) throws -> MCPToolCallResult {
        let input = try arguments.decode(MCPCleanInput.self)

        // Reject duplicate ids up front. A duplicate would cause the cleaner
        // to act on the same path twice — the first call moves the file, the
        // second fails with "file not found", which surfaces to the caller
        // as a silent partial failure rather than the client bug it is.
        if let duplicate = Self.firstDuplicate(in: input.itemIDs) {
            throw MCPToolError.invalidParams(
                "Duplicate item_id '\(duplicate)'. Each item_id must appear at most once per request."
            )
        }

        guard let method = Self.resolveMethod(input.method) else {
            throw MCPToolError.invalidParams(
                "Unknown method '\(input.method)'. Expected 'trash' or 'delete'."
            )
        }

        let (found, unknown) = sessionCache.lookupAll(ids: input.itemIDs)
        if !unknown.isEmpty {
            throw MCPToolError.invalidParams(Self.unknownIDsMessage(unknown))
        }

        // PRD §7.4 hard-reject: any protected item aborts the whole request.
        // We do not silently drop protected items and clean the rest — a
        // partial clean masking a protected reject would be worse than the
        // loud error.
        //
        // Note: `safety` is a snapshot taken at scan time. If the filesystem
        // content at a scanned path changes between scan and clean (e.g. a
        // rogue process replaces the file), the cached `safety` label is
        // stale. This handler does not revalidate. It is mitigated in
        // practice by CleanupEngine operating on the exact scanned path (not
        // following symlinks), and by the per-client rate limit + audit
        // trail which bound the replay window. A clean-time revalidation
        // would require re-scanning each item and is deferred — see the
        // task notes on `gargantua-afft`.
        let protected = found.filter { $0.safety == .protected_ }
        if !protected.isEmpty {
            throw MCPToolError.invalidParams(Self.protectedRejectMessage(protected))
        }

        let auditUUID = auditIDGenerator()

        if input.dryRun {
            // Dry-run is a preview: no disk writes, no rate-limit budget,
            // no audit entry. `auditID` in the output uses the generator's
            // UUID as a placeholder so the wire shape stays stable.
            return try Self.makeDryRunResult(
                items: found,
                method: method,
                auditID: auditUUID.uuidString
            )
        }

        let clientID = clientIDProvider() ?? Self.unknownClientSentinel

        if let limiter = rateLimiter {
            switch limiter.recordAndCheck(clientID: clientID, tool: MCPToolName.clean.rawValue) {
            case .allowed:
                break
            case .rejected(let retryAfter):
                // Failed rate-limit attempts are not audited — they never
                // reached the cleaner. Auditing rejected attempts would
                // let a client with a stuck loop spam the log; the limiter
                // itself is the forensic signal.
                throw MCPToolError.invalidParams(Self.rateLimitMessage(
                    window: limiter.window,
                    maxOps: limiter.maxOps,
                    retryAfter: retryAfter
                ))
            }
        }

        do {
            let result = try cleaner(found, method)
            recordAudit(
                entryID: auditUUID,
                clientID: clientID,
                requested: found,
                result: result,
                methodHint: method
            )
            return try Self.makeResult(
                result: result,
                method: method,
                auditID: auditUUID.uuidString
            )
        } catch let error as MCPToolError {
            // The cleaner signalled a protocol-level error (e.g. rejected
            // a method it didn't like). Audit the attempt before rethrowing
            // — from the destructive-ops perspective the client still made
            // an attempt worth recording.
            recordAudit(
                entryID: auditUUID,
                clientID: clientID,
                requested: found,
                result: nil,
                methodHint: method
            )
            throw error
        } catch {
            log?("clean handler error: \(error)")
            recordAudit(
                entryID: auditUUID,
                clientID: clientID,
                requested: found,
                result: nil,
                methodHint: method
            )
            return .failure("Clean failed: \(MCPEncoding.clientFacingMessage(for: error))")
        }
    }

    // MARK: - Helpers

    /// Returns the first id that appears more than once in `ids`, or nil if
    /// every id is unique. Preserves the caller's order so the error message
    /// points at the first offending entry.
    private static func firstDuplicate(in ids: [String]) -> String? {
        var seen: Set<String> = []
        seen.reserveCapacity(ids.count)
        for id in ids {
            if seen.contains(id) { return id }
            seen.insert(id)
        }
        return nil
    }

    private static func resolveMethod(_ raw: String) -> CleanupMethod? {
        switch raw {
        case "trash": return .trash
        case "delete": return .delete
        default: return nil
        }
    }

    private static func unknownIDsMessage(_ unknown: [String]) -> String {
        let preview = unknown.prefix(5).joined(separator: ", ")
        let more = unknown.count > 5 ? " and \(unknown.count - 5) more" : ""
        return "Unknown item_ids: \(preview)\(more). "
            + "IDs must come from the most recent scan result."
    }

    private static func protectedRejectMessage(_ protected: [ScanResult]) -> String {
        let preview = protected.prefix(3).map(\.id).joined(separator: ", ")
        let more = protected.count > 3 ? " and \(protected.count - 3) more" : ""
        return "Request rejected: \(protected.count) protected item(s) cannot be cleaned via MCP "
            + "(\(preview)\(more))."
    }

    private static func rateLimitMessage(
        window: TimeInterval,
        maxOps: Int,
        retryAfter: TimeInterval
    ) -> String {
        let windowSeconds = Int(window.rounded())
        let retrySeconds = max(1, Int(retryAfter.rounded(.up)))
        let budget = maxOps == 1
            ? "1 clean op per \(windowSeconds)s"
            : "\(maxOps) clean ops per \(windowSeconds)s"
        return "MCP clean rate limit exceeded (\(budget) per client). "
            + "Cool-down active; retry in \(retrySeconds)s."
    }

    /// Builds the audit entry and passes it to the injected recorder.
    /// Swallowing-but-logging a recorder failure is deliberate: audit is
    /// observability and should never mask or reverse a destructive op that
    /// already executed.
    private func recordAudit(
        entryID: UUID,
        clientID: String,
        requested: [ScanResult],
        result: CleanupResult?,
        methodHint: CleanupMethod
    ) {
        guard let auditRecorder else { return }

        let files = requested.map { AuditFile(path: $0.path, size: $0.size) }

        let highestSafety = requested.map(\.safety).reduce(SafetyLevel.safe) { current, next in
            switch (current, next) {
            case (.protected_, _), (_, .protected_): .protected_
            case (.review, _), (_, .review): .review
            default: .safe
            }
        }

        let entry = AuditEntry(
            id: entryID,
            tool: "native",
            command: "clean",
            files: files,
            safetyLevel: highestSafety,
            confirmationMethod: .mcp,
            cleanupMethod: result?.cleanupMethod ?? methodHint,
            bytesFreed: result?.totalFreed ?? 0,
            transport: "mcp",
            clientID: clientID
        )

        do {
            try auditRecorder(entry)
        } catch {
            log?("clean audit record failed: \(error)")
        }
    }

    /// Shape a successful `CleanupResult` into an `MCPCleanOutput`. Per-item
    /// outcomes fold the engine's two-state success/fail into the three-state
    /// wire vocabulary `moved | skipped | failed`. Task 2 does not produce
    /// `"skipped"` itself — protected items are rejected upstream before the
    /// engine runs, so every engine result maps to `moved` or `failed`. The
    /// `skipped` slot stays in the vocabulary so later tasks (e.g. rate-limit
    /// partial skips) can emit it without a wire format change.
    ///
    /// `bytes_freed` and `freed` are sourced from `ScanResult.size` (the
    /// scan-time sample) rather than actual post-clean disk delta — engine
    /// doesn't currently track actual bytes removed (e.g. the
    /// `emptyTrashContainer` path touches whatever Trash contains now, not
    /// what it contained at scan time). Agents should treat `freed` as a
    /// best-effort estimate, not a ground truth.
    private static func makeResult(
        result: CleanupResult,
        method: CleanupMethod,
        auditID: String
    ) throws -> MCPToolCallResult {
        var perItem: [MCPCleanItemResult] = []
        perItem.reserveCapacity(result.itemResults.count)
        var movedCount = 0
        var totalFreed: Int64 = 0

        for entry in result.itemResults {
            if entry.succeeded {
                movedCount += 1
                totalFreed += entry.item.size
                perItem.append(MCPCleanItemResult(
                    id: entry.item.id,
                    outcome: "moved",
                    reason: nil,
                    bytesFreed: entry.item.size
                ))
            } else {
                perItem.append(MCPCleanItemResult(
                    id: entry.item.id,
                    outcome: "failed",
                    reason: entry.error,
                    bytesFreed: nil
                ))
            }
        }

        let output = MCPCleanOutput(
            cleaned: movedCount,
            freed: AlertItem.formatBytes(totalFreed),
            method: method.rawValue,
            auditID: auditID,
            perItem: perItem
        )
        let payload = try MCPEncoding.encodeAsJSONAny(output)
        return .structured(payload, summary: summary(for: output))
    }

    /// Dry-run plan: present the set as if every item would be successfully
    /// moved. Bytes are summed verbatim from the scan cache — the preview
    /// matches the scan's reported size rather than re-sampling disk. The
    /// caller opted into dry-run by setting `dry_run: true`; we do not also
    /// add a top-level flag to the output because the request itself already
    /// documents the mode.
    private static func makeDryRunResult(
        items: [ScanResult],
        method: CleanupMethod,
        auditID: String
    ) throws -> MCPToolCallResult {
        var perItem: [MCPCleanItemResult] = []
        perItem.reserveCapacity(items.count)
        var totalFreed: Int64 = 0

        for item in items {
            totalFreed += item.size
            perItem.append(MCPCleanItemResult(
                id: item.id,
                outcome: "moved",
                reason: nil,
                bytesFreed: item.size
            ))
        }

        let output = MCPCleanOutput(
            cleaned: items.count,
            freed: AlertItem.formatBytes(totalFreed),
            method: method.rawValue,
            auditID: auditID,
            perItem: perItem
        )
        let payload = try MCPEncoding.encodeAsJSONAny(output)
        return .structured(
            payload,
            summary: "[dry-run] would clean \(items.count) item(s); \(output.freed) reclaimable."
        )
    }

    private static func summary(for output: MCPCleanOutput) -> String {
        let total = output.perItem.count
        let failed = total - output.cleaned
        if failed > 0 {
            return "Cleaned \(output.cleaned) of \(total) item(s); \(failed) failed. "
                + "Freed \(output.freed)."
        }
        return "Cleaned \(output.cleaned) item(s); freed \(output.freed)."
    }
}
