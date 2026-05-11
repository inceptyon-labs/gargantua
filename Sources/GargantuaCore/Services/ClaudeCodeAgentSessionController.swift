import Combine
import Foundation

/// Hydrated approval state surfaced when the user clicks Approve on a gate
/// that carries structured `proposedItemIDs`. Carries the gate's original
/// id (so the controller can mark the gate `.approved` once cleanup
/// finishes), the resolved scan items (subset of the requested IDs that
/// were found in the host's scan-result mirror), and the unresolved IDs
/// (so the UI can warn the user that a portion of the agent's
/// recommendation references items the host never observed — typically
/// app bundles, which `MCPCleanToolHandler` cannot handle anyway).
public struct ClaudeCodeAgentPendingApproval: Sendable {
    public let gateID: UUID
    public let items: [ScanResult]
    public let unresolvedItemIDs: [String]

    public init(gateID: UUID, items: [ScanResult], unresolvedItemIDs: [String]) {
        self.gateID = gateID
        self.items = items
        self.unresolvedItemIDs = unresolvedItemIDs
    }
}

@MainActor
public final class ClaudeCodeAgentSessionController: ObservableObject {
    @Published public private(set) var status: ClaudeCodeAgentSessionStatus = .idle
    @Published public private(set) var events: [ClaudeCodeAgentTranscriptEvent] = []
    @Published public internal(set) var streamEvents: [ClaudeCodeStreamEvent] = []
    @Published public internal(set) var terminalResult: ClaudeCodeStreamTerminalResult?
    @Published public internal(set) var approvalGates: [ClaudeCodeAgentApprovalGate] = []
    @Published public private(set) var activeSessionID: UUID?
    /// Set when the user approves a gate that has hydratable item IDs.
    /// The agent view binds a `ConfirmationModalView` to its non-nil state
    /// so the cleanup confirmation goes through the same UI Deep Clean uses.
    /// Cleared by `confirmPendingApproval(method:)` or `cancelPendingApproval()`.
    @Published public internal(set) var pendingApproval: ClaudeCodeAgentPendingApproval?
    /// True while `confirmPendingApproval` is running cleanup through the
    /// CleanupEngine pipeline. The agent view binds an overlay to this flag
    /// so the user sees an explicit "Cleaning… N of M" state instead of the
    /// modal vanishing into a beach ball while large items are removed.
    @Published public private(set) var isCleaning: Bool = false
    /// Number of items processed in the in-flight cleanup. Drives the
    /// "N of M" counter in the progress overlay.
    @Published public private(set) var cleaningProgress: Int = 0
    /// Total items scheduled for the in-flight cleanup. Set when cleanup
    /// begins, reset to 0 when it ends.
    @Published public private(set) var cleaningTotal: Int = 0
    /// The most recent assistant text the agent emitted during the run.
    /// Surfaced above the items in the review modal as the "Why these
    /// items" context — Sonnet's prose is typically a one-line rationale
    /// pinned to the user's prompt ("upgrade macOS"), and surfacing it
    /// alongside the items closes the gap where the user couldn't see why
    /// each row was selected.
    @Published public internal(set) var lastAssistantText: String = ""

    private let runner: ClaudeCodeAgentSessionRunner
    private let cleanupEngine: CleanupEngine
    private let auditWriter: AuditWriter
    /// Host-side mirror of the agent's scan-session cache. Populated from
    /// `mcp__gargantua__scan` tool_result events (parsed via the
    /// `ClaudeCodeToolResultPayload.scanResults` payload). Last-scan-wins,
    /// matching the MCP server's own cache semantics — the agent's most
    /// recent scan is what the host can hydrate against.
    let scanCache = MCPScanSessionCache()
    private var task: Task<Void, Never>?
    private var lastStartTemplate: ClaudeCodeAgentPromptTemplate?
    private var lastStartUserContext: String?
    private var lastStartWorkingDirectory: URL?

    public init(
        runner: ClaudeCodeAgentSessionRunner = ClaudeCodeAgentSessionRunner(),
        cleanupEngine: CleanupEngine = CleanupEngine(),
        auditWriter: AuditWriter = AuditWriter()
    ) {
        self.runner = runner
        self.cleanupEngine = cleanupEngine
        self.auditWriter = auditWriter
    }

    /// Root under which the runner creates per-session scratch directories.
    /// Surfaced for the trust-pass UI so users can see where the agent is
    /// allowed to write before they hit Start.
    public var sessionsRoot: URL { runner.sessionsRoot }

    deinit {
        task?.cancel()
        runner.cancel()
    }

