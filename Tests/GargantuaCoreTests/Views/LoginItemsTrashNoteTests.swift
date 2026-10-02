import Foundation
import Testing
@testable import GargantuaCore

@Suite("LoginItemsTrashNote")
struct LoginItemsTrashNoteTests {
    private func result(name: String, bundleTrashed: Bool = true, succeeded: Bool = true) -> UninstallExecutionResult {
        let app = makeApp(bundleID: "com.example.\(name)", name: name)
        let bundle = RemnantItem(
            id: "app-bundle-\(app.bundleID)",
            appBundleID: app.bundleID,
            category: .other,
            path: app.bundlePath,
            size: 1,
            safety: .review,
            confidence: 95,
            explanation: "Application bundle selected for uninstall.",
            source: SourceAttribution(name: app.name, bundleID: app.bundleID),
            ruleID: "app_bundle",
            tags: ["app_bundle"]
        )
        let plan = makePlan(
            app: app,
            bundle: bundleTrashed ? bundle : nil,
            remnants: [makeRemnant(id: "\(name)-cache", app: app)]
        )
        return makeExecutionResult(plan: plan, succeeded: succeeded)
    }

    @Test("names the app when its bundle went to the Trash")
    func singleApp() throws {
        let message = try #require(LoginItemsTrashNote.message(for: [result(name: "Bartender")]))
        #expect(message.hasPrefix("If Bartender was in Login Items"))
    }

    @Test("uses plural copy for several trashed apps")
    func batch() throws {
        let message = try #require(LoginItemsTrashNote.message(for: [result(name: "A"), result(name: "B")]))
        #expect(message.hasPrefix("If any of these apps"))
    }

    @Test("no note when only remnants were removed, the bundle failed, or it was a dry run")
    func noBundleNoNote() {
        #expect(LoginItemsTrashNote.message(for: [result(name: "A", bundleTrashed: false)]) == nil)
        #expect(LoginItemsTrashNote.message(for: [result(name: "A", succeeded: false)]) == nil)
        let real = result(name: "A")
        let dryRun = UninstallExecutionResult(
            cleanupResult: real.cleanupResult,
            dryRun: true,
            privilegedItems: [],
            auditWritten: false
        )
        #expect(LoginItemsTrashNote.message(for: [dryRun]) == nil)
    }
}
