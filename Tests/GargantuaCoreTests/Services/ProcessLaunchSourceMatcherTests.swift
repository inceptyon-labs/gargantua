import Foundation
import Testing
@testable import GargantuaCore

@Suite("ProcessLaunchSourceMatcher")
struct ProcessLaunchSourceMatcherTests {

    private let matcher = ProcessLaunchSourceMatcher()

    // MARK: - Path matching

    @Test("Exact match: parent is launchd AND exec path matches plist Program")
    func exactMatch() {
        let plist = LaunchdPlist(label: "com.acme.helper", program: "/Applications/Acme.app/Contents/MacOS/helper")
        let item = LaunchdItem(domain: .userAgent, plistPath: "/Users/me/Library/LaunchAgents/acme.plist", plist: plist)

        let (source, confidence) = matcher.match(
            executablePath: "/Applications/Acme.app/Contents/MacOS/helper",
            command: "helper",
            parentPID: 1, // launchd
            launchdItems: [item]
        )

        #expect(confidence == .exact)
        if case let .launchd(domain, label, plistPath) = source {
            #expect(domain == .userAgent)
            #expect(label == "com.acme.helper")
            #expect(plistPath == "/Users/me/Library/LaunchAgents/acme.plist")
        } else {
            Issue.record("Expected .launchd source, got \(source)")
        }
    }

    @Test("Path match: exec path matches plist but parent is not launchd")
    func pathMatchOnly() {
        let plist = LaunchdPlist(label: "com.acme.helper", program: "/Applications/Acme.app/Contents/MacOS/helper")
        let item = LaunchdItem(domain: .userAgent, plistPath: "/Users/me/Library/LaunchAgents/acme.plist", plist: plist)

        let (_, confidence) = matcher.match(
            executablePath: "/Applications/Acme.app/Contents/MacOS/helper",
            command: "helper",
            parentPID: 4242, // some other process, not launchd
            launchdItems: [item]
        )

        #expect(confidence == .path)
    }

    @Test("Path match: programArguments[0] absolute path matches")
    func programArgumentsMatch() {
        let plist = LaunchdPlist(
            label: "com.acme.tool",
            programArguments: ["/usr/local/bin/acmetool", "--daemon"]
        )
        let item = LaunchdItem(domain: .systemDaemon, plistPath: "/Library/LaunchDaemons/acme.plist", plist: plist)

        let (source, confidence) = matcher.match(
            executablePath: "/usr/local/bin/acmetool",
            command: "acmetool",
            parentPID: 1,
            launchdItems: [item]
        )

        #expect(confidence == .exact)
        if case let .launchd(_, label, _) = source {
            #expect(label == "com.acme.tool")
        } else {
            Issue.record("Expected .launchd source")
        }
    }

    @Test("Relative programArguments[0] does not match by path")
    func relativeProgramArgumentsDoNotMatchByPath() {
        // launchd resolves bare names through `_PATH_STDPATH`; but matching a
        // running binary at /usr/bin/foo against a plist that just says "foo"
        // would create false positives across every job whose binary happens
        // to share a common name.
        let plist = LaunchdPlist(label: "com.example.bare", programArguments: ["bare-tool"])
        let item = LaunchdItem(domain: .userAgent, plistPath: "/p.plist", plist: plist)

        let (source, confidence) = matcher.match(
            executablePath: "/usr/local/bin/bare-tool",
            command: "bare-tool",
            parentPID: 1,
            launchdItems: [item]
        )

        // Heuristic falls through (label has trailing component "bare", not
        // "bare-tool") so this lands on userSession (parent=1, no plist match).
        #expect(confidence == .unknown)
        #expect(source == .userSession)
    }

    // MARK: - Heuristic matching

    @Test("Heuristic match: trailing reverse-DNS component equals command")
    func heuristicTrailingComponent() {
        let plist = LaunchdPlist(label: "com.acme.helperd")
        let item = LaunchdItem(domain: .userAgent, plistPath: "/p.plist", plist: plist)

        let (source, confidence) = matcher.match(
            executablePath: "/usr/local/bin/helperd",
            command: "helperd",
            parentPID: 1,
            launchdItems: [item]
        )

        #expect(confidence == .heuristic)
        if case let .launchd(_, label, _) = source {
            #expect(label == "com.acme.helperd")
        } else {
            Issue.record("Expected .launchd source")
        }
    }

    @Test("Heuristic match: full label equals command (case-insensitive)")
    func heuristicFullLabelEqual() {
        let plist = LaunchdPlist(label: "MyLabel")
        let item = LaunchdItem(domain: .userAgent, plistPath: "/p.plist", plist: plist)

        let (_, confidence) = matcher.match(
            executablePath: nil,
            command: "mylabel",
            parentPID: 1,
            launchdItems: [item]
        )

        #expect(confidence == .heuristic)
    }

    @Test("Path match takes precedence over heuristic match")
    func pathBeatsHeuristic() {
        // Two items: one would heuristic-match, the other path-matches. Path
        // wins regardless of declaration order.
        let pathItem = LaunchdItem(
            domain: .userAgent,
            plistPath: "/path.plist",
            plist: LaunchdPlist(label: "com.path.match", program: "/Applications/Path.app/Contents/MacOS/path")
        )
        let heuristicItem = LaunchdItem(
            domain: .userAgent,
            plistPath: "/heur.plist",
            plist: LaunchdPlist(label: "com.example.path")
        )

        let (source, confidence) = matcher.match(
            executablePath: "/Applications/Path.app/Contents/MacOS/path",
            command: "path",
            parentPID: 1,
            launchdItems: [heuristicItem, pathItem]
        )

        #expect(confidence == .exact)
        if case let .launchd(_, label, _) = source {
            #expect(label == "com.path.match")
        } else {
            Issue.record("Expected .launchd source")
        }
    }

    // MARK: - Fallback paths

    @Test("Parent=1 with no plist match → userSession / unknown confidence")
    func parentLaunchdFallback() {
        let (source, confidence) = matcher.match(
            executablePath: "/usr/local/bin/strange",
            command: "strange",
            parentPID: 1,
            launchdItems: []
        )

        #expect(source == .userSession)
        #expect(confidence == .unknown)
    }

    @Test("Parent=non-launchd with no plist match → childProcess")
    func childProcessFallback() {
        let (source, confidence) = matcher.match(
            executablePath: "/usr/local/bin/orphan",
            command: "orphan",
            parentPID: 9999,
            launchdItems: []
        )

        #expect(confidence == .unknown)
        if case let .childProcess(parentPID) = source {
            #expect(parentPID == 9999)
        } else {
            Issue.record("Expected .childProcess source, got \(source)")
        }
    }

    @Test("Parent=0 → unknown source")
    func zeroParentUnknown() {
        let (source, confidence) = matcher.match(
            executablePath: nil,
            command: "kernel_task",
            parentPID: 0,
            launchdItems: []
        )

        #expect(source == .unknown)
        #expect(confidence == .unknown)
    }

    @Test("Items without parsed plists are skipped, not matched")
    func skipsUnparseableItems() {
        let unparseable = LaunchdItem(
            domain: .userAgent,
            plistPath: "/broken.plist",
            plist: nil,
            parseError: "broken"
        )

        let (source, _) = matcher.match(
            executablePath: "/usr/local/bin/whatever",
            command: "whatever",
            parentPID: 1,
            launchdItems: [unparseable]
        )

        // Falls through to parent=1 → userSession.
        #expect(source == .userSession)
    }
}
