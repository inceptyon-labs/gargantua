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
        return ScanResult(
            id: "developer-tool-\(operation.id)",
            name: operation.label,
            path: operation.commandName,
            size: operation.estimatedReclaimableBytes(in: request.preview) ?? request.preview.reclaimableBytes,
            safety: operation.safety,
            confidence: 80,
            explanation: operation.detail,
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
        guard let beforeBytes, let afterBytes else {
            return "\(operation.label) completed. Preview refreshed."
        }
        let recovered = max(0, beforeBytes - afterBytes)
        return "\(operation.label) completed. Preview dropped by \(AlertItem.formatBytes(recovered))."
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
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            previews[tool] = .failed(message)
        }
        return .ready(availabilities: availabilities, previews: previews)
    }

    func load() async {
        let availabilities = availabilityProvider()
        if Task.isCancelled { return }
        let initial = Self.deriveInitialPhase(availabilities: availabilities)
        await MainActor.run { phase = initial }

        guard case .ready = initial else { return }
        let installed = availabilities.filter(\.isInstalled).map(\.tool)
        for tool in installed {
            if Task.isCancelled { return }
            await loadPreview(for: tool)
        }
    }

    func loadPreview(for tool: DeveloperTool) async {
        let result: Result<DeveloperToolPreview, Error>
        do {
            let preview = try previewProvider(tool)
            result = .success(preview)
        } catch {
            executionLogger.error("Preview for \(tool.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
            result = .failure(error)
        }
        await MainActor.run {
            phase = Self.applyPreviewResult(tool: tool, result: result, to: phase)
        }
    }

    func reloadPreview(for tool: DeveloperTool) async {
        await MainActor.run {
            if case .ready(let availabilities, var previews) = phase {
                previews[tool] = .loading
                phase = .ready(availabilities: availabilities, previews: previews)
            }
        }
        await loadPreview(for: tool)
    }

    func confirmExecution(_ request: ExecutionRequest) {
        pendingExecution = nil
        executingOperationID = request.operation.id
        executionNotices[request.operation.id] = nil

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
            let refreshed = try previewProvider(operation.tool)
            let afterBytes = operation.estimatedReclaimableBytes(in: refreshed)
            await MainActor.run {
                phase = Self.applyPreviewResult(tool: operation.tool, result: .success(refreshed), to: phase)
                executionNotices[operation.id] = .success(Self.successMessage(
                    operation: operation,
                    beforeBytes: beforeBytes,
                    afterBytes: afterBytes
                ))
                executingOperationID = nil
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            executionLogger.error("Execution for \(operation.id, privacy: .public) failed: \(message, privacy: .private)")
            await MainActor.run {
                executionNotices[operation.id] = .failure(message)
                executingOperationID = nil
            }
        }
    }
}
