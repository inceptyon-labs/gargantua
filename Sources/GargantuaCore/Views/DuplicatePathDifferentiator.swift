import Foundation

// MARK: - Path Differentiator

/// For a group of paths, returns each path's "differentiating" segment — the
/// component-level slice that varies between siblings. Lets the UI show
/// "01fba-2025-12-10_15-43-02 Masks" instead of an identical UUID filename.
public enum DuplicatePathDifferentiator {
    /// Map of path → differentiator string. If two paths share everything but
    /// the filename, the differentiator is the filename. If they differ in a
    /// folder mid-path but share the filename, the differentiator is the
    /// folder name(s). For a single-path group the differentiator is the
    /// filename (so the UI never shows an empty primary label).
    public static func compute(paths: [String]) -> [String: String] {
        guard paths.count > 1 else {
            return paths.reduce(into: [:]) { acc, path in
                acc[path] = (path as NSString).lastPathComponent
            }
        }

        let split = paths.map(pathComponents)
        let prefixLen = longestCommonPrefixLength(of: split)
        let suffixLen = longestCommonSuffixLength(of: split, skippingFirst: prefixLen)

        var result: [String: String] = [:]
        for (idx, components) in split.enumerated() {
            let upper = max(prefixLen, components.count - suffixLen)
            let slice = components[prefixLen ..< upper]
            // Empty differentiator (path is exactly the common prefix) shouldn't
            // happen for a real duplicate group, but fall back to the filename.
            let label = slice.isEmpty
                ? components.last ?? paths[idx]
                : slice.joined(separator: "/")
            result[paths[idx]] = label
        }
        return result
    }
}

/// Common suffix length, ignoring the segment already counted as the prefix
/// (so paths like `[A,B]` and `[A,B,B]` don't double-count `B`).
private func longestCommonSuffixLength(of arrays: [[String]], skippingFirst prefixLen: Int) -> Int {
    guard let first = arrays.first else { return 0 }
    let firstAvailable = first.count - prefixLen
    var len = firstAvailable
    for other in arrays.dropFirst() {
        let availableHere = other.count - prefixLen
        len = min(len, availableHere)
        var i = 0
        while i < len, first[first.count - 1 - i] == other[other.count - 1 - i] { i += 1 }
        len = i
        if len == 0 { return 0 }
    }
    return len
}
