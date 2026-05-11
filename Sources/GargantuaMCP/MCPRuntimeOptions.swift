import Foundation
import GargantuaCore

enum MCPRuntimeTransportMode: String {
    case stdio
    case sse
    case both

    var includesStdio: Bool { self == .stdio || self == .both }
    var includesSSE: Bool { self == .sse || self == .both }

    var statusMode: MCPServerTransportMode {
        switch self {
        case .stdio: return .stdio
        case .sse: return .sse
        case .both: return .stdioAndSSE
        }
    }
}

struct MCPRuntimeOptions {
    var transportMode: MCPRuntimeTransportMode?
    var ssePort: Int?
    var bindScope: MCPServerBindScope?
    var bearerToken: String?
}

func parseRuntimeOptions(log: (String) -> Void) -> MCPRuntimeOptions {
    var options = MCPRuntimeOptions()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--stdio":
            options.transportMode = .stdio
        case "--sse":
            options.transportMode = .sse
        case "--both":
            options.transportMode = .both
        case "--transport":
            options.transportMode = parseTransportArgument(iterator.next(), log: log)
        case "--port":
            options.ssePort = parsePortArgument(iterator.next(), log: log)
        case "--bind":
            options.bindScope = parseBindArgument(iterator.next(), log: log)
        case "--token":
            options.bearerToken = parseTokenArgument(iterator.next(), log: log)
        case "--help", "-h":
            printRuntimeHelp()
            exit(0)
        default:
            log("unknown argument \(argument)")
            printRuntimeHelp()
            exit(64)
        }
    }
    return options
}

private func parseTransportArgument(
    _ value: String?,
    log: (String) -> Void
) -> MCPRuntimeTransportMode {
    guard let value,
          let mode = MCPRuntimeTransportMode(rawValue: value.lowercased())
    else {
        log("invalid --transport value; expected stdio, sse, or both")
        exit(64)
    }
    return mode
}

private func parsePortArgument(_ value: String?, log: (String) -> Void) -> Int {
    guard let value, let port = Int(value) else {
        log("invalid --port value")
        exit(64)
    }
    return port
}

private func parseBindArgument(
    _ value: String?,
    log: (String) -> Void
) -> MCPServerBindScope {
    guard let value,
          let scope = MCPServerBindScope(rawValue: value.lowercased())
    else {
        log("invalid --bind value; expected localhost or lan")
        exit(64)
    }
    return scope
}

private func parseTokenArgument(_ value: String?, log: (String) -> Void) -> String {
    guard let value, MCPBearerTokenValidator.isPlausible(value) else {
        log("invalid --token value")
        exit(64)
    }
    return MCPBearerTokenValidator.normalized(value)
}

private func printRuntimeHelp() {
    let help = """
    GargantuaMCP options:
      --transport stdio|sse|both   Select MCP transport. Defaults to stdio, or both when SSE is enabled in Settings.
      --stdio                      Shortcut for --transport stdio.
      --sse                        Shortcut for --transport sse.
      --both                       Shortcut for --transport both.
      --port 7493                  Override the SSE port.
      --bind localhost|lan         Bind SSE to 127.0.0.1 or all interfaces.
      --token TOKEN                Bearer token override for LAN SSE.

    Security:
      GargantuaMCP serves plain HTTP. For network clients, keep --bind localhost
      and terminate HTTPS in a reverse proxy that forwards to 127.0.0.1:7493.
      Use --bind lan only on trusted networks, with a bearer token and a TLS
      proxy in front of the port.
    """
    FileHandle.standardError.write(Data("\(help)\n".utf8))
}
