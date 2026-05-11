import Foundation
import Network

/// TCP/SSE transport that exposes the MCP server over loopback HTTP.
public final class MCPSSETransport: @unchecked Sendable {
    /// Closure that returns the current bearer token, if any.
    public typealias TokenProvider = @Sendable () throws -> String?

    private let configuration: MCPSSEServerConfiguration
    private let tokenProvider: TokenProvider
    private let router: MCPSSERequestRouter
    private let log: MCPTransportLog?
    private let queue: DispatchQueue
    private var listener: NWListener?

    /// Creates a transport, wiring router, token provider, and dispatch queue.
    public init(
        configuration: MCPSSEServerConfiguration,
        tokenProvider: @escaping TokenProvider,
        handler: @escaping MCPMessageHandler,
        log: MCPTransportLog? = nil,
        queue: DispatchQueue = DispatchQueue(label: "com.gargantua.mcp.sse")
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.router = MCPSSERequestRouter(handler: handler, log: log)
        self.log = log
        self.queue = queue
    }

    /// Validates configuration, binds the listener, and begins accepting connections.
    public func start() throws {
        try configuration.validate(hasBearerToken: tokenProvider() != nil)
        let port = NWEndpoint.Port(rawValue: UInt16(configuration.port))!
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(configuration.bindHost),
            port: port
        )

        let listener = try NWListener(using: parameters)
        let bindDescription = "\(configuration.bindHost):\(configuration.port)"
        listener.stateUpdateHandler = { [log] state in
            switch state {
            case .ready:
                log?("SSE transport listening on \(bindDescription)")
            case .failed(let error):
                log?("SSE transport failed: \(error)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    /// Cancels the listener and stops accepting new connections.
    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(from: connection, buffer: Data())
    }

    private func readRequest(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }
            if let error {
                self.log?("SSE connection read failed: \(error)")
                connection.cancel()
                return
            }

            do {
                if let request = try MCPHTTPRequestParser.parse(nextBuffer) {
                    self.handle(request, on: connection)
                    return
                }
            } catch {
                let response = MCPHTTPResponse.text(400, "Bad Request", error.localizedDescription)
                self.write(response, to: connection, closeAfterWrite: true)
                return
            }

            if isComplete {
                connection.cancel()
                return
            }
            self.readRequest(from: connection, buffer: nextBuffer)
        }
    }

    private func handle(_ request: MCPHTTPRequest, on connection: NWConnection) {
        let storedToken = (try? tokenProvider())
        if request.method == "GET", request.path == "/sse" {
            var sessionID: String?
            let sink: MCPSSERequestRouter.EventSink = { [weak connection] event, data in
                let payload = MCPSSEEvent.encode(event: event, data: data)
                connection?.send(
                    content: Data(payload.utf8),
                    completion: .contentProcessed { _ in }
                )
            }
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .cancelled, .failed:
                    if let sessionID {
                        self?.router.closeStream(sessionID: sessionID)
                    }
                default:
                    break
                }
            }

            switch router.openStream(
                request: request,
                configuration: configuration,
                storedToken: storedToken,
                eventSink: sink
            ) {
            case .opened(let openedSessionID, let response):
                sessionID = openedSessionID
                write(response, to: connection, closeAfterWrite: false)
            case .rejected(let response):
                write(response, to: connection, closeAfterWrite: true)
            }
            return
        }

        let response = router.handleRequest(
            request,
            configuration: configuration,
            storedToken: storedToken
        )
        write(response, to: connection, closeAfterWrite: true)
    }

    private func write(
        _ response: MCPHTTPResponse,
        to connection: NWConnection,
        closeAfterWrite: Bool
    ) {
        connection.send(
            content: response.serialized(),
            completion: .contentProcessed { error in
                if let error {
                    self.log?("SSE response write failed: \(error)")
                }
                if closeAfterWrite {
                    connection.cancel()
                }
            }
        )
    }
}
