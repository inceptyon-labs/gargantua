import Darwin

/// Every process's PID and executable path, read through `proc_listpids` and
/// `proc_pidpath`. Processes the caller can't introspect are left out.
enum ProcessTable {
    static func pids() -> [Int32] {
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

    static func executablePath(for pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: pidPathInfoMaxSize)
        let written = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            proc_pidpath(pid, ptr.baseAddress, UInt32(ptr.count))
        }
        guard written > 0 else { return nil }
        // Not a Data conversion; decoding a NUL-padded CChar buffer.
        // swiftlint:disable:next optional_data_string_conversion
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.isEmpty ? nil : path
    }
}
