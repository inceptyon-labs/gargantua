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
    private let connectionsLock = NSLock()
    private var acceptedConnections: [WeakConnection] = []
    /// Bumped by both `start()` and `stop()`, so every accepted connection can
    /// be matched against the listener generation that handed it over. Guarded
    /// by `connectionsLock`, like `listener`. See `trackForShutdown`.
    private var listenerGeneration = 0

    /// Weak handle to an accepted connection, so `stop()` can cancel what is
    /// still live without the registry itself keeping anything alive.
    ///
    /// Deliberately weak rather than strong: a strong registry would need a
    /// deregistration hook on every terminal path or it would become a second
    /// leak, and `handle(_:on:)` *replaces* `stateUpdateHandler` on the SSE
    /// path — so a deregistering handler installed in `accept` would be
    /// silently clobbered there, leaving two places that both have to remember
    /// to deregister. A weak box needs none of that: a connection that goes
    /// away nils its own entry, and `trackForShutdown` prunes the corpses.
    private final class WeakConnection {
        weak var value: NWConnection?

        init(_ value: NWConnection) {
            self.value = value
        }
    }

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
    ///
    /// Call once per instance. Restarting a stopped transport is **not**
    /// supported: the cancelled listener does not release its port
    /// synchronously, so the new `NWListener` sits in `.waiting` retrying the
    /// bind rather than failing, and never becomes ready. Nothing in the app
    /// restarts a transport — `GargantuaMCP` starts one and stops it from its
    /// signal handler — so this is documented rather than fixed. The
    /// generation counter below still accounts for a restart because getting
    /// *that* wrong would be silent (see `trackForShutdown`), whereas this
    /// limitation is loud.
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
        connectionsLock.lock()
        listenerGeneration += 1
        let generation = listenerGeneration
        self.listener = listener
        connectionsLock.unlock()

        // Stamped with the generation captured above so a connection this
        // listener hands over can be told apart from one belonging to a
        // listener that has since been stopped — see `trackForShutdown`.
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, generation: generation)
        }

        // Handler installed and listener started outside the lock: no
        // connection can arrive before `start(queue:)`, and holding the lock
        // across a framework call would make `accept` on `queue` wait on it.
        listener.start(queue: queue)
    }

    /// Cancels the listener and every connection still live, so no accepted
    /// connection — and no SSE session behind one — outlives the transport.
    ///
    /// Cancelling is what evicts the sessions: `.cancelled` reaches the
    /// `stateUpdateHandler` installed in `handle(_:on:)`, which calls
    /// `router.closeStream(sessionID:)`. That delivery is asynchronous on
    /// `queue`, so this returns having *requested* teardown, not having
    /// observed it complete. The one production caller is a signal handler
    /// that calls `exit(0)` immediately after; blocking here to wait on the
    /// transport's own queue would risk deadlocking it for no gain.
    ///
    /// Bumping `listenerGeneration` is what makes the guarantee hold against a
    /// connection arriving mid-shutdown: `listener.cancel()` is asynchronous,
    /// so a `newConnectionHandler` block dispatched before it took effect can
    /// still reach `accept` after the snapshot below has been taken and
    /// cleared. Such a connection would be in nobody's list, so `accept`
    /// cancels it outright instead of starting it.
    public func stop() {
        connectionsLock.lock()
        listenerGeneration += 1
        let stoppingListener = listener
        listener = nil
        let live = acceptedConnections.compactMap(\.value)
        acceptedConnections.removeAll()
        connectionsLock.unlock()

        // Cancel outside the lock: each cancel can reach `closeStream` and the
        // `onConnectionClose` consumers, which take the router and dispatcher
        // locks. Nesting those under ours would invert the lock order the
        // router documents on `closeStream`.
        stoppingListener?.cancel()
        for connection in live {
            connection.cancel()
        }
    }

    private func accept(_ connection: NWConnection, generation: Int) {
        guard trackForShutdown(connection, generation: generation) else {
            // The listener that handed this over has since been stopped, so
            // nothing else holds a handle to this connection and nothing else
            // would ever cancel it.
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        readRequest(from: connection, buffer: Data())
    }

    /// Records a connection so `stop()` can find it, dropping any entries
    /// whose connection has already gone away, and reports whether the
    /// connection still belongs to the running listener.
    ///
    /// Pruning here — on the one path that adds entries — keeps the array at
    /// roughly the live-connection count without any teardown-side
    /// bookkeeping.
    ///
    /// The generation check is what rejects a connection whose listener is
    /// gone. A single "stopped" flag would not be enough: `start()` would
    /// clear it, and a `newConnectionHandler` block left over from the
    /// *previous* listener could then run after the restart, find the
    /// transport running again, and get started as though it belonged to the
    /// new one. Both `start()` and `stop()` bump the generation, so an accept
    /// is only ever honoured by the listener that actually produced it.
    ///
    /// A connection tracked here can still be cancelled by `stop()` in the
    /// moment before `accept` calls `start(queue:)` on it. Starting an
    /// already-cancelled `NWConnection` is harmless — its receive completes
    /// with an error and `readRequest` tears it down — so that ordering is
    /// left alone rather than held under the lock across a framework call.
    private func trackForShutdown(_ connection: NWConnection, generation: Int) -> Bool {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        guard generation == listenerGeneration else { return false }
        acceptedConnections.removeAll { $0.value == nil }
        acceptedConnections.append(WeakConnection(connection))
        return true
    }

    /// Number of connections currently tracked for shutdown, counting any
    /// whose connection has gone away but whose box has not been pruned yet.
    ///
    /// Internal purely so `MCPSSETransportLifecycleTests` can assert the
    /// registry never becomes a second leak. Both properties that prevent it —
    /// the boxes being weak, and the prune in `trackForShutdown` — are
    /// invisible from outside this type, and removing either one leaves the
    /// entire suite green.
    var trackedConnectionCount: Int {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        return acceptedConnections.count
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
