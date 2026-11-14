import Foundation

/// How many lookups or bundle reads the App Updater runs at once.
let appReleaseFanOutLimit = 8

/// Maps `items` with at most `limit` transforms in flight, keeping input order.
func boundedMap<Item: Sendable, Output: Sendable>(
    _ items: [Item],
    limit: Int = appReleaseFanOutLimit,
    _ transform: @escaping @Sendable (Item) async -> Output
) async -> [Output] {
    var results = [Output?](repeating: nil, count: items.count)
    await withTaskGroup(of: (Int, Output).self) { group in
        var next = 0
        func enqueue() {
            guard next < items.count else { return }
            let index = next
            let item = items[index]
            next += 1
            group.addTask { (index, await transform(item)) }
        }
        for _ in 0 ..< max(1, limit) { enqueue() }
        while let (index, output) = await group.next() {
            results[index] = output
            enqueue()
        }
    }
    return results.compactMap { $0 }
}

extension OperatingSystemVersion {
    /// `10.13` → `[10, 13, 0]`; nil for anything that isn't 1–3 numeric parts.
    static func components(_ text: String) -> [Int]? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        return numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    private var components: [Int] { [majorVersion, minorVersion, patchVersion] }

    /// Whether this OS is `minimum` or later; nil when `minimum` can't be parsed.
    func meets(minimum: String) -> Bool? {
        Self.components(minimum).map { !components.lexicographicallyPrecedes($0) }
    }

    /// Whether this OS is `maximum` or earlier; nil when `maximum` can't be parsed.
    func meets(maximum: String) -> Bool? {
        Self.components(maximum).map { !$0.lexicographicallyPrecedes(components) }
    }
}

extension URL {
    var isHTTPS: Bool { scheme?.lowercased() == "https" }

    /// `self` when it is an https URL, else nil.
    var httpsOnly: URL? { isHTTPS ? self : nil }
}

extension String {
    /// Trimmed of whitespace and newlines, or nil when nothing is left.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
