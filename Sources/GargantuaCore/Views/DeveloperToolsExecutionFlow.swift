import Foundation
import OSLog
import SwiftUI

private let executionLogger = Logger(subsystem: "com.gargantua.core", category: "DeveloperToolsView")

extension DeveloperToolsView {
    /// Build the initial phase from availability results, seeding installed tools
    /// with `.loading` so the UI can show spinners while previews resolve.
    static func deriveInitialPhase(availabilities: [DeveloperToolAvailability]) -> Phase {
        let installed = availabilities.filter(\.isInstalled)
        if installed.isEmpty {
            return .empty(availabilities: availabilities)
        }
        var previews: [DeveloperTool: PreviewState] = [:]
        for item in installed {
            previews[item.tool] = .loading
        }
        return .ready(availabilities: availabilities, previews: previews)
    }

    static func operations(for preview: DeveloperToolPreview) -> [DeveloperToolCleanupOperation] {
        DeveloperToolCleanupOperation.allCases.filter {
            $0.tool == preview.tool && $0.isApplicable(to: preview)
        }
    }

    static func confirmationItem(for request: ExecutionRequest) -> ScanResult {
        let operation = request.operation
        let estimatedBytes = operation.estimatedReclaimableBytes(in: request.preview)
        let explanation = estimatedBytes == nil
            ? "\(operation.confirmationExplanation) \(operation.estimateUnavailableDetail)"
            : operation.confirmationExplanation
        return ScanResult(
            id: "developer-tool-\(operation.id)",
            name: operation.label,
            path: operation.commandName,
            size: estimatedBytes ?? 0,
            safety: operation.safety,
            confidence: 80,
            explanation: explanation,
            source: SourceAttribution(name: operation.tool.displayName),
            category: "developer_tools",
            tags: ["developer_tools", operation.tool.rawValue, operation.id],
            regenerates: false
        )
    }

    static func successMessage(
        operation: DeveloperToolCleanupOperation,
        beforeBytes: Int64?,
        afterBytes: Int64?
    ) -> String {
        switch (beforeBytes, afterBytes) {
        case let (.some(before), .some(after)):
            let recovered = max(0, before - after)
            if recovered == 0 {
                return "\(operation.label) completed. Preview refreshed; no reclaimable decrease was reported."
            }
            return "\(operation.label) completed. Preview dropped by \(AlertItem.formatBytes(recovered))."
        case (.none, .none):
            return "\(operation.label) completed. Preview refreshed; exact reclaimed bytes are unavailable for this command."
        case (.none, .some(_)):
            return "\(operation.label) completed. Preview refreshed; no before-run estimate was available."
        case (.some(_), .none):
            return "\(operation.label) completed. Preview refreshed; the updated preview no longer reports an exact estimate."
        }
    }

    static func refreshFailureMessage(operation: DeveloperToolCleanupOperation, error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return "\(operation.label) completed, but the preview refresh failed: \(message)"
    }

    /// Fold a new per-tool preview result into the phase.
    static func applyPreviewResult(
        tool: DeveloperTool,
        result: Result<DeveloperToolPreview, Error>,
        to phase: Phase
    ) -> Phase {
        guard case .ready(let availabilities, var previews) = phase else {
            return phase
        }
        switch result {
        case .success(let preview):
            previews[tool] = .loaded(preview)
        case .failure(let error):
            if case DeveloperToolPreviewError.daemonNotRunning(let stoppedTool) = error {
                previews[tool] = .daemonStopped(stoppedTool)
            } else {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                previews[tool] = .failed(message)
            }
        }
        return .ready(availabilities: availabilities, previews: previews)
    }

    /// User clicked "Scan tools" from idle (or "Refresh" from results).
    /// Bumps the generation, flips to `.loading`, and spins up a fresh
    /// availability + preview pass.
    func startScan() {
        session.loadGeneration &+= 1
        let generation = session.loadGeneration
        session.phase = .loading
        Task { await load(generation: generation) }
    }

    /// Click handler for the Back button. Bumps the generation so any
    /// in-flight load can detect it's been superseded.
    func returnToIdle() {
        session.loadGeneration &+= 1
        session.phase = .idle
    }

