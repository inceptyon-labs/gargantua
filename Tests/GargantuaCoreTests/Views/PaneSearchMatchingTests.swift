import Foundation
import Testing
@testable import GargantuaCore

@Suite("Pane search matching")
struct PaneSearchMatchingTests {
    @Test("Background items match on label, paths and identity, ignoring case")
    func backgroundItemMatching() {
        let item = BackgroundItem(
            id: "userAgent|com.acme.tool",
            label: "com.acme.tool",
            source: .userLaunchAgent,
            plistPath: "/Users/me/Library/LaunchAgents/com.acme.tool.plist",
            executablePath: "/usr/local/bin/acme-helper",
            identity: nil,
            safety: .review,
            reasons: [],
            explanation: "Test item",
            isOrphaned: false
        )

        #expect(item.matches(searchQuery: "ACME.TOOL"))
        #expect(item.matches(searchQuery: "LaunchAgents"))
        #expect(item.matches(searchQuery: "acme-helper"))
        #expect(item.matches(searchQuery: "  "))
        #expect(!item.matches(searchQuery: "dropbox"))
    }

    @Test("Rules match on id, name, category and paths")
    func ruleMatching() {
        let rule = ScanRuleTests.sampleRule

        #expect(rule.matches(searchQuery: "chrome_cache"))
        #expect(rule.matches(searchQuery: "browser cache"))
        #expect(rule.matches(searchQuery: "browser_cache"))
        #expect(rule.matches(searchQuery: "Caches/Google"))
        #expect(!rule.matches(searchQuery: "firefox"))
    }
}
