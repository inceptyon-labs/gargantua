import AppKit
import Foundation
import GargantuaLicensing

/// Result of cleaning a single item.
public struct CleanupItemResult: Sendable {
    /// The scan result that was cleaned.
    public let item: ScanResult
    /// Whether the cleanup succeeded.
    public let succeeded: Bool
    /// The new URL (Trash location) if the item was moved successfully.
    public let trashURL: URL?
    /// Error description if the cleanup failed.
    public let error: String?
    /// Bytes this operation actually reclaimed. Defaults to the scan-time
    /// `item.size` for a normal success and `0` for a failure, but callers pass
    /// `0` explicitly when the item was already gone (nothing was freed by us)
    /// so aggregate accounting doesn't credit space the app never reclaimed.
    public let bytesFreed: Int64

    public init(
        item: ScanResult,
        succeeded: Bool,
        trashURL: URL? = nil,
        error: String? = nil,
        bytesFreed: Int64? = nil
    ) {
        self.item = item
        self.succeeded = succeeded
        self.trashURL = trashURL
        self.error = error
        self.bytesFreed = bytesFreed ?? (succeeded ? item.size : 0)
    }
}

/// Aggregate result of a cleanup operation.
public struct CleanupResult: Sendable {
    /// Per-item results.
    public let itemResults: [CleanupItemResult]
    /// How the items were removed.
    public let cleanupMethod: CleanupMethod
    /// Timestamp when the cleanup completed.
    public let completedAt: Date

    public var succeededItems: [CleanupItemResult] {
        itemResults.filter(\.succeeded)
    }

    public var failedItems: [CleanupItemResult] {
        itemResults.filter { !$0.succeeded }
    }

    public var totalFreed: Int64 {
        // Count each freed byte once. Two things would otherwise inflate this:
        // already-gone items (credited via `bytesFreed == 0`, not `item.size`),
        // and overlapping selections — a Hugging Face whole-repo removal plus a
        // stale-revision prune of the same repo dir, or a parent dir selected
        // alongside a child. Collapse identical paths to their largest estimate,
        // then drop any path nested under another selected path (the ancestor's
        // removal already reclaimed it).
        let succeeded = succeededItems
        guard !succeeded.isEmpty else { return 0 }

        var largestByPath: [String: Int64] = [:]
        for result in succeeded {
            let key = Self.normalizedFreedPath(result.item.path)
            largestByPath[key] = Swift.max(largestByPath[key] ?? 0, result.bytesFreed)
        }

        let paths = Array(largestByPath.keys)
        return paths.reduce(Int64(0)) { running, path in
            let nestedUnderAnother = paths.contains { other in
                other != path && path.hasPrefix(other + "/")
            }
            return nestedUnderAnother ? running : running + (largestByPath[path] ?? 0)
        }
    }

    /// Trailing-slash-normalized path used to de-duplicate overlapping freed
    /// selections. Pure string work — no symlink resolution or disk access, so
    /// the scan-time path compares identically to itself.
    private static func normalizedFreedPath(_ path: String) -> String {
        var normalized = path
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    public var allSucceeded: Bool {
        failedItems.isEmpty
    }

    public init(
        itemResults: [CleanupItemResult],
        cleanupMethod: CleanupMethod = .trash,
        completedAt: Date = Date()
    ) {
        self.itemResults = itemResults
        self.cleanupMethod = cleanupMethod
        self.completedAt = completedAt
    }
}

/// Removes files via the selected cleanup method and tracks per-item results.
public final class CleanupEngine: Sendable {
    /// Override the home directory used to resolve `~/.Trash`. Tests only.
    private let homeDirectory: URL
    private let trashMover: any TrashMoving
    private let protectedRootPolicy: ProtectedRootPolicy
    private let commandActionRunner: CommandActionCleanupRouter
    private let ollamaModelRunner: OllamaModelCleanupRouter
    /// When set, items that fail removal with a permission/ownership error are
    /// retried through the root-privileged helper. Left `nil` in headless
    /// contexts (the MCP server) and tests so they never silently escalate.
    private let privilegedHelper: (any PrivilegedUninstallHelping)?
    /// Existence probe used to detect items that vanished between scan and clean
    /// (e.g. a browser that wiped its cache on quit). Injectable so tests that
    /// exercise the trash mover with synthetic paths aren't short-circuited.
    let fileExists: @Sendable (String) -> Bool

