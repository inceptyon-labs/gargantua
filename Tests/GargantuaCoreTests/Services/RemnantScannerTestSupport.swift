import Darwin
import Foundation
@testable import GargantuaCore

/// On-disk scratch tree used by RemnantScanner test peers. Each instance
/// creates a unique `RemnantScannerTests-<UUID>` directory under the
/// system temp dir and cleans it up on deinit. The root path is resolved
/// through `realpath` so symlink-prefixed temp dirs (macOS uses
/// /var → /private/var) match what the scanner sees.
final class FixtureTree {
    let root: URL

    init() throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemnantScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let resolved = Self.realpath(raw.path) ?? raw.path
        root = URL(fileURLWithPath: resolved, isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func makeDir(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func makeFile(_ relative: String, contents: String = "x") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func realpath(_ path: String) -> String? {
        guard let cstr = Darwin.realpath(path, nil) else { return nil }
        defer { free(cstr) }
        return String(cString: cstr)
    }
}

/// Canonical Chrome AppInfo used by tests that don't care about
/// the specific app under test. Pass `bundlePath:` to override.
func chromeApp(bundlePath: String = "/Applications/Google Chrome.app") -> AppInfo {
    AppInfo(
        bundleID: "com.google.Chrome",
        name: "Google Chrome",
        bundlePath: bundlePath,
        lastUsedDate: Date(timeIntervalSince1970: 1_700_000_000),
        teamIdentifier: "EQHXZ8M8AV"
    )
}
