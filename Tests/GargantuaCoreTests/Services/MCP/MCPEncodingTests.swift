import Testing
import Foundation
@testable import GargantuaCore

/// A stand-in for the date-bearing tool payload the MCP surface does not have
/// today. The point of the suite is that adding one later cannot regress the
/// wire format back to reference-date numbers.
private struct DateBearingPayload: Codable, Equatable {
    let label: String
    let recordedAt: Date
}

@Suite("MCPEncoding date strategy")
struct MCPEncodingTests {

    /// 2026-04-11T14:30:00Z
    private static let fixedDate = Date(timeIntervalSince1970: 1_775_917_800)
    private static let fixedISO = "2026-04-11T14:30:00Z"

    @Test("encodeAsJSONAny writes Date fields as ISO-8601 strings")
    func encodesDatesAsISO8601() throws {
        let encoded = try MCPEncoding.encodeAsJSONAny(
            DateBearingPayload(label: "scan", recordedAt: Self.fixedDate)
        )
        guard case .object(let fields) = encoded else {
            Issue.record("expected an object, got \(encoded)")
            return
        }
        #expect(fields["recordedAt"] == .string(Self.fixedISO))
    }

    @Test("decodeFromJSONAny reads ISO-8601 strings back into Date")
    func decodesISO8601IntoDate() throws {
        let any: MCPJSONAny = .object([
            "label": .string("scan"),
            "recordedAt": .string(Self.fixedISO),
        ])
        let decoded = try MCPEncoding.decodeFromJSONAny(DateBearingPayload.self, from: any)
        #expect(decoded == DateBearingPayload(label: "scan", recordedAt: Self.fixedDate))
    }

    @Test("a handler's ISO-8601 date payload reaches the wire unmangled")
    func handlerDatePayloadReachesWireUnmangled() throws {
        let dispatcher = MCPRequestDispatcher(
            serverInfo: MCPServerInfo(name: "gargantua", version: "0.0.1"),
            tools: MCPPhase2Tools.all
        )
        dispatcher.register(tool: .status) { _ in
            let payload = try MCPEncoding.encodeAsJSONAny(
                DateBearingPayload(label: "scan", recordedAt: Self.fixedDate)
            )
            return .structured(payload, summary: "ok")
        }
        let response = try #require(
            dispatcher.dispatch(
                MCPRequest(
                    id: .int(1),
                    method: "tools/call",
                    params: .object(["name": .string("status")])
                )
            )
        )
        #expect(response.error == nil)
        // End-to-end shape check only: `structuredContent` is typed
        // `MCPJSONAny`, which has no `Date` case, so the handler has already
        // stringified the date before the dispatcher's encoder ever sees it.
        // This test therefore cannot fail on a dispatcher date-strategy
        // regression — `noBareJSONCodersInMCPToolPayloadPath` is that guard.
        let wire = try MCPWireCoding.encoder.encode(response)
        let json = try #require(String(data: wire, encoding: .utf8))
        #expect(json.contains("\"\(Self.fixedISO)\""))
    }

    @Test("tool arguments decode an ISO-8601 string into a Date field")
    func toolArgumentsDecodeISO8601Date() throws {
        let args = MCPToolArguments([
            "label": .string("scan"),
            "recordedAt": .string(Self.fixedISO),
        ])
        let decoded = try args.decode(DateBearingPayload.self)
        #expect(decoded.recordedAt == Self.fixedDate)
    }

    private static var mcpSourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MCP
            .deletingLastPathComponent() // Services
            .deletingLastPathComponent() // GargantuaCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/GargantuaCore/Services/MCP")
    }

    /// Fails loudly (rather than vacuously passing on an empty scan) when the
    /// path arithmetic above stops landing on the real MCP sources directory.
    private static func requireMCPSourceRoot() -> URL {
        let root = mcpSourceRoot
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        #expect(exists && isDirectory.boolValue, "Expected an MCP sources directory at \(root.path)")
        return root
    }

    private static func swiftFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            Issue.record("Could not enumerate \(root.path)")
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    /// The regression guard for the dispatcher's date strategy. It cannot be
    /// written behaviourally (see `handlerDatePayloadReachesWireUnmangled`),
    /// so it is enforced structurally: every MCP tool-payload file routes
    /// through `MCPEncoding` or `MCPWireCoding` rather than building its own
    /// coder, because a bare `JSONEncoder()` silently reverts dates to
    /// numeric seconds since the Foundation reference date.
    @Test("no MCP tool-payload file constructs its own JSON coder")
    func noBareJSONCodersInMCPToolPayloadPath() throws {
        // The two sanctioned coder owners, plus files outside the tool-payload
        // path entirely (on-disk status persistence and transport settings).
        let allowed: Set<String> = [
            "MCPEncoding.swift",
            "MCPWireCoding.swift",
            "MCPServerStatusPersistence.swift",
            "MCPTransportSettings.swift",
        ]

        let root = Self.requireMCPSourceRoot()
        let files = Self.swiftFiles(under: root)
        #expect(!files.isEmpty, "Expected to find .swift files under \(root.path)")

        // Whitespace-stripped spellings this guard catches. This targets
        // reintroduction by habit (`JSONEncoder ()`, `JSONEncoder .init()`,
        // a coder split across a line break), not deliberate evasion — a
        // determined alias or a coder built outside this directory will
        // still slip past.
        let bannedSpellings = ["JSONEncoder()", "JSONDecoder()", "JSONEncoder.init(", "JSONDecoder.init("]

        var offenders: [String] = []
        for file in files where !allowed.contains(file.lastPathComponent) {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                let stripped = line.components(separatedBy: .whitespacesAndNewlines).joined()
                if bannedSpellings.contains(where: { stripped.contains($0) }) {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            "MCP tool-payload files must route through MCPEncoding/MCPWireCoding rather than constructing their own JSON coder: \(offenders.joined(separator: ", "))"
        )
    }

    /// The positive companion to `noBareJSONCodersInMCPToolPayloadPath`: the
    /// negative scan proves no file builds its own coder, but nothing else
    /// proves the dispatcher actually reached for the shared helper.
    @Test("the dispatcher routes tool payloads through MCPEncoding")
    func dispatcherUsesSharedMCPEncoding() throws {
        let root = Self.requireMCPSourceRoot()
        let dispatcherFile = root.appendingPathComponent("MCPRequestDispatcher.swift")
        let contents = try String(contentsOf: dispatcherFile, encoding: .utf8)

        #expect(
            contents.contains("MCPEncoding.encodeAsJSONAny"),
            "MCPRequestDispatcher.swift no longer references MCPEncoding.encodeAsJSONAny"
        )
        #expect(
            contents.contains("MCPEncoding.decodeFromJSONAny"),
            "MCPRequestDispatcher.swift no longer references MCPEncoding.decodeFromJSONAny"
        )
    }
}
