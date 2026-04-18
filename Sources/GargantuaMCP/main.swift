import Foundation
import GargantuaCore

// Phase 2 stdio MCP server entry point.
//
// This task wires JSON-RPC 2.0 framing over newline-delimited stdio. No
// dispatch yet — every request receives a `method not found` response.
// The follow-up task under Feature gargantua-2h06 (tools/list + tools/call)
// replaces the default handler with real routing.

FileHandle.standardError.write(Data(
    "Gargantua MCP server — Phase 2 (framing only)\n".utf8
))
FileHandle.standardError.write(Data(
    "Registered tools (advertised once dispatch lands):\n".utf8
))
for tool in MCPPhase2Tools.all {
    FileHandle.standardError.write(Data(
        "  - \(tool.name.rawValue): \(tool.description)\n".utf8
    ))
}

let transport = MCPStdioTransport(
    source: StandardInputMessageSource(),
    sink: StandardOutputMessageSink(),
    handler: { request in
        let requestID = request.id ?? .null
        return .failure(
            id: requestID,
            code: MCPErrorCode.methodNotFound,
            message: "Method not found: \(request.method)"
        )
    },
    log: { message in
        FileHandle.standardError.write(Data("[mcp] \(message)\n".utf8))
    }
)

transport.run()
