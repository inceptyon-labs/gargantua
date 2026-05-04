import Foundation
import Testing
@testable import GargantuaCore

@Suite("PersistenceController personal-scope roots")
struct PersistedPersonalScopeRootsTests {

    @MainActor
    private func makeController() throws -> PersistenceController {
        try PersistenceController(inMemory: true)
    }

    @Test("Fetch is empty on a fresh container")
    @MainActor
    func fetchEmptyByDefault() throws {
        let ctrl = try makeController()
        #expect(try ctrl.fetchPersonalScopeRoots().isEmpty)
    }

    @Test("Adding a root persists the entry and returns the inserted model")
    @MainActor
    func addPersistsEntry() throws {
        let ctrl = try makeController()

        let inserted = try ctrl.addPersonalScopeRoot(path: "~/Documents")
        #expect(inserted != nil)
        #expect(inserted?.pattern == "~/Documents")

        let entries = try ctrl.fetchPersonalScopeRoots()
        #expect(entries.map(\.pattern) == ["~/Documents"])
    }

    @Test("Adding a duplicate path is a no-op and returns nil")
    @MainActor
    func addDuplicateIsNoOp() throws {
        let ctrl = try makeController()
        try ctrl.addPersonalScopeRoot(path: "~/Documents")

        let second = try ctrl.addPersonalScopeRoot(path: "~/Documents")
        #expect(second == nil)
        #expect(try ctrl.fetchPersonalScopeRoots().count == 1)
    }

    @Test("Removing a root deletes it from the store")
    @MainActor
    func removeDeletesEntry() throws {
        let ctrl = try makeController()
        try ctrl.addPersonalScopeRoot(path: "~/Documents")
        try ctrl.addPersonalScopeRoot(path: "~/Downloads")

        try ctrl.removePersonalScopeRoot(path: "~/Documents")

        let remaining = try ctrl.fetchPersonalScopeRoots().map(\.pattern)
        #expect(remaining == ["~/Downloads"])
    }

    @Test("Removing an unknown path is a silent no-op")
    @MainActor
    func removeUnknownIsNoOp() throws {
        let ctrl = try makeController()
        try ctrl.addPersonalScopeRoot(path: "~/Documents")

        // Should not throw.
        try ctrl.removePersonalScopeRoot(path: "~/Nonexistent")

        #expect(try ctrl.fetchPersonalScopeRoots().count == 1)
    }

    @Test("Fetch is sorted newest-first by createdAt")
    @MainActor
    func fetchSortedNewestFirst() throws {
        let ctrl = try makeController()

        // SwiftData preserves insertion order in createdAt because each
        // call to addPersonalScopeRoot stamps Date() at insert time.
        try ctrl.addPersonalScopeRoot(path: "~/First")
        try ctrl.addPersonalScopeRoot(path: "~/Second")
        try ctrl.addPersonalScopeRoot(path: "~/Third")

        let order = try ctrl.fetchPersonalScopeRoots().map(\.pattern)
        #expect(order == ["~/Third", "~/Second", "~/First"])
    }

    @Test("Seed populates the six built-in defaults when the table is empty")
    @MainActor
    func seedFromEmpty() throws {
        let ctrl = try makeController()
        try ctrl.seedDefaultPersonalScopeRootsIfEmpty()

        let patterns = try ctrl.fetchPersonalScopeRoots().map(\.pattern)
        #expect(Set(patterns) == Set(PersistenceController.defaultPersonalScopeRootPatterns))
        #expect(patterns.count == PersistenceController.defaultPersonalScopeRootPatterns.count)
    }

    @Test("Seed is a no-op when any entries already exist")
    @MainActor
    func seedNoOpWhenPopulated() throws {
        let ctrl = try makeController()
        try ctrl.addPersonalScopeRoot(path: "~/CustomOnly")

        try ctrl.seedDefaultPersonalScopeRootsIfEmpty()

        // The user removed every default and is left with their one custom
        // entry. Seeding must not silently re-insert the defaults.
        let patterns = try ctrl.fetchPersonalScopeRoots().map(\.pattern)
        #expect(patterns == ["~/CustomOnly"])
    }

    @Test("Seed is idempotent across repeated calls")
    @MainActor
    func seedIdempotent() throws {
        let ctrl = try makeController()
        try ctrl.seedDefaultPersonalScopeRootsIfEmpty()
        try ctrl.seedDefaultPersonalScopeRootsIfEmpty()
        try ctrl.seedDefaultPersonalScopeRootsIfEmpty()

        let count = try ctrl.fetchPersonalScopeRoots().count
        #expect(count == PersistenceController.defaultPersonalScopeRootPatterns.count)
    }
}
