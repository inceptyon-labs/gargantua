import Foundation

/// Supported developer tool cleanup surfaces.
public enum DeveloperTool: String, Codable, Sendable, CaseIterable, Identifiable {
    case homebrew
    case docker
    case xcode
    case pnpm
    case go
    case cargo

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .homebrew: "Homebrew"
        case .docker: "Docker"
        case .xcode: "Xcode Simulator"
        case .pnpm: "pnpm"
        case .go: "Go"
        case .cargo: "Cargo"
        }
    }
}

/// Runtime install/availability state for an external developer tool.
public struct DeveloperToolAvailability: Equatable, Sendable {
    public let tool: DeveloperTool
    public let isInstalled: Bool
    public let executable: URL?
    public let version: String?
    public let error: String?

    public init(
        tool: DeveloperTool,
        isInstalled: Bool,
        executable: URL?,
        version: String? = nil,
        error: String? = nil
    ) {
        self.tool = tool
        self.isInstalled = isInstalled
        self.executable = executable
        self.version = version
        self.error = error
    }
}

/// A read-only preview row returned by a developer tool.
public struct DeveloperToolPreviewItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let tool: DeveloperTool
    public let title: String
    public let detail: String?
    public let reclaimableBytes: Int64?
    public let commandPreview: [String]

    public init(
        id: String,
        tool: DeveloperTool,
        title: String,
        detail: String? = nil,
        reclaimableBytes: Int64? = nil,
        commandPreview: [String]
    ) {
        self.id = id
        self.tool = tool
        self.title = title
        self.detail = detail
        self.reclaimableBytes = reclaimableBytes
        self.commandPreview = commandPreview
    }
}

/// Read-only preview for a developer tool cleanup/introspection command.
public struct DeveloperToolPreview: Equatable, Sendable {
    public let tool: DeveloperTool
    public let commandPreview: [String]
    public let items: [DeveloperToolPreviewItem]
    public let rawOutput: String
    public let error: String?

    public init(
        tool: DeveloperTool,
        commandPreview: [String],
        items: [DeveloperToolPreviewItem],
        rawOutput: String,
        error: String? = nil
    ) {
        self.tool = tool
        self.commandPreview = commandPreview
        self.items = items
        self.rawOutput = rawOutput
        self.error = error
    }

    /// Sum of per-item reclaimable bytes. Saturates at `Int64.max` on
    /// overflow rather than trapping; the number is only ever surfaced as
    /// a display string, so a capped "a lot" is preferable to a crash.
    public var reclaimableBytes: Int64 {
        items.compactMap(\.reclaimableBytes).reduce(Int64(0)) { acc, next in
            let (sum, overflow) = acc.addingReportingOverflow(next)
            return overflow ? .max : sum
        }
    }

    public var hasKnownReclaimableBytes: Bool {
        items.contains { $0.reclaimableBytes != nil }
    }
}

public enum DeveloperToolPreviewError: Error, Equatable, LocalizedError {
    case notInstalled(DeveloperTool)
    case commandFailed(tool: DeveloperTool, exitCode: Int32, stderr: String)
    /// Tool is installed but its background daemon isn't running. Currently
    /// only Docker emits this — the CLI is on disk but the engine is down.
    case daemonNotRunning(DeveloperTool)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let tool):
            "\(tool.displayName) is not installed."
        case .commandFailed(let tool, let exitCode, let stderr):
            "\(tool.displayName) preview failed with exit \(exitCode): \(stderr)"
        case .daemonNotRunning(let tool):
            "\(tool.displayName) daemon is not running."
        }
    }

    /// Stderr-pattern check used by the preview adapter to distinguish
    /// "daemon down" (recoverable: just start the engine) from a true command
    /// failure (e.g. permission denied). Pattern is the canonical Docker CLI
    /// error and has been stable across versions.
    public static func isDockerDaemonNotRunning(stderr: String) -> Bool {
        let needles = [
            "Cannot connect to the Docker daemon",
            "Is the docker daemon running",
        ]
        return needles.contains { stderr.contains($0) }
    }
}

extension DeveloperToolPreviewItem {
    func withReclaimableBytes(_ bytes: Int64) -> DeveloperToolPreviewItem {
        DeveloperToolPreviewItem(
            id: id,
            tool: tool,
            title: title,
            detail: detail,
            reclaimableBytes: bytes,
            commandPreview: commandPreview
        )
    }
}
