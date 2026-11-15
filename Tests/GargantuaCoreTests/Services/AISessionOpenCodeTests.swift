import Foundation
import Testing
@testable import GargantuaCore

/// Coverage for the OpenCode 1.x leftovers: the `storage/` tree and the
/// `snapshot/<projectID>/` git directories.
@Suite("AISessionScanAdapter: OpenCode 1.x leftovers")
struct AISessionOpenCodeTests {

    private static let day = AISessionFixtureTree.day

    @Test("a 1.x storage tree idle past the window surfaces once, as the whole tree")
    func staleStorageSurfaces() async throws {
        let fixture = try OpenCodeFixture()
        try fixture.addSession(project: "ef98", id: "ses_1", age: 120 * Self.day)

        let results = try await fixture.makeAdapter().scan(progress: nil)

        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(result.path.hasSuffix("/opencode/storage"))
        #expect(result.safety == .review)
        #expect(result.name == "OpenCode 1.x conversation history")
        #expect(result.explanation.contains("120 days"))
        #expect(result.ownerProcesses == ["opencode"])
    }

    @Test("storage age is the newest file anywhere, not any folder's timestamp")
    func storageAgeIsNewestFile() async throws {
        let fixture = try OpenCodeFixture()
        try fixture.addSession(project: "ef98", id: "ses_1", age: 120 * Self.day, partAge: 2 * Self.day)

        #expect(try await fixture.makeAdapter().scan(progress: nil).isEmpty)
    }

    @Test("a storage folder without a session subfolder is not a 1.x store")
    func storageWithoutSessionIgnored() async throws {
        let fixture = try OpenCodeFixture()
        let file = fixture.storage.appendingPathComponent("message/x/msg_1.json")
        try fixture.write(file, age: 120 * Self.day)
        try fixture.ageDirectories(under: fixture.storage, age: 120 * Self.day)

        #expect(try await fixture.makeAdapter().scan(progress: nil).isEmpty)
    }

    @Test("an idle, unreferenced 1.x snapshot repository surfaces, labelled by its worktree")
    func staleSnapshotSurfaces() async throws {
        let fixture = try OpenCodeFixture()
        try fixture.addLegacySnapshot(project: "ef98", worktree: "/Users/me/Inceptyon", age: 120 * Self.day)

        let results = try await fixture.makeAdapter().scan(progress: nil)

        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(result.path.hasSuffix("/snapshot/ef98"))
        #expect(result.name == "OpenCode 1.x snapshots — Inceptyon")
        #expect(result.safety == .review)
        #expect(result.ownerProcesses == ["opencode"])
    }

    @Test("a snapshot repository with a remaining 1.x session is left alone")
    func referencedSnapshotIgnored() async throws {
        let fixture = try OpenCodeFixture()
        try fixture.addLegacySnapshot(project: "ef98", worktree: "/Users/me/Inceptyon", age: 120 * Self.day)
        try fixture.addSession(project: "ef98", id: "ses_1", age: 120 * Self.day)

        let results = try await fixture.makeAdapter().scan(progress: nil)

        #expect(!results.contains { $0.path.hasSuffix("/snapshot/ef98") })
    }

    @Test("a snapshot repository holding an OpenCode 2.0 store is left alone")
    func v2NestedSnapshotIgnored() async throws {
        let fixture = try OpenCodeFixture()
        try fixture.addLegacySnapshot(project: "ef98", worktree: "/Users/me/Inceptyon", age: 120 * Self.day)
        try fixture.addV2Store(project: "ef98", hash: "a1b2c3", age: 120 * Self.day)

        let results = try await fixture.makeAdapter().scan(progress: nil)

        #expect(!results.contains { $0.path.hasSuffix("/snapshot/ef98") })
    }

    @Test("a recently written snapshot repository is left alone")
    func recentSnapshotIgnored() async throws {
        let fixture = try OpenCodeFixture()
        try fixture.addLegacySnapshot(project: "ef98", worktree: "/Users/me/Inceptyon", age: 120 * Self.day)
        try fixture.setAge(
            fixture.snapshot.appendingPathComponent("ef98/objects/ab/cdef"),
            age: 2 * Self.day
        )

        #expect(try await fixture.makeAdapter().scan(progress: nil).isEmpty)
    }

    @Test("any OpenCode database holds every snapshot repository back", arguments: ["opencode.db", "opencode-next.db"])
    func databaseHoldsSnapshotsBack(database: String) async throws {
        let fixture = try OpenCodeFixture()
        try fixture.addLegacySnapshot(project: "ef98", worktree: "/Users/me/Inceptyon", age: 120 * Self.day)
        try fixture.write(fixture.snapshot.deletingLastPathComponent().appendingPathComponent(database), age: 120 * Self.day)

        #expect(try await fixture.makeAdapter().scan(progress: nil).isEmpty)
    }

