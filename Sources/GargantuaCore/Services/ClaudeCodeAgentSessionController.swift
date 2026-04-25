import Combine
import Foundation

@MainActor
public final class ClaudeCodeAgentSessionController: ObservableObject {
    @Published public private(set) var status: ClaudeCodeAgentSessionStatus = .idle
    @Published public private(set) var events: [ClaudeCodeAgentTranscriptEvent] = []
    @Published public private(set) var approvalGates: [ClaudeCodeAgentApprovalGate] = []
    @Published public private(set) var activeSessionID: UUID?

    private let runner: ClaudeCodeAgentSessionRunner
    private var task: Task<Void, Never>?

    public init(runner: ClaudeCodeAgentSessionRunner = ClaudeCodeAgentSessionRunner()) {
        self.runner = runner
    }

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
        approvalGates = []
        activeSessionID = sessionID

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

    public func approve(_ gate: ClaudeCodeAgentApprovalGate) {
        decide(gate, status: .approved)
    }

    public func deny(_ gate: ClaudeCodeAgentApprovalGate) {
        decide(gate, status: .denied)
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
