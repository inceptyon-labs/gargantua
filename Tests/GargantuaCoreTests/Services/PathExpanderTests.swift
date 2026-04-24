import Darwin
import Foundation
import Testing
@testable import GargantuaCore

@Suite("PathExpander")
struct PathExpanderTests {

    // MARK: - Fixture helpers

    /// Creates a temporary directory tree under FileManager.temporaryDirectory.
    /// Callers must clean it up; tests do so in deinit via the holder struct.
    private static func makeFixture() throws -> FixtureTree {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathExpanderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        // macOS /var/folders is a symlink to /private/var/folders. FileManager enumeration
        // returns canonical paths, so resolve the fixture root through realpath so every
        // comparison uses the same /private-prefixed form.
        let root = URL(fileURLWithPath: Self.realpath(raw.path) ?? raw.path, isDirectory: true)
        return FixtureTree(root: root)
    }

    /// Resolve all symlinks via POSIX realpath. Returns nil if the path cannot be resolved.
    private static func realpath(_ path: String) -> String? {
        guard let cstr = Darwin.realpath(path, nil) else { return nil }
        defer { free(cstr) }
        return String(cString: cstr)
    }

    private final class FixtureTree {
        let root: URL

        init(root: URL) {
            self.root = root
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

        @discardableResult
        func makeSymlink(at relative: String, pointingTo target: URL) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            return url
        }
    }

    // MARK: - Literal paths

    @Test("Literal path returns match when it exists")
    func literalPathMatches() throws {
        let fixture = try Self.makeFixture()
        try fixture.makeDir("existing")
        let pattern = fixture.root.appendingPathComponent("existing").path

        let result = PathExpander().expand(pattern: pattern, roots: [])
        #expect(result.paths == [pattern])
        #expect(result.hitCap == false)
    }

    @Test("Literal path returns empty when missing")
    func literalPathAbsent() {
        let missing = "/tmp/definitely-does-not-exist-\(UUID().uuidString)"
        let result = PathExpander().expand(pattern: missing, roots: [])
        #expect(result.paths.isEmpty)
    }

    // MARK: - Single-segment wildcards

    @Test("Single-segment wildcard matches immediate children")
    func singleSegmentWildcard() throws {
        let fixture = try Self.makeFixture()
        try fixture.makeDir("profiles/abc/cache2")
        try fixture.makeDir("profiles/def/cache2")
        try fixture.makeDir("profiles/xyz/other")

        let pattern = fixture.root.appendingPathComponent("profiles/*/cache2").path
        let result = PathExpander().expand(pattern: pattern, roots: [])

        let expected: Set<String> = [
            fixture.root.appendingPathComponent("profiles/abc/cache2").path,
            fixture.root.appendingPathComponent("profiles/def/cache2").path,
        ]
        #expect(Set(result.paths) == expected)
    }

    @Test("Wildcard with prefix matches substring of filename")
    func wildcardPrefixMatch() throws {
        let fixture = try Self.makeFixture()
        try fixture.makeDir("homebrew-abc")
        try fixture.makeDir("homebrew-xyz")
        try fixture.makeDir("other-thing")

        let pattern = fixture.root.appendingPathComponent("homebrew-*").path
        let result = PathExpander().expand(pattern: pattern, roots: [])

        let expected: Set<String> = [
            fixture.root.appendingPathComponent("homebrew-abc").path,
            fixture.root.appendingPathComponent("homebrew-xyz").path,
        ]
        #expect(Set(result.paths) == expected)
    }

    // MARK: - Recursive **

    @Test("**/segment finds nested matches from roots")
    func recursiveFromRoots() throws {
        let fixture = try Self.makeFixture()
        try fixture.makeDir("a/node_modules")
        try fixture.makeDir("a/b/c/node_modules")
        try fixture.makeDir("d/other")

        let result = PathExpander().expand(pattern: "**/node_modules", roots: [fixture.root])

        let expected: Set<String> = [
            fixture.root.appendingPathComponent("a/node_modules").path,
            fixture.root.appendingPathComponent("a/b/c/node_modules").path,
        ]
        #expect(Set(result.paths) == expected)
    }

