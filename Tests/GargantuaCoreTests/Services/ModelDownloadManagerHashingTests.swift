import Foundation
import Testing
@testable import GargantuaCore

private func writeTempFile(bytes: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gargantua-shatest-\(UUID().uuidString).bin")
    try bytes.write(to: url)
    return url
}

private func makeEmptyDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gargantua-dirtest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("ModelDownloadManager hashing and directory completeness")
@MainActor
struct ModelDownloadManagerHashingTests {

    // MARK: - SHA-256 helper

    @Test("sha256Hex matches known vectors")
    func sha256HexKnownVectors() throws {
        // Empty string
        let emptyURL = try writeTempFile(bytes: Data())
        defer { try? FileManager.default.removeItem(at: emptyURL) }
        #expect(
            try ModelDownloadManager.sha256Hex(of: emptyURL) ==
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )

        // "abc"
        let abcURL = try writeTempFile(bytes: Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: abcURL) }
        #expect(
            try ModelDownloadManager.sha256Hex(of: abcURL) ==
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test("sha256Hex streams chunks larger than 1 MB")
    func sha256HexLargeFile() throws {
        // 2.5 MB of 0x41 bytes — must agree with openssl/shasum output.
        let chunk = Data(repeating: 0x41, count: 1024 * 1024)
        var buffer = Data()
        buffer.append(chunk)
        buffer.append(chunk)
        buffer.append(Data(repeating: 0x41, count: 512 * 1024))

        let url = try writeTempFile(bytes: buffer)
        defer { try? FileManager.default.removeItem(at: url) }

        let hex = try ModelDownloadManager.sha256Hex(of: url)
        #expect(hex.count == 64)
        // Sanity: hashing the same bytes twice gives the same digest.
        let hex2 = try ModelDownloadManager.sha256Hex(of: url)
        #expect(hex == hex2)
    }

    // MARK: - Directory completeness

    @Test("isModelDirectoryComplete returns false when files are missing")
    func directoryCompleteMissingFiles() throws {
        let dir = try makeEmptyDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let files = [
            ModelFile(name: "a.json", url: URL(string: "https://x/a")!, sha256: "00", size: 3),
            ModelFile(name: "b.bin", url: URL(string: "https://x/b")!, sha256: "11", size: 5),
        ]
        #expect(!ModelDownloadManager.isModelDirectoryComplete(dir, files: files))

        // One file present, one missing
        try Data("abc".utf8).write(to: dir.appendingPathComponent("a.json"))
        #expect(!ModelDownloadManager.isModelDirectoryComplete(dir, files: files))
    }

    @Test("isModelDirectoryComplete returns true when all files match sizes")
    func directoryCompleteAllPresent() throws {
        let dir = try makeEmptyDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let files = [
            ModelFile(name: "a.json", url: URL(string: "https://x/a")!, sha256: "00", size: 3),
            ModelFile(name: "b.bin", url: URL(string: "https://x/b")!, sha256: "11", size: 5),
        ]
        try Data("abc".utf8).write(to: dir.appendingPathComponent("a.json"))
        try Data("hello".utf8).write(to: dir.appendingPathComponent("b.bin"))

        #expect(ModelDownloadManager.isModelDirectoryComplete(dir, files: files))
    }

    @Test("isModelDirectoryComplete returns false when a file size mismatches")
    func directoryCompleteSizeMismatch() throws {
        let dir = try makeEmptyDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let files = [
            ModelFile(name: "a.json", url: URL(string: "https://x/a")!, sha256: "00", size: 10),
        ]
        try Data("abc".utf8).write(to: dir.appendingPathComponent("a.json")) // 3 bytes, not 10
        #expect(!ModelDownloadManager.isModelDirectoryComplete(dir, files: files))
    }

    @Test("isModelDirectoryComplete rejects a subdirectory masquerading as a file")
    func directoryCompleteRejectsSubdir() throws {
        let dir = try makeEmptyDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let files = [
            ModelFile(name: "a.json", url: URL(string: "https://x/a")!, sha256: "00", size: 0),
        ]
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("a.json"),
            withIntermediateDirectories: false
        )
        #expect(!ModelDownloadManager.isModelDirectoryComplete(dir, files: files))
    }
}
