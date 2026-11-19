import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP list_app_updates tool handler")
struct MCPListAppUpdatesToolHandlerTests {
    private static func app(_ id: String, version: String = "1.0") -> InstalledApp {
        InstalledApp(
            bundleID: id,
            name: id.uppercased(),
            url: URL(fileURLWithPath: "/Applications/\(id).app"),
            shortVersion: version
        )
    }

    private static func candidate(
        _ version: String = "2.0",
        source: AppReleaseSourceKind = .sparkle,
        download: Bool = true
    ) -> AppReleaseCandidate {
        AppReleaseCandidate(
            source: source,
            version: AppReleaseVersion(short: version, build: nil),
            downloadURL: download ? URL(string: "https://example.com/a.zip") : nil
        )
    }

    private static func row(_ id: String, _ status: AppReleaseStatus) -> AppReleaseRow {
        AppReleaseRow(app: app(id), status: status)
    }

    private static let sample: [AppReleaseRow] = [
        row("a", .available(candidate(), .inPlace)),
        row("b", .upToDate(latest: candidate("1.0"))),
        row("c", .available(candidate(source: .homebrewCask), .brewUpgrade(token: "c-cask"))),
        row("d", .ignored),
    ]

    private static func run(
        _ rows: [AppReleaseRow],
        _ arguments: [String: MCPJSONAny] = [:]
    ) throws -> (MCPToolCallResult, MCPListAppUpdatesOutput?) {
        let handler = MCPListAppUpdatesToolHandler(rowsProvider: { rows })
        let result = try handler.handle(MCPToolArguments(arguments))
        guard let payload = result.structuredContent else { return (result, nil) }
        let data = try JSONEncoder().encode(payload)
        return (result, try JSONDecoder().decode(MCPListAppUpdatesOutput.self, from: data))
    }

    @Test("default returns only rows with an update, with real counts")
    func availableOnlyByDefault() throws {
        let (result, output) = try Self.run(Self.sample)
        let out = try #require(output)
        #expect(out.items.map(\.bundleID) == ["a", "c"])
        #expect(out.totalItems == 2)
        #expect(out.availableCount == 2)
        guard case .text(let summary) = result.content.first else {
            Issue.record("no text")
            return
        }
        #expect(summary == "2 app updates available (of 4 apps checked).")
    }

    @Test("an app that updates itself is reported as such and not counted as available")
    func selfUpdatingRow() throws {
        let rows = Self.sample + [Self.row("e", .available(Self.candidate(), .updatesItself(AppReleaseSelfUpdater(productID: "x"))))]
        let (_, output) = try Self.run(rows, ["include_all": .bool(true)])
        let out = try #require(output)
        #expect(out.availableCount == 2)
        #expect(out.items.first { $0.bundleID == "e" }?.status == "updates_itself")
    }

    @Test("include_all returns every row")
    func includeAll() throws {
        let (_, output) = try Self.run(Self.sample, ["include_all": .bool(true)])
        let out = try #require(output)
        #expect(out.items.count == 4)
        #expect(out.totalItems == 4)
        #expect(out.availableCount == 2)
    }

    @Test("bundle_id hit returns that app whatever its status")
    func bundleIDHit() throws {
        let (_, output) = try Self.run(Self.sample, ["bundle_id": .string("b")])
        let out = try #require(output)
        #expect(out.items.map(\.bundleID) == ["b"])
        #expect(out.items.first?.status == "up_to_date")
        #expect(out.items.first?.availableVersion == nil)
    }

    @Test("bundle_id miss is a successful empty result")
    func bundleIDMiss() throws {
        let (result, output) = try Self.run(Self.sample, ["bundle_id": .string("zzz")])
        #expect(result.isError == false)
        #expect(try #require(output).items.isEmpty)
    }

    @Test("items are capped at 100 while total_items keeps the real count")
    func capped() throws {
        let rows = (0 ..< 130).map { Self.row("app\($0)", .available(Self.candidate(), .inPlace)) }
        let (result, output) = try Self.run(rows)
        let out = try #require(output)
        #expect(out.items.count == 100)
        #expect(out.totalItems == 130)
        #expect(out.availableCount == 130)
        guard case .text(let summary) = result.content.first else {
            Issue.record("no text")
            return
        }
        #expect(summary.contains("Showing first 100 of 130"))
    }

    @Test("provider error becomes a tool failure")
    func providerError() throws {
        struct Boom: Error {}
        let handler = MCPListAppUpdatesToolHandler(rowsProvider: { throw Boom() })
        let result = try handler.handle(MCPToolArguments([:]))
        #expect(result.isError == true)
    }

    @Test("each status maps to its wire value and fields")
    func statusMapping() throws {
        let rows = [
            Self.row("avail", .available(Self.candidate(), .inPlace)),
            Self.row("brew", .available(Self.candidate(source: .homebrewCask), .brewUpgrade(token: "tok"))),
            Self.row("link", .available(Self.candidate(download: false), .linkOnly(nil, reason: .packageInstaller))),
            Self.row("mas", .available(Self.candidate(source: .appStore, download: false), .openAppStore(URL(string: "https://apps.apple.com/a")!))),
            Self.row("up", .upToDate(latest: nil)),
            Self.row("ign", .ignored),
            Self.row("skip", .skippedVersion("2.0")),
            Self.row("fail", .failed("net")),
            Self.row("none", .untracked),
        ]
        let (_, output) = try Self.run(rows, ["include_all": .bool(true)])
        let items = Dictionary(uniqueKeysWithValues: try #require(output).items.map { ($0.bundleID, $0) })
        #expect(items["avail"]?.status == "available")
        #expect(items["avail"]?.availableVersion == "2.0")
        #expect(items["avail"]?.source == "sparkle")
        #expect(items["avail"]?.directDownload == true)
        #expect(items["avail"]?.installedVersion == "1.0")
        #expect(items["brew"]?.brewManagedToken == "tok")
        #expect(items["brew"]?.source == "homebrew_cask")
        #expect(items["link"]?.status == "link_only")
        #expect(items["link"]?.directDownload == false)
        #expect(items["mas"]?.source == "app_store")
        #expect(items["up"]?.status == "up_to_date")
        #expect(items["ign"]?.status == "ignored")
        #expect(items["skip"]?.status == "skipped")
        #expect(items["fail"]?.status == "failed")
        #expect(items["none"]?.status == "untracked")
        #expect(items["none"]?.availableVersion == nil)
    }

    @Test("registered in Phase 2 only")
    func registry() {
        #expect(MCPPhase2Tools.all.contains { $0.name == .listAppUpdates })
        #expect(!MCPPhase3Tools.all.contains { $0.name == .listAppUpdates })
    }
}
