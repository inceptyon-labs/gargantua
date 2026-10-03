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

    @Test("A folder takes the app locks and protected status of results inside it, not review")
    func folderInheritsFromContents() {
        let folder = result("folder", "/u/Library/Caches/BraveSoftware", .safe)
        var inner = result("inner", "/u/Library/Caches/BraveSoftware/Brave-Browser/Default/Cache", .safe)
        inner.blockedByApp = brave
        let reviewInside = result("reviewInside", "/u/Library/Caches/BraveSoftware/Models/x", .review)
        let sibling = result("sibling", "/u/Library/Caches/BraveSoftwareExtra", .safe)
        let other = result("other", "/u/Library/Caches/com.acme", .safe)
        let protectedInside = result("protectedInside", "/u/Library/Caches/com.acme/keys", .protected_)

        let reconciled = ScanResultOverlapReconciler.reconcile([folder, inner, reviewInside, sibling, other, protectedInside])
        let byID = Dictionary(uniqueKeysWithValues: reconciled.map { ($0.id, $0) })

        #expect(byID["folder"]?.blockedByApp == brave)
        #expect(byID["folder"]?.safety == .safe)
        #expect(byID["sibling"]?.blockedByApp == nil)
        #expect(byID["other"]?.safety == .protected_)
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
