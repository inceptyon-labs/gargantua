import Foundation
import Testing
@testable import GargantuaCore

@Suite("DuplicateGroupClassifier")
struct DuplicateGroupClassifierTests {
    @Test("Adobe Premiere mask autosaves are detected")
    func premiereMasks() {
        let paths = [
            "/Users/jason/Documents/Adobe/Premiere Pro (Beta)/26.0/Adobe Premiere Pro Auto-Save/01fba-2025-12-10_15-43-02 Masks/41c78784.prmf",
            "/Users/jason/Documents/Adobe/Premiere Pro (Beta)/26.0/Adobe Premiere Pro Auto-Save/01fba-2025-12-10_20-35-04 Masks/41c78784.prmf",
        ]
        let result = DuplicateGroupClassifier.classify(paths: paths)
        #expect(result.title == "Adobe Premiere Pro · Mask autosaves")
        #expect(result.category == .appAutosave)
        #expect(result.icon == "clock.arrow.circlepath")
        #expect(result.explainer.contains("autosave"))
    }

    @Test("~/Library/Caches/<bundleID> is classified as app cache")
    func libraryCache() {
        let paths = [
            "/Users/jason/Library/Caches/com.google.Chrome/Default/Cache/data_001",
            "/Users/jason/Library/Caches/com.google.Chrome/Default/Cache/data_002",
        ]
        let result = DuplicateGroupClassifier.classify(paths: paths)
        #expect(result.title == "Google Chrome · Cache")
        #expect(result.category == .appCache)
    }

    @Test("Unknown bundle IDs fall back to humanized last segment")
    func unknownBundleID() {
        let paths = [
            "/Users/jason/Library/Caches/com.example.SomeApp/data1.bin",
            "/Users/jason/Library/Caches/com.example.SomeApp/data2.bin",
        ]
        let result = DuplicateGroupClassifier.classify(paths: paths)
        #expect(result.title == "SomeApp · Cache")
    }

    @Test("node_modules surfaces the package name")
    func nodeModules() {
        let paths = [
            "/Users/jason/Code/projectA/node_modules/lodash/lodash.js",
            "/Users/jason/Code/projectB/node_modules/lodash/lodash.js",
        ]
        let result = DuplicateGroupClassifier.classify(paths: paths)
        #expect(result.title == "node_modules · lodash")
        #expect(result.category == .devArtifact)
    }

    @Test("node_modules with scoped package keeps the @scope prefix")
    func nodeModulesScoped() {
        let paths = [
            "/Users/jason/Code/a/node_modules/@types/node/index.d.ts",
            "/Users/jason/Code/b/node_modules/@types/node/index.d.ts",
        ]
        let result = DuplicateGroupClassifier.classify(paths: paths)
        #expect(result.title == "node_modules · @types/node")
    }

    @Test("Xcode DerivedData is recognized as a dev artifact")
    func xcodeDerivedData() {
        let paths = [
            "/Users/jason/Library/Developer/Xcode/DerivedData/MyApp-abc/Build/Products/Debug/Module.swiftmodule",
            "/Users/jason/Library/Developer/Xcode/DerivedData/MyApp-xyz/Build/Products/Debug/Module.swiftmodule",
        ]
        let result = DuplicateGroupClassifier.classify(paths: paths)
        #expect(result.title == "Xcode · Derived Data")
        #expect(result.category == .devArtifact)
    }

    @Test("Downloads is classified separately from media")
    func downloads() {
        let paths = [
            "/Users/jason/Downloads/installer.dmg",
            "/Users/jason/Downloads/old/installer.dmg",
        ]
        let result = DuplicateGroupClassifier.classify(paths: paths)
        #expect(result.category == .download)
    }

    @Test("Movies bucket gets media classification with film icon")
    func moviesBucket() {
        let paths = [
            "/Users/jason/Movies/Trip/clip.mp4",
            "/Users/jason/Movies/Trip-backup/clip.mp4",
        ]
        let result = DuplicateGroupClassifier.classify(paths: paths)
        #expect(result.category == .media)
        #expect(result.icon == "film")
    }

    @Test("Path crumb collapses /Users/<name> to ~")
    func tildeCollapsing() {
        let paths = [
            "/Users/jason/Documents/Foo/a.txt",
            "/Users/jason/Documents/Foo/b.txt",
        ]
        let result = DuplicateGroupClassifier.classify(paths: paths)
        #expect(result.pathCrumb.hasPrefix("~/"))
        #expect(!result.pathCrumb.contains("/Users/jason"))
    }

    @Test("Empty input returns a safe fallback rather than crashing")
    func emptyInput() {
        let result = DuplicateGroupClassifier.classify(paths: [])
        #expect(result.category == .generic)
        #expect(!result.title.isEmpty)
    }
}

@Suite("DuplicatePathDifferentiator")
struct DuplicatePathDifferentiatorTests {
    @Test("Differentiator surfaces the timestamped folder when filenames are identical")
    func timestampedFolders() {
        let paths = [
            "/Users/j/Adobe/Auto-Save/2025-12-10_15-43-02 Masks/uuid.prmf",
            "/Users/j/Adobe/Auto-Save/2025-12-10_20-35-04 Masks/uuid.prmf",
            "/Users/j/Adobe/Auto-Save/2025-12-11_08-38-31 Masks/uuid.prmf",
        ]
        let result = DuplicatePathDifferentiator.compute(paths: paths)
        #expect(result[paths[0]] == "2025-12-10_15-43-02 Masks")
        #expect(result[paths[1]] == "2025-12-10_20-35-04 Masks")
        #expect(result[paths[2]] == "2025-12-11_08-38-31 Masks")
    }

    @Test("Differentiator falls back to filename when only filenames differ")
    func filenamesOnly() {
        let paths = [
            "/a/b/c/file_v1.txt",
            "/a/b/c/file_v2.txt",
        ]
        let result = DuplicatePathDifferentiator.compute(paths: paths)
        #expect(result[paths[0]] == "file_v1.txt")
        #expect(result[paths[1]] == "file_v2.txt")
    }

    @Test("Single-path group falls back to the filename (never empty)")
    func singlePath() {
        let paths = ["/a/b/c.txt"]
        let result = DuplicatePathDifferentiator.compute(paths: paths)
        #expect(result[paths[0]] == "c.txt")
    }

    @Test("Paths with different depths still differentiate cleanly")
    func differentDepths() {
        let paths = [
            "/a/b/file.txt",
            "/a/b/extra/file.txt",
        ]
        let result = DuplicatePathDifferentiator.compute(paths: paths)
        // Path with extra segment should call out the differing folder.
        #expect(result[paths[1]] == "extra")
        // Shallower path's differentiator should still be non-empty (we fall
        // back to the filename so the row is never blank).
        #expect(result[paths[0]] == "file.txt")
    }
}
