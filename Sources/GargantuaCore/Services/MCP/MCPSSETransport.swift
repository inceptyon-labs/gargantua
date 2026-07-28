import Foundation
import Network
import os

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
        handler: @escaping MCPConnectionMessageHandler,
        onConnectionClose: MCPSSERequestRouter.ConnectionCloseHandler? = nil,
        log: MCPTransportLog? = nil,
        queue: DispatchQueue = DispatchQueue(label: "com.gargantua.mcp.sse")
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.router = MCPSSERequestRouter(handler: handler, log: log, onClose: onConnectionClose)
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

    /// Keeps a receive outstanding on an opened SSE stream so the peer going
    /// away is actually observed.
    ///
    /// From here on the connection is write-only — the client has no further
    /// requests to make on this socket — so there is nothing left to parse.
    /// But an `NWConnection` with no pending receive does not transition to
    /// `.cancelled`/`.failed` when the peer sends FIN, so the
    /// `stateUpdateHandler` installed in `handle(_:on:)` would never fire and
    /// `router.closeStream` would never run: the session stays in the routing
    /// table and the connection stays alive for the process lifetime, and both
    /// grow unbounded on a long-lived daemon. Arming a receive that discards
    /// whatever it gets makes EOF (or a read error) reach us, and the
    /// `cancel()` below is what drives the transition that tears the session
    /// down.
    ///
    /// Re-arming after each non-terminal completion is load-bearing, not
    /// bookkeeping: a single byte from the client consumes a one-shot receive,
    /// and without the re-arm that connection is back to having none pending —
    /// its later FIN would go unobserved exactly as before this method existed.
    ///
    /// `isComplete` is also true when the client has only shut down its write
    /// side while still reading, so a half-closing client is treated as gone
    /// and its session torn down. That is deliberate: HTTP has no way to
    /// resume such a connection, and no MCP client half-closes.
    private func drainClientBytes(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] _, _, isComplete, error in
            if let error {
                // `readRequest` logs the same failure class; without this, a
                // client that vanished cleanly and a socket that errored are
                // indistinguishable in the log when sessions start dropping.
                self?.log?("SSE stream read failed: \(error)")
            }
            guard let self, error == nil, !isComplete else {
                connection.cancel()
                return
            }
            self.drainClientBytes(on: connection)
        }
    }

    private func handle(_ request: MCPHTTPRequest, on connection: NWConnection) {
        let storedToken = (try? tokenProvider())
        if request.method == "GET", request.path == "/sse" {
            let sessionBox = OSAllocatedUnfairLock<String?>(initialState: nil)
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
                    if let sessionID = sessionBox.withLock({ $0 }) {
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
                sessionBox.withLock { $0 = openedSessionID }
                switch connection.state {
                case .cancelled, .failed:
                    // The connection already died between openStream registering the
                    // session and this write. The stateUpdateHandler installed above
                    // runs asynchronously on this same serial queue: it will either
                    // fire later for this transition — and would double-close the
                    // session if the box were left populated — or never fire at all if
                    // it was installed too late to observe the transition. Clear the
                    // box first so a later invocation is a no-op, then close the
                    // session and cancel the connection directly here so nothing is
                    // leaked in the meantime.
                    //
                    // UNTESTED: no test in the suite reaches this branch. Triggering it
                    // needs the connection to transition to .cancelled/.failed in the
                    // narrow window between openStream() returning and this switch
                    // running, which isn't reliably reproducible from a real socket
                    // without the test itself becoming racy. The ordering here — clear
                    // sessionBox, THEN closeStream, THEN cancel the connection — is
                    // load-bearing (reversing the first two would let a later, async
                    // firing of stateUpdateHandler's own .cancelled/.failed arm read a
                    // stale session id and double-close it) but is verified only by
                    // inspection. Do not reorder these three statements without adding
                    // coverage first.
                    sessionBox.withLock { $0 = nil }
                    router.closeStream(sessionID: openedSessionID)
                    connection.cancel()
                default:
                    write(response, to: connection, closeAfterWrite: false)
                    drainClientBytes(on: connection)
                }
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
