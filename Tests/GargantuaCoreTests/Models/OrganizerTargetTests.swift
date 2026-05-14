import Testing
import Foundation
@testable import GargantuaCore

@Suite("OrganizerTarget")
struct OrganizerTargetTests {
    @Test("Built-in cases have distinct stable IDs")
    func builtInIDsDistinct() {
        let ids = Set(OrganizerTarget.builtIns.map(\.id))
        #expect(ids == ["builtin:downloads", "builtin:desktop", "builtin:screenshots"])
    }

    @Test("Custom case ID derives from path")
    func customIDFromPath() {
        let url = URL(fileURLWithPath: "/Users/test/Projects")
        let target: OrganizerTarget = .custom(url)
        #expect(target.id == "custom:/Users/test/Projects")
    }

    @Test("Custom target's displayName is the folder's last path component")
    func customDisplayName() {
        let target: OrganizerTarget = .custom(URL(fileURLWithPath: "/Users/test/Projects/Receipts"))
        #expect(target.displayName == "Receipts")
    }

    @Test("isBuiltIn distinguishes built-in from custom")
    func isBuiltInFlag() {
        #expect(OrganizerTarget.downloads.isBuiltIn)
        #expect(OrganizerTarget.desktop.isBuiltIn)
        #expect(OrganizerTarget.screenshots.isBuiltIn)
        #expect(!OrganizerTarget.custom(URL(fileURLWithPath: "/x")).isBuiltIn)
    }

    @Test("Equatable + Hashable across both built-in and custom cases")
    func equatableAndHashable() {
        let urlA = URL(fileURLWithPath: "/x")
        let urlB = URL(fileURLWithPath: "/y")
        #expect(OrganizerTarget.downloads == OrganizerTarget.downloads)
        #expect(OrganizerTarget.custom(urlA) == OrganizerTarget.custom(urlA))
        #expect(OrganizerTarget.custom(urlA) != OrganizerTarget.custom(urlB))
        let set: Set<OrganizerTarget> = [.downloads, .downloads, .custom(urlA), .custom(urlA)]
        #expect(set.count == 2)
    }
}

@Suite("OrganizerCustomFolderStore")
struct OrganizerCustomFolderStoreTests {
    private static func makeStore() -> (OrganizerCustomFolderStore, UserDefaults) {
        let suiteName = "organizer-custom-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (OrganizerCustomFolderStore(defaults: defaults), defaults)
    }

    @Test("Empty when no value stored")
    func emptyDefault() {
        let (store, _) = Self.makeStore()
        #expect(store.load().isEmpty)
    }

    @Test("Add + load round-trip")
    func addRoundTrip() {
        let (store, _) = Self.makeStore()
        store.add(URL(fileURLWithPath: "/Users/test/Projects"))
        store.add(URL(fileURLWithPath: "/Users/test/Documents/Archive"))
        let loaded = store.load().map { $0.standardizedFileURL.path }
        #expect(loaded == ["/Users/test/Projects", "/Users/test/Documents/Archive"])
    }

    @Test("Add de-duplicates by standardized path")
    func addDeduplicates() {
        let (store, _) = Self.makeStore()
        store.add(URL(fileURLWithPath: "/Users/test/Projects"))
        store.add(URL(fileURLWithPath: "/Users/test/Projects"))
        store.add(URL(fileURLWithPath: "/Users/test/Projects/"))
        #expect(store.load().count == 1)
    }

    @Test("Remove drops only the matching path")
    func remove() {
        let (store, _) = Self.makeStore()
        let a = URL(fileURLWithPath: "/Users/test/A")
        let b = URL(fileURLWithPath: "/Users/test/B")
        store.add(a)
        store.add(b)
        store.remove(a)
        let remaining = store.load().map { $0.standardizedFileURL.path }
        #expect(remaining == ["/Users/test/B"])
    }
}