    @Test("an unreadable session folder counts as a reference")
    func unreadableSessionsHoldSnapshotBack() async throws {
        let fixture = try OpenCodeFixture()
        try fixture.addLegacySnapshot(project: "ef98", worktree: "/Users/me/Inceptyon", age: 120 * Self.day)
        let sessions = fixture.storage.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sessions.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sessions.path) }

        let results = try await fixture.makeAdapter().scan(progress: nil)

        #expect(!results.contains { $0.path.hasSuffix("/snapshot/ef98") })
    }

    @Test(
        "a snapshot folder whose HEAD or objects is not the real thing is not a 1.x repository",
        arguments: ["HEAD as directory", "HEAD as symlink", "objects missing", "objects as symlink"]
    )
    func malformedSnapshotIgnored(defect: String) async throws {
        let fixture = try OpenCodeFixture()
        try fixture.addLegacySnapshot(project: "ef98", worktree: "/Users/me/Inceptyon", age: 120 * Self.day)
        let repo = fixture.snapshot.appendingPathComponent("ef98", isDirectory: true)
        let fm = FileManager.default
        let target = defect.hasPrefix("HEAD") ? repo.appendingPathComponent("HEAD") : repo.appendingPathComponent("objects")
        let elsewhere = fixture.root.appendingPathComponent("elsewhere", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.moveItem(at: target, to: elsewhere.appendingPathComponent(target.lastPathComponent))
        switch defect {
        case "HEAD as directory":
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
        case "HEAD as symlink", "objects as symlink":
            try fm.createSymbolicLink(at: target, withDestinationURL: elsewhere.appendingPathComponent(target.lastPathComponent))
        default:
            break
        }
        try fixture.ageDirectories(under: repo, age: 120 * Self.day)

        #expect(try await fixture.makeAdapter().scan(progress: nil).isEmpty)
    }

    @Test("default stores register OpenCode's storage and snapshot folders")
    func defaultStoresIncludeOpenCode() throws {
        let fixture = try OpenCodeFixture()
        let data = fixture.storage.deletingLastPathComponent()
        let home = data.deletingLastPathComponent()
        let xdgData = home.appendingPathComponent(".local/share", isDirectory: true)
        try FileManager.default.createDirectory(at: xdgData, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: data, to: xdgData.appendingPathComponent("opencode", isDirectory: true))

        let stores = AISessionScanAdapter.defaultStores(homeDirectory: home)
            .filter { $0.toolName == "OpenCode" }
            .map { "\($0.kind.rawValue) \($0.url.path.replacingOccurrences(of: home.path, with: "~"))" }

        #expect(stores == [
            "openCodeLegacyStorage ~/.local/share/opencode/storage",
            "openCodeLegacySnapshot ~/.local/share/opencode/snapshot",
        ])
    }

    @Test("a snapshot folder with no HEAD of its own is not a 1.x repository")
    func headlessSnapshotIgnored() async throws {
        let fixture = try OpenCodeFixture()
        try fixture.addLegacySnapshot(project: "ef98", worktree: "/Users/me/Inceptyon", age: 120 * Self.day)
        let repo = fixture.snapshot.appendingPathComponent("ef98", isDirectory: true)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("HEAD"))
        try fixture.ageDirectories(under: repo, age: 120 * Self.day)

        #expect(try await fixture.makeAdapter().scan(progress: nil).isEmpty)
    }
}

private final class OpenCodeFixture {
    let root: URL
    let storage: URL
    let snapshot: URL
    private let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("AISessionOpenCodeTests-\(UUID().uuidString)", isDirectory: true)
        storage = root.appendingPathComponent("opencode/storage", isDirectory: true)
        snapshot = root.appendingPathComponent("opencode/snapshot", isDirectory: true)
        try fm.createDirectory(at: storage, withIntermediateDirectories: true)
        try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(at: root) }

    func setAge(_ url: URL, age: TimeInterval) throws {
        try fm.setAttributes([.modificationDate: AISessionFixtureTree.now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    func write(_ url: URL, text: String? = nil, age: TimeInterval) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (text.map { Data($0.utf8) } ?? Data(repeating: 0x61, count: 128)).write(to: url)
        try setAge(url, age: age)
    }

    /// Directory mtimes are set last, deepest first: creating children bumps them.
    func ageDirectories(under base: URL, age: TimeInterval) throws {
        var directories = [base]
        if let walker = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                directories.append(url)
            }
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            try setAge(directory, age: age)
        }
    }

    func addSession(project: String, id: String, age: TimeInterval, partAge: TimeInterval? = nil) throws {
        try write(storage.appendingPathComponent("session/\(project)/\(id).json"), age: age)
        try write(storage.appendingPathComponent("message/\(id)/msg_1.json"), age: age)
        try write(storage.appendingPathComponent("part/msg_1/prt_1.json"), age: partAge ?? age)
        try write(storage.appendingPathComponent("session_diff/\(id).json"), age: age)
        try ageDirectories(under: storage, age: age)
    }

    func addLegacySnapshot(project: String, worktree: String, age: TimeInterval) throws {
        let repo = snapshot.appendingPathComponent(project, isDirectory: true)
        try write(repo.appendingPathComponent("HEAD"), text: "ref: refs/heads/main\n", age: age)
        try write(repo.appendingPathComponent("config"), text: "[core]\n\tbare = false\n\tworktree = \(worktree)\n", age: age)
        try write(repo.appendingPathComponent("objects/ab/cdef"), age: age)
        try fm.createDirectory(at: repo.appendingPathComponent("refs/heads", isDirectory: true), withIntermediateDirectories: true)
        try ageDirectories(under: repo, age: age)
    }

    func addV2Store(project: String, hash: String, age: TimeInterval) throws {
        let repo = snapshot.appendingPathComponent(project, isDirectory: true)
        try write(repo.appendingPathComponent("\(hash)/HEAD"), text: "ref: refs/heads/main\n", age: age)
        try write(repo.appendingPathComponent("\(hash)/objects/12/3456"), age: age)
        try ageDirectories(under: repo, age: age)
    }

    func makeAdapter() -> AISessionScanAdapter {
        AISessionScanAdapter(
            policy: AISessionScanPolicy(stores: [
                AISessionStore(toolName: "OpenCode", kind: .openCodeLegacyStorage, url: storage),
                AISessionStore(toolName: "OpenCode", kind: .openCodeLegacySnapshot, url: snapshot),
            ]),
            categories: ["dev_artifacts"],
            now: { AISessionFixtureTree.now }
        )
    }
}
