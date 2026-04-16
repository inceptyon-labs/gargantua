import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "MoAnalyzeAdapter")

/// Adapter for the `mo analyze` command (Disk Explorer).
///
/// Executes `mo analyze --json` via `MoleRunner` and maps the output to a
/// `[DirectoryItem]` tree suitable for the Disk Explorer view.
///
/// Usage:
/// ```swift
/// let adapter = MoAnalyzeAdapter(runner: MoleRunner())
/// let tree = try await adapter.analyze(path: "/Users/dev")
/// ```
public struct MoAnalyzeAdapter: Sendable {
    private let runner: MoleRunner

    public init(runner: MoleRunner) {
        self.runner = runner
    }

    /// Analyze disk usage at the given path and return a directory tree.
    ///
    /// - Parameters:
    ///   - path: Root path to analyze. Defaults to the user's home directory.
    ///   - depth: Maximum directory depth to traverse. Defaults to 3.
    /// - Returns: Array of top-level directory items with nested children.
    public func analyze(
        path: String = NSHomeDirectory(),
        depth: Int = 3
    ) async throws -> [DirectoryItem] {
        let arguments = ["--json", "--depth", String(depth), path]

        logger.info("Starting mo analyze (path: \(path, privacy: .public), depth: \(depth))")

        let runResult: MoleRunResult
        do {
            runResult = try await runner.run(command: "analyze", arguments: arguments)
        } catch {
            logger.error("mo analyze failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        let items: [DirectoryItem]
        do {
            items = try parseAnalyzeOutput(runResult.stdout)
        } catch {
            logger.error("Failed to parse mo analyze output: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        logger.info("mo analyze returned \(items.count) top-level items in \(String(format: "%.2f", runResult.duration))s")
        return items
    }

    // MARK: - Parsing

    /// Parse `mo analyze --json` output into DirectoryItem trees.
    private func parseAnalyzeOutput(_ data: Data) throws -> [DirectoryItem] {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MoleParseError.invalidJSON(detail: error.localizedDescription)
        }

        guard let json = parsed as? [String: Any] else {
            throw MoleParseError.invalidJSON(detail: "mo analyze output is not a JSON object")
        }

        guard let entries = json["entries"] as? [[String: Any]] else {
            throw MoleParseError.invalidJSON(detail: "mo analyze output missing 'entries' array")
        }

        return entries.compactMap { convertEntry($0) }
    }

    /// Recursively convert a JSON entry to a DirectoryItem.
    private func convertEntry(_ entry: [String: Any]) -> DirectoryItem? {
        guard let path = entry["path"] as? String else {
            logger.warning("Skipping analyze entry: missing 'path'")
            return nil
        }

        let name = (entry["name"] as? String) ?? URL(fileURLWithPath: path).lastPathComponent
        let size = (entry["size"] as? NSNumber).map { Int64($0.int64Value) } ?? 0
        let permissionDenied = (entry["permission_denied"] as? Bool) ?? false

        var children: [DirectoryItem]?
        if let childEntries = entry["children"] as? [[String: Any]] {
            children = childEntries.compactMap { convertEntry($0) }
        }

        return DirectoryItem(
            name: name,
            path: path,
            size: size,
            isPermissionDenied: permissionDenied,
            children: children
        )
    }
}
