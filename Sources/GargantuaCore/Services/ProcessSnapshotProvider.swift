import Foundation
import OSLog

#if canImport(Darwin)
    import Darwin
#endif

private let logger = Logger(subsystem: "com.gargantua.core", category: "ProcessSnapshotProvider")

/// Raw per-process sample read straight from libproc / sysctl. The scanner
/// pairs two of these to derive CPU deltas before producing `ProcessItem`s.
public struct RawProcessSample: Sendable, Equatable {
    public let pid: Int32
    public let parentPID: Int32
    public let uid: UInt32
    /// Truncated command name from `pbi_comm` (max 16 bytes on Darwin).
    public let command: String
    /// Full executable path from `proc_pidpath`. `nil` when the call failed
    /// (kernel tasks, processes the caller can't introspect, etc.).
    public let executablePath: String?
    /// Process start time, expressed as Unix epoch seconds (`pbi_start_tvsec`).
    /// Critical for distinguishing a recycled PID from the same long-lived
    /// process across snapshots — without it, a respawned helper that reuses
    /// its parent's PID would inherit the prior CPU baseline.
    public let startTimeUnixSeconds: UInt64
    /// Sum of user + system CPU time in nanoseconds since the process began.
    public let cpuTimeNanoseconds: UInt64
    /// Resident memory in bytes.
    public let residentBytes: UInt64
    /// Wall-clock instant the sample was taken.
    public let sampledAt: Date

    public init(
        pid: Int32,
        parentPID: Int32,
        uid: UInt32,
        command: String,
        executablePath: String?,
        startTimeUnixSeconds: UInt64,
        cpuTimeNanoseconds: UInt64,
        residentBytes: UInt64,
        sampledAt: Date
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.uid = uid
        self.command = command
        self.executablePath = executablePath
        self.startTimeUnixSeconds = startTimeUnixSeconds
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.residentBytes = residentBytes
        self.sampledAt = sampledAt
    }
}

/// Source of process samples for the inventory scanner. Protocol-fronted so
/// tests can supply deterministic samples without exercising libproc.
public protocol ProcessSnapshotProviding: Sendable {
    /// One sample of every visible process at call time.
    func snapshot() -> [RawProcessSample]
}