    public func start(
        template: ClaudeCodeAgentPromptTemplate,
        userContext: String,
        workingDirectory: URL? = nil
    ) {
        guard !status.isRunning else { return }

        let prompt = ClaudeCodeAgentPromptBuilder.prompt(template: template, userContext: userContext)
        let sessionID = UUID()
        status = .running
        events = []
        streamEvents = []
        terminalResult = nil
        approvalGates = []
        activeSessionID = sessionID
        lastStartTemplate = template
        lastStartUserContext = userContext
        lastStartWorkingDirectory = workingDirectory
        // Drop any items mirrored from a previous session. Within a session
        // the cache accumulates so multi-scan runs don't lose IDs; across
        // sessions we want a clean slate so a new run can't approve cleanup
        // of items that no longer exist on disk.
        scanCache.clear()
        lastAssistantText = ""

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await runner.run(
                    prompt: prompt,
                    sessionID: sessionID,
                    workingDirectory: workingDirectory,
                    onEvent: { event in
                        Task { @MainActor [weak self] in
                            self?.events.append(event)
                        }
                    },
                    onGate: { gate in
                        Task { @MainActor [weak self] in
                            self?.upsertGate(gate)
                        }
                    },
                    onStreamEvent: { event in
                        Task { @MainActor [weak self] in
                            self?.appendStreamEvent(event)
                        }
                    }
                )
                let taskWasCancelled = Task.isCancelled
                await MainActor.run {
                    self.activeSessionID = result.sessionID
                    if self.status == .cancelled || taskWasCancelled {
                        self.status = .cancelled
                    } else {
                        self.status = result.exitCode == 0 ? .completed : .failed("Claude Code exited with status \(result.exitCode).")
                    }
                    self.approvalGates = self.merge(existing: self.approvalGates, incoming: result.approvalGates)
                    // The agent's prompt asks it to end with a dry-run
                    // `mcp__gargantua__clean` call so the host can route the
                    // proposed items into the same review modal Deep Scan
                    // uses. Sonnet doesn't always follow that instruction —
                    // sometimes it just emits a prose report and stops. This
                    // fallback closes that gap: if the run completed and the
                    // agent did scan but never proposed items, hydrate the
                    // cached scan results directly into pendingApproval so
                    // the modal pops up automatically. The user gets the
                    // actionable handoff regardless of what the agent did.
                    self.surfaceScanCacheModalIfAgentDidNotPropose()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.status = .cancelled
                }
            } catch {
                await MainActor.run {
                    self.status = .failed(error.localizedDescription)
                    self.events.append(ClaudeCodeAgentTranscriptEvent(stream: .system, message: error.localizedDescription))
                }
            }
        }
    }

    public func cancel() {
        guard status.isRunning else { return }
        if let activeSessionID {
            runner.recordAgentAudit(command: "agent_cancel", sessionID: activeSessionID)
        }
        status = .cancelled
        task?.cancel()
        runner.cancel()
    }

    /// Approve a gate. When the gate carries structured `proposedItemIDs`,
    /// the controller hydrates them against its scan mirror and exposes a
    /// `pendingApproval` state for the view to render the confirmation
    /// modal and/or the unresolved-IDs note — the gate is NOT marked
    /// `.approved` until the user confirms via
    /// `confirmPendingApproval(method:)`. When the gate has no structured
    /// IDs at all (substring-fallback case), there is nothing to hydrate
    /// or warn about, so the controller falls back to the previous
    /// status-flip-with-audit behavior.
    public func approve(_ gate: ClaudeCodeAgentApprovalGate) {
        guard !gate.proposedItemIDs.isEmpty else {
            // No structured IDs to hydrate — record the decision and move on.
            // Substring-fallback gates land here.
            decide(gate, status: .approved)
            return
        }
        let (found, unknown) = scanCache.lookupAll(ids: gate.proposedItemIDs)
        let actionable = found.filter(\.safety.isActionable)
        let blocked = found.filter { !$0.safety.isActionable }
        guard !actionable.isEmpty || !unknown.isEmpty || !blocked.isEmpty else {
            // Defensive: lookupAll partitions every requested id into one
            // bucket, so this shouldn't fire — but if both come back empty
            // we keep the prior auto-approve shape so the gate doesn't
            // wedge in pending.
            decide(gate, status: .approved)
            return
        }
        if !blocked.isEmpty {
            let ids = blocked.map(\.id).joined(separator: ", ")
            events.append(ClaudeCodeAgentTranscriptEvent(
                stream: .system,
                message: "Skipped protected agent cleanup item(s): \(ids). Safety comes from Gargantua scan rules."
            ))
        }
        pendingApproval = ClaudeCodeAgentPendingApproval(
            gateID: gate.id,
            items: actionable,
            unresolvedItemIDs: unknown
        )
    }

    public func deny(_ gate: ClaudeCodeAgentApprovalGate) {
        decide(gate, status: .denied)
    }

    /// Run cleanup against the items the user has confirmed in the modal.
    /// Uses the same `CleanupEngine` + `AuditWriter` pipeline `DeepCleanView`
    /// drives — no parallel pipeline, no agent-specific cleanup code. Marks
    /// the originating gate `.approved` once cleanup completes (success or
    /// fail) so the UI can transition out of the pending state.
    ///
    /// When `pending.items` is empty (only-unresolved case — every ID the
    /// agent proposed was outside the scan cache, typically app bundles),
    /// there is nothing to clean. We still mark the gate approved with
    /// audit so the user's acknowledgement of the Smart Uninstaller note
    /// is recorded.
    public func confirmPendingApproval(method: CleanupMethod = .trash) async {
        guard let pending = pendingApproval else { return }
        pendingApproval = nil
        let cleanupItems = pending.items.filter(\.safety.isActionable)
        if cleanupItems.count != pending.items.count {
            events.append(ClaudeCodeAgentTranscriptEvent(
                stream: .system,
                message: "Skipped protected cleanup item(s) before execution. Safety comes from Gargantua scan rules."
            ))
        }
        if !cleanupItems.isEmpty {
            // Surface progress so the user sees "Cleaning… N of M" instead
            // of the modal disappearing into a beach ball while large items
            // are deleted. The observer drives the counter; CleanupEngine
            // emits an event per item.
            isCleaning = true
            cleaningProgress = 0
            cleaningTotal = cleanupItems.count
            await Task.yield()
            let observer = AgentCleanupProgressObserver { [weak self] in
                Task { @MainActor [weak self] in
                    self?.cleaningProgress += 1
                }
            }
            let result = await cleanupEngine.clean(
                cleanupItems,
                method: method,
                observer: observer
            )
            isCleaning = false
            cleaningProgress = 0
            cleaningTotal = 0
            do {
                try auditWriter.record(result: result)
            } catch {
                // Audit write failure doesn't unwind cleanup — log and continue,
                // matching DeepCleanView's behavior in the same situation.
                events.append(ClaudeCodeAgentTranscriptEvent(
                    stream: .system,
                    message: "Audit write failed: \(error.localizedDescription)"
                ))
            }
        }
        if let index = approvalGates.firstIndex(where: { $0.id == pending.gateID }) {
            approvalGates[index].status = .approved
            approvalGates[index].decidedAt = Date()
            runner.recordAgentAudit(
                command: "agent_gate_approved",
                sessionID: approvalGates[index].sessionID
            )
        }
    }

    /// Dismiss the modal without cleaning anything. Leaves the gate in
    /// `.pending` state — the user can re-approve later if they change
    /// their mind.
    public func cancelPendingApproval() {
        pendingApproval = nil
    }

    private func decide(
        _ gate: ClaudeCodeAgentApprovalGate,
        status decision: ClaudeCodeAgentApprovalStatus
    ) {
        guard let index = approvalGates.firstIndex(where: { $0.id == gate.id }) else { return }
        approvalGates[index].status = decision
        approvalGates[index].decidedAt = Date()
        runner.recordAgentAudit(
            command: decision == .approved ? "agent_gate_approved" : "agent_gate_denied",
            sessionID: gate.sessionID
        )
    }

    private func upsertGate(_ gate: ClaudeCodeAgentApprovalGate) {
        approvalGates = merge(existing: approvalGates, incoming: [gate])
    }

    /// Re-fire the last prompt that ran (via `start`). Used by the UI to give
    /// users a one-click recovery from `error_max_turns` after they raise
    /// `maxTurns` in settings — calling `restart()` without changing settings
    /// would just hit the same wall again.
    public func restart() {
        guard !status.isRunning,
              let template = lastStartTemplate,
              let userContext = lastStartUserContext else { return }
        start(template: template, userContext: userContext, workingDirectory: lastStartWorkingDirectory)
    }

    private func merge(
        existing: [ClaudeCodeAgentApprovalGate],
        incoming: [ClaudeCodeAgentApprovalGate]
    ) -> [ClaudeCodeAgentApprovalGate] {
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for gate in incoming {
            byID[gate.id] = gate
        }
        return byID.values.sorted { $0.requestedAt < $1.requestedAt }
    }
}
