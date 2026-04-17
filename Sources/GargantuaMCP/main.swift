import Foundation
import GargantuaCore

// Phase 2 stdio MCP server entry point.
//
// This task defines the target shape and tool schemas only. Dispatch,
// JSON-RPC framing, and tool handlers land in follow-up tasks under
// Feature gargantua-2h06. Running the binary today prints the registered
// tool catalog to stderr so integrators can confirm wiring, then exits.

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

let catalog = MCPPhase2Tools.all

FileHandle.standardError.write(Data("Gargantua MCP server — Phase 2 (schemas only)\n".utf8))
FileHandle.standardError.write(Data("Registered tools:\n".utf8))
for tool in catalog {
    FileHandle.standardError.write(Data("  - \(tool.name.rawValue): \(tool.description)\n".utf8))
}

if let payload = try? encoder.encode(catalog),
   let json = String(data: payload, encoding: .utf8) {
    FileHandle.standardOutput.write(Data(json.utf8))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

exit(EXIT_SUCCESS)