/// Default implementation backed by `proc_listpids` + `proc_pidinfo` +
/// `proc_pidpath`. Only public APIs are used — this works in the sandbox.
///
/// Processes the caller cannot introspect (other users on multi-user systems,
/// kernel tasks) are silently dropped from the snapshot rather than failing
/// the whole pass — read-only review is best-effort by design.
public struct DefaultProcessSnapshotProvider: ProcessSnapshotProviding {
    private let now: @Sendable () -> Date
    private let userNameForUID: @Sendable (UInt32) -> String?

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        userNameForUID: @escaping @Sendable (UInt32) -> String? = Self.lookupUserName
    ) {
        self.now = now
        self.userNameForUID = userNameForUID
    }

    public func snapshot() -> [RawProcessSample] {
        #if canImport(Darwin)
            let pids = Self.listPIDs()
            let timestamp = now()
            var samples: [RawProcessSample] = []
            samples.reserveCapacity(pids.count)
            for pid in pids where pid > 0 {
                if let sample = sample(pid: pid, at: timestamp) {
                    samples.append(sample)
                }
            }
            return samples
        #else
            return []
        #endif
    }

    // MARK: - Per-PID sampling

    #if canImport(Darwin)
        private func sample(pid: Int32, at timestamp: Date) -> RawProcessSample? {
            // BSD info: parent PID, UID, command name. Dropping the process
            // when this fails matches the Activity Monitor behaviour for
            // kernel tasks: they're invisible rather than half-populated.
            //
            // Use `.size` (not `.stride`) — `proc_pidinfo` writes exactly the
            // C struct size; with trailing alignment padding `.stride` could
            // exceed `.size` and the equality check would drop every sample.
            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            let bsdResult = withUnsafeMutablePointer(to: &bsd) { ptr -> Int32 in
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, UnsafeMutableRawPointer(ptr), bsdSize)
            }
            guard bsdResult == bsdSize else { return nil }

            // Task info: CPU time + resident memory. Failure here is expected
            // for processes whose task port we can't open — return without
            // the sample rather than synthesising a misleading zero.
            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let taskResult = withUnsafeMutablePointer(to: &task) { ptr -> Int32 in
                proc_pidinfo(pid, PROC_PIDTASKINFO, 0, UnsafeMutableRawPointer(ptr), taskSize)
            }
            guard taskResult == taskSize else { return nil }

            let executablePath = Self.executablePath(for: pid)
            let command = Self.commandName(from: bsd)
            let cpuTime = task.pti_total_user &+ task.pti_total_system

            return RawProcessSample(
                pid: pid,
                parentPID: Int32(bsd.pbi_ppid),
                uid: bsd.pbi_uid,
                command: command,
                executablePath: executablePath,
                startTimeUnixSeconds: UInt64(bsd.pbi_start_tvsec),
                cpuTimeNanoseconds: cpuTime,
                residentBytes: task.pti_resident_size,
                sampledAt: timestamp
            )
        }

        private static func listPIDs() -> [Int32] {
            // Two-pass: query the byte size first, then fill the buffer.
            // `proc_listpids` returns the byte count, not the element count;
            // dividing by the stride yields the PID count.
            let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
            guard bytes > 0 else { return [] }
            var buffer = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.stride)
            let written = buffer.withUnsafeMutableBytes { rawBuffer -> Int32 in
                proc_listpids(UInt32(PROC_ALL_PIDS), 0, rawBuffer.baseAddress, Int32(rawBuffer.count))
            }
            guard written > 0 else { return [] }
            let count = Int(written) / MemoryLayout<pid_t>.stride
            return Array(buffer.prefix(count))
        }

        /// `PROC_PIDPATHINFO_MAXSIZE` from `<sys/proc_info.h>` (4 × MAXPATHLEN).
        /// The constant isn't surfaced to Swift, so it's hardcoded here.
        private static let pidPathInfoMaxSize: Int = 4 * 1024

        private static func executablePath(for pid: Int32) -> String? {
            var buffer = [CChar](repeating: 0, count: pidPathInfoMaxSize)
            let written = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
                proc_pidpath(pid, ptr.baseAddress, UInt32(ptr.count))
            }
            guard written > 0 else { return nil }
            let path = String(cString: buffer)
            return path.isEmpty ? nil : path
        }

        private static func commandName(from bsd: proc_bsdinfo) -> String {
            // `pbi_comm` is a fixed-length C tuple of `CChar` (`MAXCOMLEN+1`
            // bytes). Read through `withUnsafeBytes` for direct pointer
            // access, then append an explicit null terminator before handing
            // to `String(cString:)`. The kernel always null-terminates, but
            // the trailing zero costs nothing and prevents reading past the
            // tuple if a malformed record ever surfaces.
            withUnsafeBytes(of: bsd.pbi_comm) { rawBuffer -> String in
                var bytes = [UInt8](rawBuffer)
                bytes.append(0)
                return bytes.withUnsafeBufferPointer { ptr in
                    guard let base = ptr.baseAddress else { return "" }
                    return String(cString: base)
                }
            }
        }
    #endif

    // MARK: - User-name lookup

    /// Best-effort UID → user name lookup via `getpwuid_r`. Returns `nil` for
    /// UIDs the directory service doesn't know about; the caller falls back
    /// to the numeric UID.
    @Sendable
    public static func lookupUserName(uid: UInt32) -> String? {
        #if canImport(Darwin)
            var pwd = passwd()
            var resultPtr: UnsafeMutablePointer<passwd>?
            let bufferSize = Int(sysconf(Int32(_SC_GETPW_R_SIZE_MAX)).clampedToNonNegative())
            let actualSize = bufferSize > 0 ? bufferSize : 16_384
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: actualSize)
            defer { buffer.deallocate() }
            let rc = getpwuid_r(uid, &pwd, buffer, actualSize, &resultPtr)
            guard rc == 0, let entry = resultPtr else { return nil }
            return String(cString: entry.pointee.pw_name)
        #else
            return nil
        #endif
    }
}

private extension Int {
    /// `sysconf` returns `-1` when a limit is undetermined; clamping keeps the
    /// fallback path simple at the call site.
    func clampedToNonNegative() -> Int { self < 0 ? 0 : self }
}
