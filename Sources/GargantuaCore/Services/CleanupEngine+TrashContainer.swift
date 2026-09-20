import AppKit
import Foundation

/// Emptying the Trash container itself.
///
/// macOS refuses to remove `~/.Trash`, so both `.trash` and `.delete` on that
/// URL fail. `cleanSingle` intercepts it and empties the contents instead.
/// Split from `CleanupEngine.swift` to keep that file within the project's
/// file- and type-body-length limits; the logic is unchanged.
extension CleanupEngine {
    /// Resolves to true when `url` refers to the user's Trash directory.
    /// Both `.trash` and `.delete` operations on this URL would fail
    /// (macOS refuses to remove the Trash container), so we intercept.
    func isTrashContainer(_ url: URL) -> Bool {
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
    func emptyTrashContainer(item: ScanResult) async -> CleanupItemResult {
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
    func escalateTrashFailures(
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
