import Darwin
import Foundation
import Testing
@testable import GargantuaCore

@MainActor
private final class SelectiveTrashMover: TrashMoving {
    private let failing: Set<String>
    private let message: String
    private(set) var movedPaths: [String] = []

    init(failing: Set<String> = [], message: String = "boom") {
        self.failing = failing
        self.message = message
    }

    func moveToTrash(_ url: URL) async throws -> URL? {
        movedPaths.append(url.path)
        if failing.contains(url.lastPathComponent) {
            throw TrashMoveFailure(message: message)
        }
        return nil
    }
}

@Suite("SQLite database items")
struct CleanupEngineSQLiteTests {
    private static func makeDir() throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-items-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let resolved = Darwin.realpath(raw.path, nil).map { ptr -> String in
            defer { free(ptr) }
            return String(cString: ptr)
        }
        return URL(fileURLWithPath: resolved ?? raw.path, isDirectory: true)
    }

    @discardableResult
    private static func write(_ dir: URL, _ name: String, bytes: Int = 10) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    private static func item(_ url: URL, size: Int64 = 30) -> ScanResult {
        ScanResult(
            id: "db", name: "db", path: url.path, size: size, safety: .safe, confidence: 90,
            explanation: "t", source: SourceAttribution(name: "Test"), category: "test"
        )
    }

    private static func rule(path: String, filters: [String] = []) -> ScanRule {
        ScanRule(
            id: "db_rule", name: "DB", paths: [path], matchFilters: filters, safety: .safe,
            confidence: 90, explanation: "t", source: SourceAttribution(name: "Test"),
            regenerates: true, category: "test"
        )
    }

    private static func scan(_ rule: ScanRule, path: String) -> ScanResult? {
        var counter = 0
        return NativeScanAdapter.makeResult(
            rule: rule, path: path, counter: &counter, classifier: SafetyClassifier(),
            profile: CleanupProfile(id: "p", name: "P", description: "P", categories: ["test"])
        )
    }

    @Test("delete removes the database and its sidecars")
    @MainActor
    func deleteRemovesAll() async throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Self.write(dir, "x.sqlite")
        try Self.write(dir, "x.sqlite-wal")
        try Self.write(dir, "x.sqlite-shm")
        let engine = CleanupEngine(homeDirectoryForTesting: dir)
        let result = await engine.clean([Self.item(db)], method: .delete, authorization: .unchecked(.deepClean))
        #expect(result.allSucceeded)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test("trash moves sidecars before the database")
    @MainActor
    func trashOrder() async throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Self.write(dir, "x.sqlite")
        try Self.write(dir, "x.sqlite-wal")
        try Self.write(dir, "x.sqlite-shm")
        let mover = SelectiveTrashMover()
        let engine = CleanupEngine(homeDirectoryForTesting: dir, trashMover: mover)
        let result = await engine.clean([Self.item(db)], method: .trash, authorization: .unchecked(.deepClean))
        #expect(result.allSucceeded)
        #expect(mover.movedPaths == [db.path + "-wal", db.path + "-shm", db.path])
    }

    @Test("a sidecar failure leaves the database in place")
    @MainActor
    func sidecarFailure() async throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Self.write(dir, "x.sqlite")
        try Self.write(dir, "x.sqlite-wal")
        let mover = SelectiveTrashMover(failing: ["x.sqlite-wal"])
        let engine = CleanupEngine(homeDirectoryForTesting: dir, trashMover: mover)
        let result = await engine.clean([Self.item(db)], method: .trash, authorization: .unchecked(.deepClean))
        let outcome = try #require(result.itemResults.first)
        #expect(!outcome.succeeded)
        #expect(outcome.error?.contains("x.sqlite-wal") == true)
        #expect(outcome.error?.contains("left in place") == true)
        #expect(!mover.movedPaths.contains(db.path))
        #expect(FileManager.default.fileExists(atPath: db.path))
    }

    @Test("a non-database file's look-alike sidecar is untouched")
    @MainActor
    func nonDatabaseAlone() async throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try Self.write(dir, "x.txt")
        let wal = try Self.write(dir, "x.txt-wal")
        let engine = CleanupEngine(homeDirectoryForTesting: dir)
        let result = await engine.clean([Self.item(file)], method: .delete, authorization: .unchecked(.deepClean))
        #expect(result.allSucceeded)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: wal.path))
    }

    @Test("a rule listing a folder's children skips sidecars whose database is beside them")
    func enumeratedChildrenSkipSidecars() async throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.write(dir, "x.db", bytes: 100)
        try Self.write(dir, "x.db-wal", bytes: 20)
        try Self.write(dir, "x.db-shm", bytes: 3)
        try Self.write(dir, "stray.db-wal", bytes: 7)
        try Self.write(dir, "note.txt", bytes: 5)
        let rule = ScanRule(
            id: "db_rule", name: "DB", paths: [dir.path], pattern: "*", safety: .safe,
            confidence: 90, explanation: "t", source: SourceAttribution(name: "Test"),
            regenerates: true, category: "test"
        )
        let results = try await NativeScanAdapter(
            rules: [rule],
            profile: CleanupProfile(id: "p", name: "P", description: "P", categories: ["test"])
        ).scan()
        let sizes = Dictionary(
            uniqueKeysWithValues: results.map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0.size) }
        )
        #expect(sizes == ["x.db": 123, "stray.db-wal": 7, "note.txt": 5])
    }

    @Test("scan size sums the database and its sidecars")
    func scanSize() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Self.write(dir, "x.sqlite", bytes: 100)
        try Self.write(dir, "x.sqlite-wal", bytes: 20)
        try Self.write(dir, "x.sqlite-shm", bytes: 3)
        let result = try #require(Self.scan(Self.rule(path: db.path), path: db.path))
        #expect(result.size == 123)
    }

    @Test("age filter sees the newest of database and sidecars")
    func scanAge() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Self.write(dir, "x.sqlite")
        let wal = try Self.write(dir, "x.sqlite-wal")
        let old = Date().addingTimeInterval(-60 * 86_400)
        for url in [db, wal] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        let rule = Self.rule(path: db.path, filters: ["mtime > 30d"])
        #expect(Self.scan(rule, path: db.path) != nil)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: wal.path)
        #expect(Self.scan(rule, path: db.path) == nil)
    }

    @Test("a database whose sidecar hit a permission error is not escalated")
    @MainActor
    func permissionSidecarFailureSkipsEscalation() async throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Self.write(dir, "x.sqlite")
        try Self.write(dir, "x.sqlite-wal")
        let mover = SelectiveTrashMover(failing: ["x.sqlite-wal"], message: "Operation not permitted")
        let helper = StubPrivilegedHelper(mode: .succeedAll)
        let engine = CleanupEngine(homeDirectoryForTesting: dir, trashMover: mover, privilegedHelper: helper)
        let result = await engine.clean([Self.item(db)], method: .trash, authorization: .unchecked(.deepClean))
        #expect(helper.received.isEmpty)
        #expect(!result.allSucceeded)
        #expect(FileManager.default.fileExists(atPath: db.path))
    }

    @Test("a database without sidecars still escalates on a permission error")
    @MainActor
    func sidecarlessDatabaseEscalates() async throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Self.write(dir, "y.sqlite")
        let mover = SelectiveTrashMover(failing: ["y.sqlite"], message: "Operation not permitted")
        let helper = StubPrivilegedHelper(mode: .succeedAll)
        let engine = CleanupEngine(homeDirectoryForTesting: dir, trashMover: mover, privilegedHelper: helper)
        let result = await engine.clean([Self.item(db)], method: .trash, authorization: .unchecked(.deepClean))
        #expect(helper.received.count == 1)
        #expect(helper.received.first?.items.first?.path == db.path)
        #expect(result.allSucceeded)
    }

    @Test("An already-gone database has its leftover sidecars removed")
    @MainActor
    func goneDatabaseLosesSidecars() async throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("x.sqlite")
        let wal = try Self.write(dir, "x.sqlite-wal")
        let shm = try Self.write(dir, "x.sqlite-shm")

        let engine = CleanupEngine(
            homeDirectoryForTesting: dir,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            isAppRunning: { _ in false }
        )
        let result = await engine.clean([Self.item(db)], method: .delete, authorization: .unchecked(.deepClean))

        #expect(result.itemResults.first?.succeeded == true)
        #expect(result.itemResults.first?.bytesFreed == 0)
        #expect(!FileManager.default.fileExists(atPath: wal.path))
        #expect(!FileManager.default.fileExists(atPath: shm.path))
    }

    @Test("A stale sidecar that can't be removed is named in the error")
    @MainActor
    func staleSidecarFailureNamesFile() async throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("x.sqlite")
        try Self.write(dir, "x.sqlite-wal")
        let engine = CleanupEngine(
            homeDirectoryForTesting: dir,
            trashMover: SelectiveTrashMover(failing: ["x.sqlite-wal"]),
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            isAppRunning: { _ in false }
        )
        let result = await engine.clean([Self.item(db)], method: .trash, authorization: .unchecked(.deepClean))
        let outcome = try #require(result.itemResults.first)
        #expect(!outcome.succeeded)
        #expect(outcome.error?.contains("x.sqlite-wal") == true)
        #expect(outcome.error?.contains("already gone") == true)
    }

    @Test("A folder named like a database is removed without touching its look-alike sidecar")
    @MainActor
    func directoryNamedLikeDatabase() async throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("cache.db", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.write(folder, "inner")
        let wal = try Self.write(dir, "cache.db-wal")
        let engine = CleanupEngine(homeDirectoryForTesting: dir)
        let result = await engine.clean([Self.item(folder)], method: .delete, authorization: .unchecked(.deepClean))
        #expect(result.allSucceeded)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: wal.path))
    }

    @Test("An already-gone database keeps its sidecars while an owner runs")
    @MainActor
    func goneDatabaseKeepsSidecarsWhileOwnerRuns() async throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("x.sqlite")
        let wal = try Self.write(dir, "x.sqlite-wal")
        var item = Self.item(db)
        item.ownerProcesses = ["owner"]

        let engine = CleanupEngine(
            homeDirectoryForTesting: dir,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            isAppRunning: { $0 == "owner" }
        )
        let result = await engine.clean([item], method: .delete, authorization: .unchecked(.deepClean))

        #expect(result.itemResults.first?.succeeded == false)
        #expect(FileManager.default.fileExists(atPath: wal.path))
    }

    @Test("Stale sidecars are not removed when the parent was swapped for a symlink")
    @MainActor
    func goneDatabaseSymlinkSwapKeepsSidecars() async throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("dir", isDirectory: true)
        let elsewhere = dir.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let wal = try Self.write(elsewhere, "x.sqlite-wal")
        let item = Self.item(real.appendingPathComponent("x.sqlite")).recordingScanTimeAncestry()
        try FileManager.default.removeItem(at: real)
        try FileManager.default.createSymbolicLink(at: real, withDestinationURL: elsewhere)

        let engine = CleanupEngine(
            homeDirectoryForTesting: dir,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            isAppRunning: { _ in false }
        )
        let result = await engine.clean([item], method: .delete, authorization: .unchecked(.deepClean))

        #expect(result.itemResults.first?.succeeded == false)
        #expect(result.itemResults.first?.error?.contains("symlink") == true)
        #expect(FileManager.default.fileExists(atPath: wal.path))
    }

    @Test("Stale sidecars under a protected root are not removed")
    @MainActor
    func goneDatabaseProtectedRootKeepsSidecars() async throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("x.sqlite")
        let wal = try Self.write(dir, "x.sqlite-wal")

        let engine = CleanupEngine(
            homeDirectoryForTesting: dir,
            protectedRootPolicy: ProtectedRootPolicy(entries: [
                ProtectedRootEntry(path: db.path, reason: "protected test root"),
            ]),
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            isAppRunning: { _ in false }
        )
        let result = await engine.clean([Self.item(db)], method: .delete, authorization: .unchecked(.deepClean))

        #expect(result.itemResults.first?.succeeded == false)
        #expect(result.itemResults.first?.error?.contains("protected test root") == true)
        #expect(FileManager.default.fileExists(atPath: wal.path))
    }
}
