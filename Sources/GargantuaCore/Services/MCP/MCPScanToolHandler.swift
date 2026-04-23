import Foundation

// Handler for the MCP `scan` tool. Maps the validated `MCPScanInput` to a
// concrete `CleanupProfile`, runs a scan via the injected `Scanner`, and
// shapes the resulting `[ScanResult]` into the `MCPScanOutput` payload the
// PRD §7.3 contract promises.
//
// The handler is synchronous to match `MCPToolHandler`. Async scan backends
// (e.g. `NativeScanAdapter`) must be bridged to sync at the call site that
// constructs the `Scanner` closure — see `Sources/GargantuaMCP/main.swift`.
//
// Dry-run is already enforced at the type boundary: `MCPScanInput.init(from:)`
// rejects any payload whose `dry_run` is not `true`. No additional guard is
// needed here, and that's the point — there's no code path through this
// handler that could execute a destructive scan.

/// Tool handler for `scan`.
public struct MCPScanToolHandler: Sendable {

    /// Synchronous scan backend. Receives the fully-resolved profile (with any
    /// caller-provided category override already applied) and returns the raw
    /// scan results. Throwing `MCPToolError.invalidParams` or `.internalError`
    /// propagates with the appropriate JSON-RPC code; any other thrown error
    /// is surfaced to the client as a tool-domain `.failure(...)` result.
    public typealias Scanner = @Sendable (_ profile: CleanupProfile) throws -> [ScanResult]

    /// Resolves the optional profile id from `MCPScanInput` into a concrete
    /// profile. Throws `MCPToolError.invalidParams` for unknown ids. Nil input
    /// should resolve to the server's default profile.
    public typealias ProfileResolver = @Sendable (_ requestedID: String?) throws -> CleanupProfile

    private let scanner: Scanner
    private let profileResolver: ProfileResolver
    private let sessionCache: MCPScanSessionCache?
    private let log: MCPDispatcherLog?

    public init(
        scanner: @escaping Scanner,
        profileResolver: @escaping ProfileResolver,
        sessionCache: MCPScanSessionCache? = nil,
        log: MCPDispatcherLog? = nil
    ) {
        self.scanner = scanner
        self.profileResolver = profileResolver
        self.sessionCache = sessionCache
        self.log = log
    }

    /// Bridges this handler to the `MCPToolHandler` shape the dispatcher
    /// expects, so registration is a one-liner:
    /// `dispatcher.register(tool: .scan, handler: handler.toolHandler)`.
    public var toolHandler: MCPToolHandler {
        let this = self
        return { arguments in try this.handle(arguments) }
    }

    /// Execute the handler against a decoded arguments payload. Exposed for
    /// unit tests that want to bypass the dispatcher.
    public func handle(_ arguments: MCPToolArguments) throws -> MCPToolCallResult {
        let input = try arguments.decode(MCPScanInput.self)
        // `input.dryRun` is guaranteed true by `MCPScanInput` — its Decodable
        // rejects any payload with `dry_run: false`. No further guard needed.

        // Empty `categories` is ambiguous under `NativeScanAdapter`'s filter
        // (empty == match all), so reject it rather than silently producing
        // a full scan. Clients can omit the field entirely to use the
        // profile's own categories.
        if let override = input.categories, override.isEmpty {
            throw MCPToolError.invalidParams(
                "categories must be non-empty when provided; omit the field to use the profile's default categories."
            )
        }

        let baseProfile = try profileResolver(input.profile)
        let effectiveProfile = Self.applyCategoryOverride(
            baseProfile: baseProfile,
            categories: input.categories
        )

        let results: [ScanResult]
        do {
            results = try scanner(effectiveProfile)
        } catch let error as MCPToolError {
            // The scanner explicitly signalled a protocol-level error
            // (malformed params or server misconfiguration it chose to
            // expose). Let the dispatcher map to the right JSON-RPC code.
            throw error
        } catch {
            // Any other scanner failure is a tool-domain error: the call
            // itself was well-formed but execution failed. MCP spec
            // requires this to surface as `isError: true` in the result,
            // not as a JSON-RPC error.
            //
            // Only `LocalizedError.errorDescription` values are forwarded
            // to the client — plain `Error` reflections can expose paths
            // or internal state. Unknown errors get a generic message and
            // the raw detail goes to stderr via the log hook.
            log?("scan handler error: \(error)")
            return .failure("Scan failed: \(MCPEncoding.clientFacingMessage(for: error))")
        }

        // Populate the scan-session cache before shaping output, so that a
        // follow-up `clean` call can resolve these exact IDs. Last-scan-wins:
        // a fresh scan always replaces any prior session state. Failures
        // above threw before reaching here, so the cache is never polluted
        // with a half-finished scan's results.
        sessionCache?.replace(with: results)

        let output = Self.makeOutput(from: results)
        let payload = try MCPEncoding.encodeAsJSONAny(output)
        return .structured(payload, summary: Self.summary(for: output))
    }

    // MARK: - Helpers

    private static func applyCategoryOverride(
        baseProfile: CleanupProfile,
        categories: [String]?
    ) -> CleanupProfile {
        guard let categories, !categories.isEmpty else { return baseProfile }
        return CleanupProfile(
            id: baseProfile.id,
            name: baseProfile.name,
            description: baseProfile.description,
            categories: categories,
            safetyOverrides: baseProfile.safetyOverrides,
            isCustom: baseProfile.isCustom
        )
    }

    /// Shape `[ScanResult]` into the PRD §7.3 output:
    /// - `total_reclaimable` sums safe + review bytes (protected are not
    ///   actionable and are excluded from the reclaimable tally).
    /// - `summary` counts every result; `safe_size` / `review_size` are the
    ///   formatted byte totals per tier. Protected items have no size tally
    ///   per the PRD contract (only a count).
    static func makeOutput(from results: [ScanResult]) -> MCPScanOutput {
        var items: [MCPScanItem] = []
        items.reserveCapacity(results.count)
        var safeCount = 0
        var reviewCount = 0
        var protectedCount = 0
        var safeBytes: Int64 = 0
        var reviewBytes: Int64 = 0

        for result in results {
            items.append(MCPScanItem(
                id: result.id,
                name: result.name,
                path: result.path,
                size: AlertItem.formatBytes(result.size),
                safety: result.safety.rawValue,
                confidence: result.confidence,
                explanation: result.explanation,
                source: result.source.name,
                lastAccessed: result.lastAccessed,
                category: result.category
            ))
            switch result.safety {
            case .safe:
                safeCount += 1
                safeBytes += result.size
            case .review:
                reviewCount += 1
                reviewBytes += result.size
            case .protected_:
                protectedCount += 1
            }
        }

        return MCPScanOutput(
            totalReclaimable: AlertItem.formatBytes(safeBytes + reviewBytes),
            items: items,
            summary: MCPScanSummary(
                safeCount: safeCount,
                safeSize: AlertItem.formatBytes(safeBytes),
                reviewCount: reviewCount,
                reviewSize: AlertItem.formatBytes(reviewBytes),
                protectedCount: protectedCount
            )
        )
    }

    private static func summary(for output: MCPScanOutput) -> String {
        let tierSummary = "\(output.summary.safeCount) safe, "
            + "\(output.summary.reviewCount) review, "
            + "\(output.summary.protectedCount) protected"
        return "Scan found \(output.items.count) items (\(tierSummary)); "
            + "\(output.totalReclaimable) reclaimable."
    }
}
