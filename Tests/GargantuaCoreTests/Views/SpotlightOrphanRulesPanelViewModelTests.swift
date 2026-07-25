import GargantuaLicensing
import Testing
@testable import GargantuaCore

@MainActor
@Suite("SpotlightOrphanRulesPanelViewModel")
struct SpotlightOrphanRulesPanelViewModelTests {
    /// Reader + writer sharing one mutable array, mirroring the real store so a
    /// prune is reflected by the next read.
    private final class FakeStore: SpotlightRulesReading, SpotlightRulesWriting, @unchecked Sendable {
        var ids: [String]
        init(_ ids: [String]) { self.ids = ids }
        func enabledRuleIdentifiers() -> [String] { ids }
        func write(keptIdentifiers: [String]) throws { ids = keptIdentifiers }
    }

    private struct Resolver: InstalledAppResolving {
        let installed: Set<String>
        func isInstalled(bundleID: String) -> Bool { installed.contains(bundleID) }
    }

    private func model(
        store: FakeStore,
        installed: Set<String> = [],
        gate: @escaping @Sendable () async -> DestructiveActionAuthorization? = {
            .unchecked(.spotlightOrphanRules)
        }
    ) -> SpotlightOrphanRulesPanelViewModel {
        SpotlightOrphanRulesPanelViewModel(
            scanner: SpotlightOrphanRuleScanner(
                reader: store,
                writer: store,
                resolver: Resolver(installed: installed),
                authorizeDestructive: gate
            )
        )
    }

    @Test("load surfaces the orphans and flips hasLoaded")
    func loadPopulatesOrphans() {
        let model = model(store: FakeStore(["com.gone.app", "com.apple.tips", "com.docker.docker"]), installed: ["com.docker.docker"])

        #expect(model.hasLoaded == false)
        model.load()

        #expect(model.hasLoaded)
        #expect(model.orphans.map(\.identifier) == ["com.gone.app"])
    }

    @Test("prune removes orphans, refreshes the list, and reports the count")
    func pruneRemovesAndRefreshes() async {
        let store = FakeStore(["com.gone.app", "com.apple.tips", "com.docker.docker"])
        let model = model(store: store, installed: ["com.docker.docker"])
        model.load()
        #expect(model.orphans.map(\.identifier) == ["com.gone.app"])

        await model.prune()

        #expect(model.orphans.isEmpty)
        #expect(model.notice == .removed(1))
        #expect(store.ids == ["com.apple.tips", "com.docker.docker"])
        #expect(model.isPruning == false)
    }

    @Test("a blocked license surfaces a blocked notice and writes nothing")
    func pruneBlocked() async {
        let store = FakeStore(["com.gone.app"])
        let model = model(store: store, installed: [], gate: { nil })
        model.load()

        await model.prune()

        #expect(model.notice == .blocked)
        #expect(store.ids == ["com.gone.app"])
        #expect(model.orphans.map(\.identifier) == ["com.gone.app"])
    }

    @Test("pruning with no orphans reports already-clean")
    func pruneAlreadyClean() async {
        let store = FakeStore(["com.apple.tips", "com.docker.docker"])
        let model = model(store: store, installed: ["com.docker.docker"])
        model.load()
        #expect(model.orphans.isEmpty)

        await model.prune()

        #expect(model.notice == .alreadyClean)
        #expect(store.ids == ["com.apple.tips", "com.docker.docker"])
    }
}
