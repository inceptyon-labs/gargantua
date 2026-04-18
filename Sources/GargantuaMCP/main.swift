import Foundation
import GargantuaCore

// Phase 2 stdio MCP server entry point.
//
// Framing lives in `MCPStdioTransport`; protocol dispatch lives in
// `MCPRequestDispatcher`. This entry point wires them together and routes
// log output to stderr (stdout is reserved for protocol traffic).
//
// Tool handlers are registered in follow-up Tasks under Feature gargantua-2h06.
// Until those land, `tools/call` returns JSON-RPC internal error 'Tool not
// implemented' for every Phase 2 tool.

private let mcpServerVersion = "0.1.0"

FileHandle.standardError.write(Data(
    "Gargantua MCP server — Phase 2\n".utf8
))
FileHandle.standardError.write(Data(
    "Registered tools:\n".utf8
))
for tool in MCPPhase2Tools.all {
    FileHandle.standardError.write(Data(
        "  - \(tool.name.rawValue): \(tool.description)\n".utf8
    ))
}

private let stderrLog: @Sendable (String) -> Void = { message in
    FileHandle.standardError.write(Data("[mcp] \(message)\n".utf8))
}

let dispatcher = MCPRequestDispatcher(
    serverInfo: MCPServerInfo(name: "gargantua", version: mcpServerVersion),
    tools: MCPPhase2Tools.all,
    log: stderrLog
)

let transport = MCPStdioTransport(
    source: StandardInputMessageSource(),
    sink: StandardOutputMessageSink(),
    handler: { request in dispatcher.dispatch(request) },
    log: stderrLog
)

transport.run()
