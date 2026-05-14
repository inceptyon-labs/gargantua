import Foundation
import SwiftUI

/// One folder the organizer can scan. Built-in cases resolve to
/// `~/Downloads`, `~/Desktop`, and the user's screenshot destination
/// (`~/Pictures/Screenshots` or `~/Desktop`). The `custom(URL)` case
/// carries a user-picked path persisted via `OrganizerCustomFolderStore`.
public enum OrganizerTarget: Identifiable, Hashable, Sendable {
    case downloads
    case desktop
    case screenshots
    case custom(URL)

    public var id: String {
        switch self {
        case .downloads: "builtin:downloads"
        case .desktop: "builtin:desktop"
        case .screenshots: "builtin:screenshots"
        case .custom(let url): "custom:\(url.standardizedFileURL.path)"
        }
    }

    public var displayName: String {
        switch self {
        case .downloads: "Downloads"
        case .desktop: "Desktop"
        case .screenshots: "Screenshots"
        case .custom(let url): url.lastPathComponent
        }
    }

    public var systemImage: String {
        switch self {
        case .downloads: "arrow.down.circle"
        case .desktop: "menubar.dock.rectangle"
        case .screenshots: "camera.viewfinder"
        case .custom: "folder"
        }
    }

    public var isBuiltIn: Bool {
        if case .custom = self { return false }
        return true
    }

    public static let builtIns: [OrganizerTarget] = [.downloads, .desktop, .screenshots]

    public func url(fileManager: FileManager = .default) -> URL {
        let home = fileManager.homeDirectoryForCurrentUser
        switch self {
        case .downloads:
            return home.appendingPathComponent("Downloads", isDirectory: true)
        case .desktop:
            return home.appendingPathComponent("Desktop", isDirectory: true)
        case .screenshots:
            let screenshots = home.appendingPathComponent("Pictures/Screenshots", isDirectory: true)
            if fileManager.fileExists(atPath: screenshots.path) { return screenshots }
            return home.appendingPathComponent("Desktop", isDirectory: true)
        case .custom(let url):
            return url
        }
    }
}

/// Lifecycle of the Organize tab's single-folder workflow. Linear flow:
/// idle → proposing → preview → applying → applied (then optional Undo).
/// Errors surface as `failed`; the user can retry by going back to idle.
public enum OrganizerPhase: Equatable, Sendable {
    case idle
    case proposing
    case preview
    case applying
    case applied(summary: OrganizerExecutionResult)
    case undoing
    case undone(summary: OrganizerUndoResult)
    case failed(message: String)

    public static func == (lhs: OrganizerPhase, rhs: OrganizerPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.proposing, .proposing), (.preview, .preview),
             (.applying, .applying), (.undoing, .undoing):
            return true
        case (.applied(let a), .applied(let b)): return a.proposalID == b.proposalID
        case (.undone(let a), .undone(let b)): return a.proposalID == b.proposalID
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

/// State the Organize tab observes. `@MainActor` because every transition
/// drives SwiftUI; proposers/executors are called from `Task { ... }`
/// blocks the state owns so callers don't have to manage cancellation.
@MainActor
public final class OrganizerSessionState: ObservableObject {
    @Published public var selectedTarget: OrganizerTarget = .downloads
    @Published public private(set) var phase: OrganizerPhase = .idle
    @Published public private(set) var proposal: OrganizationProposal?

    private let executor: OrganizerExecutor
    private let cloudService: CloudAIService?
    private let localProposer: LocalOrganizerProposer
    private let mlxProposer: MLXOrganizerProposer?
    private let claudeCodeProposer: ClaudeCodeOrganizerProposer
    private let preferenceProvider: @MainActor () -> OrganizerBackendPreference

    private var activeTask: Task<Void, Never>?

    public init(
        executor: OrganizerExecutor = OrganizerExecutor(),
        cloudService: CloudAIService? = nil,
        localProposer: LocalOrganizerProposer = LocalOrganizerProposer(),
        mlxProposer: MLXOrganizerProposer? = nil,
        claudeCodeProposer: ClaudeCodeOrganizerProposer = ClaudeCodeOrganizerProposer(),
        preferenceProvider: @escaping @MainActor () -> OrganizerBackendPreference = {
            OrganizerBackendPreference.stored()
        }
    ) {
        self.executor = executor
        self.cloudService = cloudService
        self.localProposer = localProposer
        self.mlxProposer = mlxProposer
        self.claudeCodeProposer = claudeCodeProposer
        self.preferenceProvider = preferenceProvider
    }

    // MARK: - Public actions

    public func startScan() {
        cancelActiveTask()
        phase = .proposing
        let folder = selectedTarget.url()
        let preference = preferenceProvider()
        let service = cloudService
        let local = localProposer
        let mlx = mlxProposer
        let claudeCode = claudeCodeProposer

        activeTask = Task { [weak self] in
            do {
                let result: OrganizationProposal
                switch preference {
                case .cloud:
                    guard let service else {
                        throw OrganizerSessionError.cloudUnavailable
                    }
                    let cloudResult = try await service.proposeFileOrganization(sourceFolder: folder)
                    result = cloudResult.proposal
                case .local:
                    result = try local.propose(sourceFolder: folder)
                case .mlx:
                    guard let mlx else {
                        throw OrganizerSessionError.mlxUnavailable
                    }
                    result = try await mlx.propose(sourceFolder: folder)
                case .claudeCode:
                    result = try await claudeCode.propose(sourceFolder: folder)
                }
                guard !Task.isCancelled else { return }
                self?.proposal = result
                self?.phase = .preview
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed(message: error.localizedDescription)
            }
        }
    }

    public func applyAll() {
        guard let proposal else { return }
        cancelActiveTask()
        phase = .applying
        let executor = executor

        activeTask = Task { [weak self] in
            do {
                let result = try executor.apply(proposal)
                guard !Task.isCancelled else { return }
                self?.phase = .applied(summary: result)
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed(message: error.localizedDescription)
            }
        }
    }

    public func undoLastApply() {
        guard let proposal else { return }
        cancelActiveTask()
        phase = .undoing
        let executor = executor

        activeTask = Task { [weak self] in
            do {
                let result = try executor.undo(proposalID: proposal.id)
                guard !Task.isCancelled else { return }
                self?.phase = .undone(summary: result)
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed(message: error.localizedDescription)
            }
        }
    }

    public func reset() {
        cancelActiveTask()
        proposal = nil
        phase = .idle
    }

    // MARK: - Internal

    private func cancelActiveTask() {
        activeTask?.cancel()
        activeTask = nil
    }

    // MARK: - Test seams

    /// Bypass the proposer and seat a proposal directly. The Apply / Undo
    /// paths need a real proposal to exercise without dragging in a fake
    /// transport or pointing tests at `~/Downloads`. Internal so it's
    /// only reachable via `@testable import`.
    func _testSetProposal(_ proposal: OrganizationProposal) {
        self.proposal = proposal
    }

    func _testSetPhase(_ newPhase: OrganizerPhase) {
        self.phase = newPhase
    }
}

public enum OrganizerSessionError: Error, LocalizedError, Equatable {
    case cloudUnavailable
    case mlxUnavailable

    public var errorDescription: String? {
        switch self {
        case .cloudUnavailable:
            return "Cloud AI is not configured. Switch to On-device in Settings or add an Anthropic key."
        case .mlxUnavailable:
            return "Local MLX model isn't available. Open AI Models to download it, then try again."
        }
    }
}
