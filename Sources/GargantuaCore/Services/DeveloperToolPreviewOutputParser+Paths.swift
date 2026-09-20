import Foundation

/// Helpers that pull a filesystem path out of a developer tool's stdout —
/// `pnpm store path`, a cache-directory line, and `go env`.
///
/// Split from `DeveloperToolPreviewOutputParser.swift` to keep that type within
/// the project's type-body-length limit; the logic is unchanged.
extension DeveloperToolPreviewOutputParser {
    static func parsePnpmStorePath(
        output: String,
        commandPreview: [String]
    ) -> [DeveloperToolPreviewItem] {
        guard let path = output
            .split(separator: "\n")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty else {
            return []
        }

        return [
            DeveloperToolPreviewItem(
                id: "pnpm-store",
                tool: .pnpm,
                title: "pnpm content-addressable store",
                detail: path,
                reclaimableBytes: nil,
                commandPreview: commandPreview
            ),
        ]
    }

    /// npm (`npm config get cache`) and yarn classic (`yarn cache dir`) both
    /// emit the cache directory as a single line on stdout. The reclaimable
    /// size is filled in later by the adapter, which measures the directory.
    static func parseCacheDirectoryPath(
        output: String,
        commandPreview: [String],
        tool: DeveloperTool,
        id: String,
        title: String
    ) -> [DeveloperToolPreviewItem] {
        guard let path = output
            .split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { $0.hasPrefix("/") }),
            !path.isEmpty else {
            return []
        }

        return [
            DeveloperToolPreviewItem(
                id: id,
                tool: tool,
                title: title,
                detail: path,
                reclaimableBytes: nil,
                commandPreview: commandPreview
            ),
        ]
    }

    static func parseGoEnv(
        output: String,
        commandPreview: [String]
    ) -> [DeveloperToolPreviewItem] {
        guard let data = output.data(using: .utf8),
              let env = try? JSONDecoder().decode(GoEnvPreview.self, from: data) else {
            return []
        }

        return [
            env.GOCACHE.map {
                DeveloperToolPreviewItem(
                    id: "go-build-cache",
                    tool: .go,
                    title: "Go build cache",
                    detail: $0,
                    reclaimableBytes: nil,
                    commandPreview: commandPreview
                )
            },
            env.GOMODCACHE.map {
                DeveloperToolPreviewItem(
                    id: "go-module-cache",
                    tool: .go,
                    title: "Go module download cache",
                    detail: $0,
                    reclaimableBytes: nil,
                    commandPreview: commandPreview
                )
            },
        ]
        .compactMap { item -> DeveloperToolPreviewItem? in
            guard let item,
                  item.detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return nil
            }
            return item
        }
    }
}
