import Testing
@testable import GargantuaCore

@Suite("Path exclusion settings view model")
struct PathExclusionSettingsViewModelTests {
    @MainActor
    private func makeSubject() throws -> (PathExclusionSettingsViewModel, PersistenceController) {
        let persistence = try PersistenceController(inMemory: true)
        let model = PathExclusionSettingsViewModel(persistence: persistence)
        return (model, persistence)
    }

    @Test("Adding a draft pattern trims and persists through PersistenceController")
    @MainActor
    func addDraftPatternPersistsEntry() throws {
        let (model, persistence) = try makeSubject()

        model.newPattern = "  ~/Library/Caches/KeepMe  \n"
        model.addDraftPattern()

        let persisted = try persistence.fetchWhitelistEntries()
        #expect(persisted.map(\.pattern) == ["~/Library/Caches/KeepMe"])
        #expect(model.entries.map(\.pattern) == ["~/Library/Caches/KeepMe"])
        #expect(model.newPattern.isEmpty)
        #expect(model.notice == .added("~/Library/Caches/KeepMe"))
    }

    @Test("Duplicate entries are reported without creating a second row")
    @MainActor
    func duplicateEntryIsExplicit() throws {
        let (model, persistence) = try makeSubject()
        try persistence.addWhitelistEntry(pattern: "~/Library/Caches/KeepMe")

        model.load()
        model.newPattern = "~/Library/Caches/KeepMe"
        model.addDraftPattern()

        let persisted = try persistence.fetchWhitelistEntries()
        #expect(persisted.count == 1)
        #expect(model.entries.count == 1)
        #expect(model.newPattern == "~/Library/Caches/KeepMe")
        #expect(model.notice == .duplicate("~/Library/Caches/KeepMe"))
    }

    @Test("Empty drafts surface an inline notice and do not persist")
    @MainActor
    func emptyDraftIsRejected() throws {
        let (model, persistence) = try makeSubject()

        model.newPattern = " \n "
        model.addDraftPattern()

        #expect(try persistence.fetchWhitelistEntries().isEmpty)
        #expect(model.entries.isEmpty)
        #expect(model.notice == .empty)
    }

    @Test("Removing an entry uses the same persistence path")
    @MainActor
    func removeEntryPersists() throws {
        let (model, persistence) = try makeSubject()
        try persistence.addWhitelistEntry(pattern: "~/Library/Caches/KeepMe")

        model.load()
        model.removeEntry(pattern: "~/Library/Caches/KeepMe")

        #expect(try persistence.fetchWhitelistEntries().isEmpty)
        #expect(model.entries.isEmpty)
        #expect(model.notice == .removed("~/Library/Caches/KeepMe"))
    }
}