    /// - Parameter privilegedHelper: pass `XPCPrivilegedUninstallHelper()` from
    ///   interactive flows to recover root-owned items that POSIX `EPERM`
    ///   blocked. Defaults to `nil` (no escalation).
    public init(
        privilegedHelper: (any PrivilegedUninstallHelping)? = nil
    ) {
        self.homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        self.trashMover = FallbackTrashMover()
        self.protectedRootPolicy = .loadDefault()
        self.commandActionRunner = CommandActionCleanupRouter.production()
        self.ollamaModelRunner = OllamaModelCleanupRouter.production()
        self.privilegedHelper = privilegedHelper
        self.fileExists = { FileManager.default.fileExists(atPath: $0) }
    }

    /// Test-only initializer. Use the default `init()` in app code. `fileExists`
    /// defaults to "everything exists" so mover/escalation tests are unaffected;
    /// the already-gone path is exercised by passing `{ _ in false }`.
    internal init(
        homeDirectoryForTesting: URL,
        trashMover: any TrashMoving = FallbackTrashMover(),
        protectedRootPolicy: ProtectedRootPolicy = .loadDefault(),
        commandActionRunner: CommandActionCleanupRouter = .disabled,
        ollamaModelRunner: OllamaModelCleanupRouter = .disabled,
        privilegedHelper: (any PrivilegedUninstallHelping)? = nil,
        fileExists: @escaping @Sendable (String) -> Bool = { _ in true }
    ) {
        self.homeDirectory = homeDirectoryForTesting
        self.trashMover = trashMover
        self.protectedRootPolicy = protectedRootPolicy
        self.commandActionRunner = commandActionRunner
        self.ollamaModelRunner = ollamaModelRunner
        self.privilegedHelper = privilegedHelper
        self.fileExists = fileExists
    }

    /// Remove the given scan results with the selected cleanup method.
    ///
    /// Each file is handled individually so partial failures are tracked.
    /// Returns a `CleanupResult` with per-item success/failure details.
    ///
    /// - Parameters:
    ///   - authorization: Proof the license gate allowed this operation. Obtained
    ///     from `LicenseGate.authorize(_:)`; unforgeable by construction, so a new
    ///     destructive surface cannot reach this method without being gated.
    @MainActor
    public func clean(
        _ items: [ScanResult],
        method: CleanupMethod = .trash,
        authorization: DestructiveActionAuthorization
    ) async -> CleanupResult {
        await clean(items, method: method, observer: nil, authorization: authorization)
    }

    /// Variant that emits a `ScanProgressEvent` per item to feed the
    /// EventHorizon console during the cleaning phase. Successful removals
    /// surface as `.match` (with bytes); failures surface as `.failed`.
    ///
    /// - Parameters:
    ///   - authorization: Proof the license gate allowed this operation. Obtained
    ///     from `LicenseGate.authorize(_:)`; unforgeable by construction, so a new
    ///     destructive surface cannot reach this method without being gated.
    @MainActor
    public func clean(
        _ items: [ScanResult],
        method: CleanupMethod = .trash,
        observer: (any ScanProgressObserving)?,
        authorization: DestructiveActionAuthorization
    ) async -> CleanupResult {
        var results: [CleanupItemResult] = []

        for item in items {
            // Honor cooperative cancellation between items so the user's
            // "Sever Tether" abort actually stops the loop. Items already
            // deleted stay deleted; the partial CleanupResult flows through
            // to the summary so the user can see what got cleaned.
            if Task.isCancelled { break }
            let url = URL(fileURLWithPath: item.path)
            let result = await cleanSingle(url: url, item: item, method: method)
            if let observer {
                if result.succeeded {
                    observer.didEmit(ScanProgressEvent(
                        path: item.path,
                        outcome: .match,
                        bytes: result.bytesFreed
                    ))
                } else {
                    observer.didEmit(ScanProgressEvent(
                        path: item.path,
                        outcome: .failed(reason: result.error ?? "unknown error")
                    ))
                }
            }
            results.append(result)
        }

        let recovered = await escalatePermissionFailures(results, observer: observer)
        return CleanupResult(itemResults: recovered, cleanupMethod: method)
    }