    func load(generation: Int) async {
        let availabilities = availabilityProvider()
        if Task.isCancelled { return }
        let initial = Self.deriveInitialPhase(availabilities: availabilities)
        let stillCurrent: Bool = await MainActor.run {
            guard generation == session.loadGeneration else { return false }
            session.phase = initial
            return true
        }
        guard stillCurrent else { return }

        guard case .ready = initial else { return }
        let installed = availabilities.filter(\.isInstalled).map(\.tool)
        for tool in installed {
            if Task.isCancelled { return }
            let isCurrent: Bool = await MainActor.run { generation == session.loadGeneration }
            if !isCurrent { return }
            await loadPreview(for: tool, generation: generation)
        }
    }

    func loadPreview(for tool: DeveloperTool, generation: Int? = nil) async {
        let result: Result<DeveloperToolPreview, Error>
        do {
            let preview = try previewProvider(tool)
            result = .success(preview)
        } catch {
            executionLogger.error("Preview for \(tool.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
            result = .failure(error)
        }
        await MainActor.run {
            // If a generation was passed (in-flight scan), skip the update
            // when the user has navigated away or kicked off a new scan.
            if let generation, generation != session.loadGeneration { return }
            session.phase = Self.applyPreviewResult(tool: tool, result: result, to: session.phase)
        }
    }

    func reloadPreview(for tool: DeveloperTool) async {
        await MainActor.run {
            if case .ready(let availabilities, var previews) = session.phase {
                previews[tool] = .loading
                session.phase = .ready(availabilities: availabilities, previews: previews)
            }
        }
        await loadPreview(for: tool)
    }

    /// Start Docker Desktop and poll until the daemon answers, then refresh
    /// the Docker preview. Lifecycle activity is published on
    /// `dockerLifecycleActivity` so the panel can show a busy state instead
    /// of a stale daemon-stopped CTA.
    func startDockerDaemon() {
        guard session.dockerLifecycleActivity == nil else { return }
        session.dockerLifecycleActivity = .starting
        let control = dockerControl
        Task {
            _ = control.start()
            let succeeded = await control.pollUntilRunning()
            if succeeded {
                await reloadPreview(for: .docker)
            }
            await MainActor.run {
                session.dockerLifecycleActivity = nil
            }
        }
    }

    /// Quit Docker Desktop and poll until the daemon stops responding, then
    /// flip the panel back to `.daemonStopped`.
    func stopDockerDaemon() {
        guard session.dockerLifecycleActivity == nil else { return }
        session.dockerLifecycleActivity = .stopping
        let control = dockerControl
        Task {
            control.stop()
            _ = await control.pollUntilStopped()
            await MainActor.run {
                if case .ready(let availabilities, var previews) = session.phase {
                    previews[.docker] = .daemonStopped(.docker)
                    session.phase = .ready(availabilities: availabilities, previews: previews)
                }
                session.dockerLifecycleActivity = nil
            }
        }
    }

    /// Re-run availability + previews for every tool. Wired to the page-level
    /// Refresh button.
    func refreshAll() async {
        session.loadGeneration &+= 1
        let generation = session.loadGeneration
        session.phase = .loading
        await load(generation: generation)
    }

    func confirmExecution(_ request: ExecutionRequest) {
        session.pendingExecution = nil
        session.executingOperationID = request.operation.id
        session.executionNotices[request.operation.id] = nil

        Task {
            await execute(request)
        }
    }

    func execute(_ request: ExecutionRequest) async {
        let operation = request.operation
        let beforeBytes = operation.estimatedReclaimableBytes(in: request.preview)
        let tier = confirmationTier(for: [Self.confirmationItem(for: request)])

        do {
            _ = try executionProvider(operation, request.preview, tier)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            executionLogger.error("Execution for \(operation.id, privacy: .public) failed: \(message, privacy: .private)")
            await MainActor.run {
                session.executionNotices[operation.id] = .failure(message)
                session.executingOperationID = nil
            }
            return
        }

        do {
            let refreshed = try previewProvider(operation.tool)
            let afterBytes = operation.estimatedReclaimableBytes(in: refreshed)
            await MainActor.run {
                session.phase = Self.applyPreviewResult(tool: operation.tool, result: .success(refreshed), to: session.phase)
                session.executionNotices[operation.id] = .success(Self.successMessage(
                    operation: operation,
                    beforeBytes: beforeBytes,
                    afterBytes: afterBytes
                ))
                session.executingOperationID = nil
            }
        } catch {
            executionLogger.error("Preview refresh after \(operation.id, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
            await MainActor.run {
                session.executionNotices[operation.id] = .success(Self.refreshFailureMessage(
                    operation: operation,
                    error: error
                ))
                session.executingOperationID = nil
            }
        }
    }
}
