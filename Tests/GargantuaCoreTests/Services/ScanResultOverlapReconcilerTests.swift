import Foundation
import Testing
@testable import GargantuaCore

@Suite("ScanResultOverlapReconciler")
struct ScanResultOverlapReconcilerTests {
    private let brave = BlockedApp(bundleID: "com.brave.Browser", name: "Brave")

    @Test("A duplicate path keeps the stricter rule's result and any app lock")
    func duplicateKeepsStricterAndLock() {
        let broad = result("broad", "/u/Library/Caches/com.acme", .safe)
        let specific = result("specific", "/u/Library/Caches/com.acme", .review)
        var locked = result("locked", "/u/Library/Caches/com.acme", .safe)
        locked.blockedByApp = brave

        let reconciled = ScanResultOverlapReconciler.reconcile([broad, specific, locked])

        #expect(reconciled.count == 1)
        #expect(reconciled[0].id == "specific")
        #expect(reconciled[0].safety == .review)
        #expect(reconciled[0].blockedByApp == brave)
    }

    @Test("A folder takes the strictest safety and lock of results inside it")
    func folderInheritsFromContents() {
        let folder = result("folder", "/u/Library/Caches/BraveSoftware", .safe)
        var inner = result("inner", "/u/Library/Caches/BraveSoftware/Brave-Browser/Default/Cache", .safe)
        inner.blockedByApp = brave
        let deeper = result("deeper", "/u/Library/Caches/BraveSoftware/Models/x", .review)
        let sibling = result("sibling", "/u/Library/Caches/BraveSoftwareExtra", .safe)

        let reconciled = ScanResultOverlapReconciler.reconcile([folder, inner, deeper, sibling])
        let byID = Dictionary(uniqueKeysWithValues: reconciled.map { ($0.id, $0) })

        #expect(byID["folder"]?.safety == .review)
        #expect(byID["folder"]?.blockedByApp == brave)
        #expect(byID["sibling"]?.safety == .safe)
        #expect(byID["sibling"]?.blockedByApp == nil)
    }

    private func result(_ id: String, _ path: String, _ safety: SafetyLevel) -> ScanResult {
        ScanResult(
            id: id,
            name: id,
            path: path,
            size: 1,
            safety: safety,
            confidence: 90,
            explanation: "x",
            source: SourceAttribution(name: "test"),
            category: "app_cache"
        )
    }
}
