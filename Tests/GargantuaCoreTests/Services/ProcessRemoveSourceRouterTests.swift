import Foundation
import Testing
@testable import GargantuaCore

@Suite("ProcessRemoveSourceRouter")
struct ProcessRemoveSourceRouterTests {

    private func makeItem(
        launchSource: ProcessLaunchSource,
        launchConfidence: LaunchSourceConfidence
    ) -> ProcessItem {
        ProcessItem(
            id: "1234|0|/usr/local/bin/tool",
            pid: 1234,
            parentPID: 1,
            startTimeUnixSeconds: 0,
            command: "tool",
            uid: 501,
            owningUser: "me",
            executablePath: "/usr/local/bin/tool",
            cpuFraction: 0,
            residentBytes: 0,
            identity: nil,
            launchSource: launchSource,
            launchConfidence: launchConfidence,
            safety: .review,
            reasons: [],
            explanation: "Test"
        )
    }

    @Test("Exact-confidence launchd source routes to Background Items with the plist path")
    func exactRoutes() {
        let router = ProcessRemoveSourceRouter()
        let item = makeItem(
            launchSource: .launchd(
                domain: .userAgent,
                label: "com.acme.tool",
                plistPath: "/Users/me/Library/LaunchAgents/com.acme.tool.plist"
            ),
            launchConfidence: .exact
        )
        let routing = router.route(item)
        #expect(routing == .routeToBackgroundItems(
            plistPath: "/Users/me/Library/LaunchAgents/com.acme.tool.plist",
            label: "com.acme.tool"
        ))
    }

    @Test("Path-confidence launchd source routes to Background Items")
    func pathRoutes() {
        let router = ProcessRemoveSourceRouter()
        let item = makeItem(
            launchSource: .launchd(
                domain: .systemDaemon,
                label: "com.acme.daemon",
                plistPath: "/Library/LaunchDaemons/com.acme.daemon.plist"
            ),
            launchConfidence: .path
        )
        let routing = router.route(item)
        if case let .routeToBackgroundItems(path, label) = routing {
            #expect(path == "/Library/LaunchDaemons/com.acme.daemon.plist")
            #expect(label == "com.acme.daemon")
        } else {
            Issue.record("Expected routeToBackgroundItems, got \(routing)")
        }
    }

    @Test("Heuristic-confidence launchd source refuses — too risky to act on")
    func heuristicRefused() {
        let router = ProcessRemoveSourceRouter()
        let item = makeItem(
            launchSource: .launchd(
                domain: .userAgent,
                label: "tool",
                plistPath: "/Users/me/Library/LaunchAgents/tool.plist"
            ),
            launchConfidence: .heuristic
        )
        let routing = router.route(item)
        if case let .unsupported(refusal, _) = routing {
            #expect(refusal == .unsupportedRemoveSource)
        } else {
            Issue.record("Expected unsupported, got \(routing)")
        }
    }

    @Test("Foreground-app source refuses — no source to remove")
    func foregroundAppRefused() {
        let router = ProcessRemoveSourceRouter()
        let item = makeItem(launchSource: .foregroundApp, launchConfidence: .exact)
        let routing = router.route(item)
        if case let .unsupported(refusal, _) = routing {
            #expect(refusal == .unsupportedRemoveSource)
        } else {
            Issue.record("Expected unsupported, got \(routing)")
        }
    }

    @Test("User-session source refuses — no source to remove")
    func userSessionRefused() {
        let router = ProcessRemoveSourceRouter()
        let item = makeItem(launchSource: .userSession, launchConfidence: .exact)
        let routing = router.route(item)
        if case let .unsupported(refusal, _) = routing {
            #expect(refusal == .unsupportedRemoveSource)
        } else {
            Issue.record("Expected unsupported, got \(routing)")
        }
    }

    @Test("Child-process source refuses — parent is the source, not us")
    func childProcessRefused() {
        let router = ProcessRemoveSourceRouter()
        let item = makeItem(launchSource: .childProcess(parentPID: 99), launchConfidence: .exact)
        let routing = router.route(item)
        if case let .unsupported(refusal, _) = routing {
            #expect(refusal == .unsupportedRemoveSource)
        } else {
            Issue.record("Expected unsupported, got \(routing)")
        }
    }

    @Test("Unknown source refuses")
    func unknownRefused() {
        let router = ProcessRemoveSourceRouter()
        let item = makeItem(launchSource: .unknown, launchConfidence: .unknown)
        let routing = router.route(item)
        if case let .unsupported(refusal, _) = routing {
            #expect(refusal == .unsupportedRemoveSource)
        } else {
            Issue.record("Expected unsupported, got \(routing)")
        }
    }

    @Test("Empty plist path on a launchd source refuses with .noPlistPath (defensive)")
    func emptyPlistPathRefused() {
        let router = ProcessRemoveSourceRouter()
        let item = makeItem(
            launchSource: .launchd(domain: .userAgent, label: "com.acme.tool", plistPath: ""),
            launchConfidence: .exact
        )
        let routing = router.route(item)
        if case let .unsupported(refusal, _) = routing {
            #expect(refusal == .noPlistPath)
        } else {
            Issue.record("Expected .noPlistPath, got \(routing)")
        }
    }
}
