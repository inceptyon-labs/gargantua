import Foundation
import Darwin
import CoreFoundation
import Testing
@testable import GargantuaCore

// MARK: - Shared MCP SSE transport test networking helpers

/// Shared raw-socket helpers used across the MCP SSE transport test suites
/// (`MCPSSETransportTests`, `MCPSSETransportNetworkingTests`,
/// `MCPSSETransportLifecycleTests`). Kept at file scope, nested under this
/// enum namespace to avoid colliding with other test files that declare
/// their own file-private `TCPClient` / `findFreePort` helpers.
enum MCPSSETransportTestSupport {
    /// Errors raised by `findFreePort()` and `TCPClient`.
    enum SocketError: Error {
        case writeFailed
        case readFailed
        case timedOut(String)
        case noFreePort
    }

    /// Binds an ephemeral loopback socket, reads back the port the kernel
    /// assigned, then releases it so `MCPSSETransport` (or a raw test
    /// socket) can bind that same port a moment later.
    static func findFreePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.noFreePort }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw SocketError.noFreePort }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else { throw SocketError.noFreePort }
        return UInt16(bigEndian: address.sin_port)
    }

    /// Polls a real TCP connect attempt against `127.0.0.1:port` until it
    /// succeeds or `timeout` elapses, returning whether the listener is
    /// actually accepting connections yet.
    ///
    /// `MCPSSETransport.start()` returns before its `NWListener` has
    /// finished binding (or reported an async bind failure), so a fixed
    /// `usleep` after `start()` is both slower than necessary on a fast
    /// machine and not long enough on a loaded CI box. This probes the real
    /// thing instead of guessing a sleep duration.
    static func waitUntilAcceptingConnections(port: UInt16, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                usleep(10_000)
                continue
            }
            defer { close(fd) }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")

            let connectResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if connectResult == 0 {
                return true
            }
            usleep(10_000)
        } while Date() < deadline
        return false
    }

    /// Allocates a fresh loopback port, builds a transport for it via
    /// `makeTransport`, starts it, and blocks until it is actually accepting
    /// connections (see `waitUntilAcceptingConnections`).
    ///
    /// `findFreePort()` hands back a port number after closing the probe
    /// socket that reserved it, which leaves a gap where a parallel test (or
    /// another process) can claim the same port before the listener binds.
    /// If `start()` throws, or the listener never becomes ready within
    /// `readinessTimeout`, this retries with a freshly allocated port up to
    /// `attempts` times before giving up.
    static func startTransport(
        attempts: Int = 3,
        readinessTimeout: TimeInterval = 5,
        makeTransport: (UInt16) -> MCPSSETransport
    ) throws -> (transport: MCPSSETransport, port: UInt16) {
        var lastError: Error = SocketError.noFreePort
        for _ in 0 ..< attempts {
            let port = try findFreePort()
            let transport = makeTransport(port)
            do {
                try transport.start()
            } catch {
                lastError = error
                continue
            }
            if waitUntilAcceptingConnections(port: port, timeout: readinessTimeout) {
                return (transport, port)
            }
            transport.stop()
            lastError = SocketError.timedOut(
                "MCPSSETransport on port \(port) never accepted a connection within \(readinessTimeout)s"
            )
        }
        throw lastError
    }

    /// Deadline-bounded TCP client used to drive `MCPSSETransport`'s raw
    /// HTTP/SSE wire protocol from tests.
    ///
    /// Every `read(until:)` call is bounded by `timeout` (default 2s) and
    /// throws `SocketError.timedOut` instead of blocking forever. Without
    /// this, a peer that never replies — or a port `findFreePort()` handed
    /// back that another process grabbed in the gap before the listener
    /// bound it — hangs the calling test in a raw `recv`/stream read
    /// forever. swift-testing has no per-test timeout, so that hang runs
    /// until the CI job's outer timeout kills the whole run instead of
    /// failing just this test.
    final class TCPClient {
        private let input: InputStream
        private let output: OutputStream
        private var isClosed = false

        init(port: Int) throws {
            var readStream: Unmanaged<CFReadStream>?
            var writeStream: Unmanaged<CFWriteStream>?
            CFStreamCreatePairWithSocketToHost(
                nil,
                "127.0.0.1" as CFString,
                UInt32(port),
                &readStream,
                &writeStream
            )
            self.input = try #require(readStream?.takeRetainedValue() as InputStream?)
            self.output = try #require(writeStream?.takeRetainedValue() as OutputStream?)
            input.open()
            output.open()
        }

        deinit {
            closeGracefully()
        }

        private func closeGracefully() {
            guard !isClosed else { return }
            isClosed = true
            input.close()
            output.close()
        }

        /// Forces the client's TCP connection closed with `SO_LINGER` set to
        /// a zero timeout, so the kernel sends an RST instead of a graceful
        /// FIN.
        ///
        /// A plain close (what `deinit` does) is a half-close: the peer can
        /// keep sending successfully for a while after, so a test that needs
        /// the *server's* next write to fail immediately can't rely on it —
        /// that makes the observed disconnect dependent on network-stack
        /// timing. Forcing an RST here makes the peer's next write fail
        /// deterministically. Only tests that specifically need that
        /// guarantee should call this; everything else keeps the graceful
        /// close via `deinit`.
        func closeAbortively() {
            defer { closeGracefully() }
            guard let handle = CFWriteStreamCopyProperty(
                output as CFWriteStream,
                .socketNativeHandle
            ) as? Data, handle.count >= MemoryLayout<Int32>.size else {
                return
            }
            var fd: Int32 = -1
            _ = withUnsafeMutableBytes(of: &fd) { destination in
                handle.copyBytes(to: destination, count: MemoryLayout<Int32>.size)
            }
            guard fd >= 0 else { return }
            var lingerOption = linger(l_onoff: 1, l_linger: 0)
            setsockopt(fd, SOL_SOCKET, SO_LINGER, &lingerOption, socklen_t(MemoryLayout<linger>.size))
        }

        func write(_ string: String) throws {
            let bytes = Array(string.utf8)
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBufferPointer { buffer in
                    output.write(
                        buffer.baseAddress!.advanced(by: offset),
                        maxLength: bytes.count - offset
                    )
                }
                guard written > 0 else {
                    throw SocketError.writeFailed
                }
                offset += written
            }
        }

        func read(until marker: String, timeout: TimeInterval = 2) throws -> String {
            let markerData = Data(marker.utf8)
            var data = Data()
            let deadline = Date().addingTimeInterval(timeout)
            var buffer = [UInt8](repeating: 0, count: 4_096)

            while Date() < deadline {
                if input.hasBytesAvailable {
                    let count = input.read(&buffer, maxLength: buffer.count)
                    if count > 0 {
                        data.append(buffer, count: count)
                        if data.range(of: markerData) != nil {
                            return String(bytes: data, encoding: .utf8) ?? ""
                        }
                    } else if count < 0 {
                        throw SocketError.readFailed
                    }
                } else {
                    RunLoop.current.run(
                        mode: .default,
                        before: Date().addingTimeInterval(0.01)
                    )
                }
            }

            throw SocketError.timedOut(String(bytes: data, encoding: .utf8) ?? "")
        }
    }
}
