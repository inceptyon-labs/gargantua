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

    @Test("A duplicate path merges owner lists, order-preserving without duplicates")
    func duplicateMergesOwners() {
        var first = result("first", "/u/Library/Caches/com.acme", .safe)
        first.ownerProcesses = ["a"]
        var second = result("second", "/u/Library/Caches/com.acme", .safe)
        second.ownerProcesses = ["b", "a"]

        let reconciled = ScanResultOverlapReconciler.reconcile([first, second])

        #expect(reconciled.count == 1)
        #expect(reconciled[0].ownerProcesses == ["a", "b"])
    }

    @Test("A folder takes the owners of results inside it")
    func folderInheritsOwners() {
        let folder = result("folder", "/u/Library/Caches/Acme", .safe)
        var inner = result("inner", "/u/Library/Caches/Acme/Data", .safe)
        inner.ownerProcesses = ["codex"]

        let byID = Dictionary(uniqueKeysWithValues: ScanResultOverlapReconciler.reconcile([folder, inner]).map { ($0.id, $0) })

        #expect(byID["folder"]?.ownerProcesses == ["codex"])
    }

    @Test("Totals count a result inside another result's folder once")
    func distinctBytesSkipsNestedResults() {
        let chrome = result("chrome", "/u/Library/Caches/Google/Chrome", .review, size: 100)
        let profile = result("profile", "/u/Library/Caches/Google/Chrome/Default/Cache", .review, size: 40)
        let sibling = result("sibling", "/u/Library/Caches/Google/ChromeHelper", .safe, size: 7)

        #expect(ScanResultOverlapReconciler.distinctBytes([chrome, profile, sibling]) == 107)
        // Without its folder in the set, the nested result counts.
        #expect(ScanResultOverlapReconciler.distinctBytes([profile, sibling]) == 47)
        // A containment map built over the full scan still applies to a subset.
        let containers = ScanResultOverlapReconciler.containers(in: [chrome, profile, sibling])
        #expect(ScanResultOverlapReconciler.distinctBytes([profile], containers: containers) == 40)
    }

    private func result(_ id: String, _ path: String, _ safety: SafetyLevel, size: Int64 = 1) -> ScanResult {
        ScanResult(
            id: id,
            name: id,
            path: path,
            size: size,
            safety: safety,
            confidence: 90,
            explanation: "x",
            source: SourceAttribution(name: "test"),
            category: "app_cache"
        )
    }
}
