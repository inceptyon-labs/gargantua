import Foundation
import Testing
@testable import GargantuaCore

/// Coverage for `AISessionStoreKind.agentTaskStore` — Roo Code's per-task
/// directories, judged by inactivity.
@Suite("AISessionScanAdapter: agent task stores")
struct AISessionTaskStoreTests {

    @Test("task untouched past the window surfaces as review")
    func staleTaskSurfaces() async throws {
        let fixture = try AISessionFixtureTree()
        try fixture.addTask(id: "task-1", contentAge: 120 * AISessionFixtureTree.day)

        let results = try await fixture.makeAdapter().scan(progress: nil)

        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(result.safety == .review)
        #expect(result.name == "Roo Code task — task-1")
        #expect(result.explanation.contains("120 days"))
        #expect(result.path.hasSuffix("/tasks/task-1"))
    }

    @Test("task written to recently is left alone")
    func activeTaskIgnored() async throws {
        let fixture = try AISessionFixtureTree()
        try fixture.addTask(id: "task-1", contentAge: 10 * AISessionFixtureTree.day)

        #expect(try await fixture.makeAdapter().scan(progress: nil).isEmpty)
    }

    @Test("the default window is 90 days: a task idle 89 days stays, one just past 90 surfaces")
    func defaultWindowIsNinetyDays() async throws {
        let fixture = try AISessionFixtureTree()
        // Just past rather than exactly at 90 days: the mtime round-trips
        // through the file system, so an exact boundary would be flaky.
        try fixture.addTask(id: "task-89", contentAge: 89 * AISessionFixtureTree.day)
        try fixture.addTask(id: "task-90", contentAge: 90 * AISessionFixtureTree.day + 60 * 60)

        let results = try await fixture.makeAdapter().scan(progress: nil)

        #expect(results.map(\.name) == ["Roo Code task — task-90"])
    }

    @Test("task age is the newest file anywhere inside, not the folder's own timestamp")
    func taskAgeIsDeepest() async throws {
        let fixture = try AISessionFixtureTree()
        try fixture.addTask(
            id: "task-1",
            contentAge: 120 * AISessionFixtureTree.day,
            nestedContentAge: 2 * AISessionFixtureTree.day,
            folderAge: 120 * AISessionFixtureTree.day
        )

        #expect(try await fixture.makeAdapter().scan(progress: nil).isEmpty)
    }

    @Test("Roo's underscore-prefixed bookkeeping is never surfaced")
    func underscoreEntriesIgnored() async throws {
        let fixture = try AISessionFixtureTree()
        try fixture.addTask(id: "_scratch", contentAge: 120 * AISessionFixtureTree.day)
        let index = fixture.taskStoreRoot.appendingPathComponent("_index.json")
        try Data(repeating: 0x1, count: 128).write(to: index)
        try fixture.age(index, by: 120 * AISessionFixtureTree.day)

        #expect(try await fixture.makeAdapter().scan(progress: nil).isEmpty)
    }

    @Test("an excluded task is not surfaced")
    func excludedTaskIgnored() async throws {
        let fixture = try AISessionFixtureTree()
        try fixture.addTask(id: "task-1", contentAge: 120 * AISessionFixtureTree.day)
        let path = fixture.taskStoreRoot.appendingPathComponent("task-1").path

        #expect(try await fixture.makeAdapter(excludedPaths: [path]).scan(progress: nil).isEmpty)
    }
}