    @Test("prefix/**/segment walks only within the prefix")
    func recursiveWithinPrefix() throws {
        let fixture = try Self.makeFixture()
        try fixture.makeDir("projects/alpha/target")
        try fixture.makeDir("projects/beta/build/target")
        try fixture.makeDir("downloads/target")

        let pattern = fixture.root.appendingPathComponent("projects/**/target").path
        let result = PathExpander().expand(pattern: pattern, roots: [])

        let expected: Set<String> = [
            fixture.root.appendingPathComponent("projects/alpha/target").path,
            fixture.root.appendingPathComponent("projects/beta/build/target").path,
        ]
        #expect(Set(result.paths) == expected)
    }

    @Test("recursive hidden-directory patterns descend hidden ancestors only when requested")
    func recursiveHiddenDirectoryPatterns() throws {
        let fixture = try Self.makeFixture()
        try fixture.makeDir(".workspace/project/.venv")
        try fixture.makeDir(".workspace/project/node_modules")
        try fixture.makeDir("visible/.tox")

        let hiddenResult = PathExpander().expand(pattern: "**/.venv", roots: [fixture.root])
        let nonHiddenResult = PathExpander().expand(pattern: "**/node_modules", roots: [fixture.root])
        let toxResult = PathExpander().expand(pattern: "**/.tox", roots: [fixture.root])

        #expect(hiddenResult.paths == [
            fixture.root.appendingPathComponent(".workspace/project/.venv").path,
        ])
        #expect(nonHiddenResult.paths.isEmpty)
        #expect(toxResult.paths == [
            fixture.root.appendingPathComponent("visible/.tox").path,
        ])
    }

    // MARK: - Limits

    @Test("Depth cap stops descent and marks hitCap")
    func depthCap() throws {
        let fixture = try Self.makeFixture()
        // Nest node_modules 6 levels deep
        try fixture.makeDir("l1/l2/l3/l4/l5/l6/node_modules")

        let limits = PathExpander.Limits(maxDepth: 3, maxEntries: 100_000, timeBudget: 30)
        let result = PathExpander(limits: limits).expand(pattern: "**/node_modules", roots: [fixture.root])

        #expect(result.paths.isEmpty)
        #expect(result.hitCap == true)
        #expect(result.capReason == "depth")
    }

    @Test("Entry cap stops enumeration and marks hitCap")
    func entryCap() throws {
        let fixture = try Self.makeFixture()
        for i in 0..<50 {
            try fixture.makeDir("dir\(i)")
        }

        let limits = PathExpander.Limits(maxDepth: 8, maxEntries: 10, timeBudget: 30)
        let result = PathExpander(limits: limits).expand(pattern: "**/whatever", roots: [fixture.root])

        #expect(result.hitCap == true)
        #expect(result.capReason == "entries")
    }

    // MARK: - Symlinks

    @Test("Symlinked directories are skipped during recursive walk")
    func symlinksSkipped() throws {
        let fixture = try Self.makeFixture()
        try fixture.makeDir("real/node_modules")
        let target = try fixture.makeDir("elsewhere/node_modules")
        try fixture.makeSymlink(at: "linked-nm", pointingTo: target)

        let result = PathExpander().expand(pattern: "**/node_modules", roots: [fixture.root])

        // The symlink itself should NOT be reported; the real path under "real/" should.
        let paths = Set(result.paths)
        #expect(paths.contains(fixture.root.appendingPathComponent("real/node_modules").path))
        #expect(paths.contains(fixture.root.appendingPathComponent("elsewhere/node_modules").path))
        #expect(paths.contains(fixture.root.appendingPathComponent("linked-nm").path) == false)
    }

    // MARK: - fnmatch

    @Test("fnmatch handles prefix, suffix, contains, and pure *")
    func fnmatchCases() {
        #expect(PathExpander.fnmatch(pattern: "*", name: "anything") == true)
        #expect(PathExpander.fnmatch(pattern: "*", name: "") == true)

        #expect(PathExpander.fnmatch(pattern: "homebrew-*", name: "homebrew-abc") == true)
        #expect(PathExpander.fnmatch(pattern: "homebrew-*", name: "notbrew-abc") == false)

        #expect(PathExpander.fnmatch(pattern: "*.dmg", name: "installer.dmg") == true)
        #expect(PathExpander.fnmatch(pattern: "*.dmg", name: "installer.pkg") == false)

        #expect(PathExpander.fnmatch(pattern: "foo*bar", name: "foo-XYZ-bar") == true)
        #expect(PathExpander.fnmatch(pattern: "foo*bar", name: "fooXYZbaz") == false)

        #expect(PathExpander.fnmatch(pattern: "exact", name: "exact") == true)
        #expect(PathExpander.fnmatch(pattern: "exact", name: "exactly") == false)
    }
}
