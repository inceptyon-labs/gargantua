import Darwin
import Foundation
import Testing

@testable import GargantuaCore

@Suite("AppBundleReader")
struct AppBundleReaderTests {

    // MARK: - Fixture helpers

    private static func makeTempDir() throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppBundleReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        return URL(fileURLWithPath: Self.realpath(raw.path) ?? raw.path, isDirectory: true)
    }

    private static func realpath(_ path: String) -> String? {
        guard let cstr = Darwin.realpath(path, nil) else { return nil }
        defer { free(cstr) }
        return String(cString: cstr)
    }

    /// Build a minimal `.app` bundle on disk with the given Info.plist fields and a
    /// placeholder executable.
    @discardableResult
    private static func makeAppBundle(
        in dir: URL,
        name: String,
        info: [String: Any],
        executableBytes: Int = 2048
    ) throws -> URL {
        let bundleURL = dir.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        let plistURL = contents.appendingPathComponent("Info.plist")
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plistData.write(to: plistURL)

        let executableName = (info["CFBundleExecutable"] as? String) ?? name
        let execURL = macOS.appendingPathComponent(executableName)
        try Data(repeating: 0xAB, count: executableBytes).write(to: execURL)

        return bundleURL
    }

    // MARK: - Happy path

    @Test("readMetadata extracts all Info.plist fields when present")
    func readsAllFields() throws {
        let tmp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bundleURL = try Self.makeAppBundle(
            in: tmp,
            name: "SampleApp",
            info: [
                "CFBundleIdentifier": "com.example.sample",
                "CFBundleName": "Sample",
                "CFBundleDisplayName": "Sample (Beta)",
                "CFBundleShortVersionString": "2.3.1",
                "CFBundleVersion": "42",
                "CFBundleExecutable": "Sample",
            ]
        )

        let reader = DefaultAppBundleReader()
        let meta = try #require(reader.readMetadata(bundleURL: bundleURL))

        #expect(meta.bundleID == "com.example.sample")
        #expect(meta.name == "Sample")
        #expect(meta.displayName == "Sample (Beta)")
        #expect(meta.shortVersion == "2.3.1")
        #expect(meta.bundleVersion == "42")
        #expect(meta.bundlePath == bundleURL.path)
        #expect(meta.executablePath?.hasSuffix("Contents/MacOS/Sample") == true)
        #expect(meta.installDate != nil)
        #expect(meta.lastUsedDate != nil)
    }

    // MARK: - Missing bundleID

    @Test("readMetadata returns nil when CFBundleIdentifier is missing")
    func missingBundleIDIsNil() throws {
        let tmp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bundleURL = try Self.makeAppBundle(
            in: tmp,
            name: "NoID",
            info: [
                "CFBundleName": "NoID"
                // CFBundleIdentifier intentionally missing
            ]
        )

        let reader = DefaultAppBundleReader()
        #expect(reader.readMetadata(bundleURL: bundleURL) == nil)
    }

    @Test("readMetadata returns nil when CFBundleIdentifier is empty")
    func emptyBundleIDIsNil() throws {
        let tmp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bundleURL = try Self.makeAppBundle(
            in: tmp,
            name: "EmptyID",
            info: [
                "CFBundleIdentifier": "",
                "CFBundleName": "EmptyID",
            ]
        )

        let reader = DefaultAppBundleReader()
        #expect(reader.readMetadata(bundleURL: bundleURL) == nil)
    }

    // MARK: - Fallbacks

    @Test("readMetadata falls back to filename when CFBundleName is absent")
    func fallbackToFilename() throws {
        let tmp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bundleURL = try Self.makeAppBundle(
            in: tmp,
            name: "FallbackName",
            info: [
                "CFBundleIdentifier": "com.example.fallback"
                // CFBundleName missing
            ]
        )

        let reader = DefaultAppBundleReader()
        let meta = try #require(reader.readMetadata(bundleURL: bundleURL))
        #expect(meta.name == "FallbackName")
    }

    @Test("displayName is nil when it matches CFBundleName")
    func displayNameDedupedFromName() throws {
        let tmp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bundleURL = try Self.makeAppBundle(
            in: tmp,
            name: "Same",
            info: [
                "CFBundleIdentifier": "com.example.same",
                "CFBundleName": "Same",
                "CFBundleDisplayName": "Same",
            ]
        )

        let reader = DefaultAppBundleReader()
        let meta = try #require(reader.readMetadata(bundleURL: bundleURL))
        #expect(meta.displayName == nil)
    }

    // MARK: - Size measurement

    @Test("sizeOnDisk returns non-zero value for a populated bundle")
    func sizeOnDiskMeasuresBundle() throws {
        let tmp = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bundleURL = try Self.makeAppBundle(
            in: tmp,
            name: "SizeTest",
            info: [
                "CFBundleIdentifier": "com.example.size",
                "CFBundleName": "SizeTest",
                "CFBundleExecutable": "SizeTest",
            ],
            executableBytes: 10_000
        )

        let reader = DefaultAppBundleReader()
        let size = try #require(reader.sizeOnDisk(bundleURL: bundleURL))
        // File-system block allocation rounds up, so assert a lower bound only.
        #expect(size >= 10_000)
    }
}
