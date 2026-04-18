import Foundation
import Testing
@testable import GargantuaCore

// MARK: - Spaghettify.text

@Suite("Spaghettify.text")
struct SpaghettifyTextTests {
    @Test("Progress 0 returns the original string")
    func noProgressIsIdentity() {
        #expect(Spaghettify.text("/Users/demo/Library/Caches/example", progress: 0) == "/Users/demo/Library/Caches/example")
    }

    @Test("Progress below the first third leaves the string alone")
    func belowFirstThirdIsIdentity() {
        let base = "/some/path/to/artifact.log"
        #expect(Spaghettify.text(base, progress: 0.2) == base)
    }

    @Test("Progress past two-thirds strips up to 10 trailing characters")
    func aboveTwoThirdsStripsMaximum() {
        let base = "aaaaaaaaaaaaaaaaaaaaXXXXXXXXXX" // 20 a's + 10 X's
        let result = Spaghettify.text(base, progress: 0.8)
        #expect(result.hasPrefix("aaaaaaaaaaaaaaaaaaaa"))
        #expect(result.count == base.count)
        #expect(!result.contains("X"))
    }

    @Test("Progress 1 replaces exactly 10 trailing chars when the string is longer")
    func fullProgressReplacesTenTailChars() {
        let base = String(repeating: "a", count: 25)
        let result = Spaghettify.text(base, progress: 1)
        let kept = result.prefix(15)
        let tail = result.suffix(10)
        #expect(kept == "aaaaaaaaaaaaaaa")
        #expect(!tail.contains("a"))
    }

    @Test("Tail length grows monotonically through the middle third")
    func tailGrowsMonotonically() {
        let base = String(repeating: "x", count: 40)
        // Sample every 4% from just above 0.33 through 0.66 — the range where
        // the tail is actively growing. `kept` (count of leading x's) must
        // never increase as progress advances.
        var lastKept = base.count
        for sample in stride(from: 0.34, through: 0.66, by: 0.04) {
            let result = Spaghettify.text(base, progress: sample)
            let kept = result.prefix(while: { $0 == "x" }).count
            #expect(kept <= lastKept, "kept grew at progress \(sample): \(kept) > \(lastKept)")
            lastKept = kept
        }
        // By the end of the middle third, the tail is at the 10-char cap.
        #expect(lastKept == base.count - Spaghettify.maxTailStrip)
    }

    @Test("Short strings have their entire length stripped when progress is high")
    func shortStringFullyStripped() {
        let base = "abc"
        let result = Spaghettify.text(base, progress: 1)
        #expect(result.count == 3)
        #expect(!result.contains("a"))
    }

    @Test("Empty input is returned unchanged at any progress")
    func emptyInputUnchanged() {
        #expect(Spaghettify.text("", progress: 0) == "")
        #expect(Spaghettify.text("", progress: 0.5) == "")
        #expect(Spaghettify.text("", progress: 1) == "")
    }
}

// MARK: - SingularityCloseMessage

@Suite("SingularityCloseMessage")
struct SingularityCloseMessageTests {
    private func makeResult(succeeded: [Int64], failed: [Int64]) -> CleanupResult {
        func scan(_ size: Int64, _ id: String) -> ScanResult {
            ScanResult(
                id: id,
                name: id,
                path: "/tmp/\(id)",
                size: size,
                safety: .safe,
                confidence: 90,
                explanation: "",
                source: SourceAttribution(name: "Test"),
                category: "test"
            )
        }
        let successItems = succeeded.enumerated().map { idx, size in
            CleanupItemResult(item: scan(size, "s\(idx)"), succeeded: true)
        }
        let failedItems = failed.enumerated().map { idx, size in
            CleanupItemResult(item: scan(size, "f\(idx)"), succeeded: false, error: "boom")
        }
        return CleanupResult(itemResults: successItems + failedItems, cleanupMethod: .trash)
    }

    @Test("All-success cleanups produce the mass-recovered message")
    func successMessage() {
        let result = makeResult(succeeded: [1_000_000, 2_000_000], failed: [])
        let line = SingularityCloseMessage.line(for: result)
        #expect(line.hasPrefix("2 artifacts lost to Gargantua. Mass recovered: "))
        #expect(line.hasSuffix("."))
    }

    @Test("Partial-success cleanups mention tidal resistance")
    func partialMessage() {
        let result = makeResult(succeeded: [1_000_000], failed: [500_000, 500_000])
        let line = SingularityCloseMessage.line(for: result)
        #expect(line == "1 artifacts lost to Gargantua. 2 resisted tidal forces.")
    }

    @Test("All-failure cleanups produce the signal-lost message")
    func totalFailureMessage() {
        let result = makeResult(succeeded: [], failed: [1_000_000])
        #expect(SingularityCloseMessage.line(for: result) == "Signal lost. All artifacts still bound.")
    }

    @Test("Empty cleanups are treated as total failure rather than success")
    func emptyIsTotalFailure() {
        let result = makeResult(succeeded: [], failed: [])
        #expect(SingularityCloseMessage.line(for: result) == "Signal lost. All artifacts still bound.")
    }

    @Test("Outcome mapping is stable across inputs")
    func outcomeBucketing() {
        let success = makeResult(succeeded: [100], failed: [])
        let partial = makeResult(succeeded: [100], failed: [100])
        let fail = makeResult(succeeded: [], failed: [100])
        #expect(SingularityCloseMessage.Outcome.from(result: success) == .success)
        #expect(SingularityCloseMessage.Outcome.from(result: partial) == .partial)
        #expect(SingularityCloseMessage.Outcome.from(result: fail) == .totalFailure)
    }

    @Test("Heading matches outcome bucket and never contradicts the close line")
    func headingMatchesOutcome() {
        let success = makeResult(succeeded: [1_000_000], failed: [])
        let partial = makeResult(succeeded: [100], failed: [100])
        let fail = makeResult(succeeded: [], failed: [100])
        #expect(SingularityCloseMessage.heading(for: success) == "SIGNAL RECOVERED")
        #expect(SingularityCloseMessage.heading(for: partial) == "PARTIAL TRANSFER")
        #expect(SingularityCloseMessage.heading(for: fail) == "SIGNAL LOST")
        // The bug this guards against: "SIGNAL RECOVERED" + "Signal lost."
        // shown together when every item failed.
        #expect(SingularityCloseMessage.heading(for: fail) != "SIGNAL RECOVERED")
        #expect(SingularityCloseMessage.line(for: fail).contains("Signal lost"))
    }

    @Test("Outcome exposes a semantic accent role keyed to the bucket")
    func outcomeAccentMapping() {
        // The summary banner color and the card's top-border both key off
        // this mapping — getting it wrong shows amber on a total failure.
        #expect(SingularityCloseMessage.Outcome.success.accent == .safe)
        #expect(SingularityCloseMessage.Outcome.partial.accent == .accretion)
        #expect(SingularityCloseMessage.Outcome.totalFailure.accent == .protected)
    }
}