    /// Retry permission-class failures through the root-privileged helper.
    ///
    /// Full Disk Access lets us read root-owned paths but not delete them; the
    /// helper (running as root) is the only path that can recycle them. No-ops
    /// when no helper was injected, so headless/test callers are unaffected.
    /// Escalation always moves to Trash even for a `.delete` request — the
    /// helper supports recycle only, and recoverable-but-trashed beats failed.
    @MainActor
    private func escalatePermissionFailures(
        _ results: [CleanupItemResult],
        observer: (any ScanProgressObserving)?
    ) async -> [CleanupItemResult] {
        guard let privilegedHelper else { return results }

        let escalatable = results.enumerated().filter { _, result in
            !result.succeeded
                && !result.item.isCommandAction
                && !result.item.isOllamaModel
                && !result.item.isHuggingFaceRevisionPrune
                && CleanupFailureClassifier.isElevatable(result.error)
        }
        guard !escalatable.isEmpty else { return results }

        let request = PrivilegedUninstallRequest(
            planID: UUID(),
            scanResults: escalatable.map(\.element.item)
        )
        let elevated = await privilegedHelper.movePrivilegedItemsToTrash(
            request,
            authorization: .privilegedHelperApproved
        )
        let elevatedByID = Dictionary(
            elevated.map { ($0.item.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var merged = results
        for (index, original) in escalatable {
            guard let outcome = elevatedByID[original.item.id] else { continue }
            // Keep the original permission/ownership error (so the summary's
            // classifier still routes to the right remediation prompt) but append
            // the helper's reason when it differs — otherwise a real helper-side
            // failure (rejected path, trashItem error) is invisible and
            // undiagnosable, which is exactly how the firmlink bug stayed hidden.
            let mergedError: String?
            if outcome.succeeded {
                mergedError = nil
            } else if let helperError = outcome.error,
                      let originalError = original.error,
                      helperError != originalError {
                mergedError = "\(originalError) (privileged removal also failed: \(helperError))"
            } else {
                mergedError = outcome.error ?? original.error
            }
            merged[index] = CleanupItemResult(
                item: original.item,
                succeeded: outcome.succeeded,
                trashURL: outcome.trashURL,
                error: mergedError
            )
            if outcome.succeeded {
                observer?.didEmit(ScanProgressEvent(
                    path: original.item.path,
                    outcome: .match,
                    bytes: original.item.size
                ))
            }
        }
        return merged
    }

    @MainActor
    private func cleanSingle(url: URL, item: ScanResult, method: CleanupMethod) async -> CleanupItemResult {
        // Command-action items are routed through the executor regardless of
        // the requested `method` — `path` would try to trash a string like
        // "xcrun simctl delete unavailable", which is not what the user
        // confirmed. The executor writes its own kind: command audit entry
        // with the captured tool version, exit code, and arguments.
        if item.isCommandAction {
            // The runner shells out (executor.preview + execute) and can block
            // for up to 2x the rule timeout. Run it off the main actor so a
            // long-running command doesn't beach-ball the confirmation modal.
            let runner = commandActionRunner
            let tier = confirmationTier(for: [item])
            let capturedItem = item
            return await Task.detached(priority: .userInitiated) {
                runner.run(item: capturedItem, confirmationMethod: tier)
            }.value
        }

        // Ollama models are removed through Ollama's own delete (shared blobs are
        // GC'd by the daemon), never by trashing the manifest path.
        if item.isOllamaModel {
            return await ollamaModelRunner.run(item: item)
        }

        // Hugging Face revision pruning removes a recomputed set of detached
        // snapshot dirs + newly-orphaned blobs, not the repo path itself.
        if item.isHuggingFaceRevisionPrune {
            return await pruneHuggingFaceRevisions(item: item, method: method)
        }

        // Already gone. Apps like browsers wipe and recreate their cache on quit,
        // and a path can vanish between scan and clean, so the directory the scan
        // recorded may no longer exist. The user wanted it gone and it is — count
        // it as removed instead of reporting a confusing "couldn't be removed",
        // but credit zero bytes: we didn't reclaim the scan-time size, something
        // else already did.
        if !fileExists(url.path) {
            return CleanupItemResult(item: item, succeeded: true, bytesFreed: 0)
        }

        if let protectedRoot = protectedRootPolicy.protectionReason(for: url, homeDirectory: homeDirectory) {
            return CleanupItemResult(
                item: item,
                succeeded: false,
                error: "Skipped \(protectedRoot): \(url.path)"
            )
        }

        // Special case: the Trash container itself cannot be removed or
        // recycled. Empty its contents instead so "Move to Trash" and
        // "Delete Permanently" both do the right thing.
        if isTrashContainer(url) {
            return await emptyTrashContainer(item: item)
        }

        // TOCTOU guard: the path the scan recorded as a real file could have had
        // a symlink swapped into its parent chain before the user confirmed the
        // clean. Both `trashItem` and `removeItem` follow symlinked parents, so
        // refuse rather than risk deleting the link's target. A symlink ancestor
        // the scan already resolved through (a symlinked scan root) is allowed;
        // only a post-scan change is a swap. The privileged path enforces the
        // same rule in the helper.
        guard SymlinkSwapGuard.isUnchanged(url, scanTimeResolvedParent: item.scanTimeResolvedParent) else {
            return CleanupItemResult(
                item: item,
                succeeded: false,
                error: "Skipped (path now resolves through a symlink): \(url.path)"
            )
        }

        switch method {
        case .trash:
            return await recycleSingle(url: url, item: item)
        case .delete:
            return await deleteSingle(url: url, item: item)
        case .toolNative:
            return CleanupItemResult(
                item: item,
                succeeded: false,
                error: "Tool-native cleanup is not supported by CleanupEngine."
            )
        }
    }

    /// Removal attempts and the delay between them for a *transient* failure —
    /// e.g. a just-quit app whose helper process is still releasing a cache file.
    /// Permission/ownership failures are never retried (they escalate instead),
    /// so the 37-items-failed permission case adds no extra latency.
    private static let maxRemovalAttempts = 3
    private static let transientRetryDelay: UInt64 = 700_000_000 // 0.7s

    /// A failure that may clear on its own (a process releasing a handle), as
    /// opposed to a permission/ownership failure (escalates) or a missing file.
    private func isTransientRemovalFailure(_ message: String) -> Bool {
        !CleanupFailureClassifier.isElevatable(message)
            && !message.lowercased().contains("no such file")
    }

    /// Move a single URL to Trash via the direct macOS Trash API, with an
    /// `NSWorkspace.recycle` fallback. Retries a transient hold (e.g. a
    /// browser's helper still releasing the cache right after the user quit it
    /// via the Quit button).
    @MainActor
    func recycleSingle(url: URL, item: ScanResult) async -> CleanupItemResult {
        var lastError = "unknown error"
        for attempt in 1 ... Self.maxRemovalAttempts {
            do {
                let trashURL = try await trashMover.moveToTrash(url)
                return CleanupItemResult(item: item, succeeded: true, trashURL: trashURL)
            } catch {
                // Vanished mid-attempt (e.g. the app cleared it) — goal met, but
                // we reclaimed nothing ourselves, so credit zero bytes.
                if !fileExists(url.path) {
                    return CleanupItemResult(item: item, succeeded: true, bytesFreed: 0)
                }
                lastError = error.localizedDescription
                if attempt < Self.maxRemovalAttempts, isTransientRemovalFailure(lastError) {
                    try? await Task.sleep(nanoseconds: Self.transientRetryDelay)
                    continue
                }
                break
            }
        }
        return CleanupItemResult(item: item, succeeded: false, error: lastError)
    }

    /// Permanently delete a single URL. Runs on a detached task so the
    /// caller's MainActor thread isn't blocked while `FileManager.removeItem`
    /// walks the directory tree — large dev caches can take several seconds
    /// per item, which froze the UI (beach ball) every time the agent's
    /// modal confirmed a "Delete Permanently" cleanup.
    func deleteSingle(url: URL, item: ScanResult) async -> CleanupItemResult {
        let pathToRemove = url
        var lastError = "unknown error"
        for attempt in 1 ... Self.maxRemovalAttempts {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.removeItem(at: pathToRemove)
                }.value
                return CleanupItemResult(item: item, succeeded: true)
            } catch {
                if !fileExists(pathToRemove.path) {
                    return CleanupItemResult(item: item, succeeded: true, bytesFreed: 0)
                }
                lastError = error.localizedDescription
                if attempt < Self.maxRemovalAttempts, isTransientRemovalFailure(lastError) {
                    try? await Task.sleep(nanoseconds: Self.transientRetryDelay)
                    continue
                }
                break
            }
        }
        return CleanupItemResult(item: item, succeeded: false, error: lastError)
    }

    /// Resolves to true when `url` refers to the user's Trash directory.
    /// Both `.trash` and `.delete` operations on this URL would fail
    /// (macOS refuses to remove the Trash container), so we intercept.
    private func isTrashContainer(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        let trash = trashURL.standardizedFileURL.resolvingSymlinksInPath().path
        return target == trash
    }

    private var trashURL: URL {
        homeDirectory.appendingPathComponent(".Trash", isDirectory: true)
    }

    /// Empty the Trash: enumerate its top-level contents and remove each.
    /// Reports aggregate success/failure on a single `CleanupItemResult`
    /// keyed to the original "Trash" scan item.
    @MainActor
    private func emptyTrashContainer(item: ScanResult) async -> CleanupItemResult {
        let fm = FileManager.default
        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(
                at: trashURL,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            return CleanupItemResult(
                item: item,
                succeeded: false,
                error: "Could not read Trash contents: \(error.localizedDescription)"
            )
        }

        if children.isEmpty {
            return CleanupItemResult(item: item, succeeded: true)
        }

        // Emptying a large Trash walks a deep tree per child and can take
        // several seconds; run the removal loop off the main actor so the UI
        // doesn't beach-ball, mirroring `deleteSingle`.
        var failures = await Task.detached(priority: .userInitiated) {
            var failures: [(url: URL, message: String)] = []
            for child in children {
                do {
                    try FileManager.default.removeItem(at: child)
                } catch {
                    failures.append((child, error.localizedDescription))
                }
            }
            return failures
        }.value

        failures = await escalateTrashFailures(failures)

        if failures.isEmpty {
            return CleanupItemResult(item: item, succeeded: true)
        }

        let summary: String
        if failures.count == 1 {
            summary = "\(failures[0].url.lastPathComponent): \(failures[0].message)"
        } else {
            let preview = failures.prefix(3).map { $0.url.lastPathComponent }.joined(separator: ", ")
            let more = failures.count > 3 ? " and \(failures.count - 3) more" : ""
            summary = "\(failures.count) Trash items could not be removed (\(preview)\(more))"
        }
        return CleanupItemResult(item: item, succeeded: false, error: summary)
    }

    /// Root-owned items in the user's own Trash (e.g. an installer's root agent
    /// the user can't unlink) get a bounded privileged delete. The helper only
    /// removes direct children of this user's `~/.Trash`. Returns the failures
    /// that remain after escalation.
    @MainActor
    private func escalateTrashFailures(
        _ failures: [(url: URL, message: String)]
    ) async -> [(url: URL, message: String)] {
        guard let privilegedHelper, !failures.isEmpty else { return failures }
        let elevatable = failures.filter { CleanupFailureClassifier.isElevatable($0.message) }
        guard !elevatable.isEmpty else { return failures }

        let request = PrivilegedUninstallRequest(
            planID: UUID(),
            items: elevatable.map {
                PrivilegedUninstallItem(
                    id: $0.url.path,
                    path: $0.url.path,
                    category: RemnantCategory.other.rawValue,
                    size: 0,
                    operation: .deleteFromTrash
                )
            },
            invokingUserID: getuid()
        )
        let results = await privilegedHelper.movePrivilegedItemsToTrash(
            request,
            authorization: .privilegedHelperApproved
        )
        let removedPaths = Set(results.filter(\.succeeded).map(\.item.path))
        return failures.filter { !removedPaths.contains($0.url.path) }
    }
}
