import Foundation

/// Number-formatting helpers shared between `ProcessInventoryRow` and the
/// view footer. Pulled into its own file to keep the row body under
/// SwiftLint's `file_length` cap.
public enum ProcessInventoryFormat {
    /// Render a CPU fraction as a percentage of one core. Two-thread workloads
    /// can exceed 100 %; truncating below 0.05 % avoids row-thrash for idle
    /// items.
    public static func cpu(_ fraction: Double) -> String {
        let clamped = max(0, fraction)
        let percent = clamped * 100
        if percent >= 100 {
            return String(format: "%.0f%%", percent)
        }
        if percent >= 10 {
            return String(format: "%.1f%%", percent)
        }
        if percent < 0.05 {
            return "0%"
        }
        return String(format: "%.2f%%", percent)
    }

    /// Shared memory-style formatter. Building a `ByteCountFormatter` per call
    /// churned an allocation on every row body eval while scrolling the
    /// inventory list; the formatter is only read from MainActor row bodies, so
    /// one shared instance is safe.
    @MainActor private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        formatter.countStyle = .memory
        formatter.includesUnit = true
        formatter.zeroPadsFractionDigits = false
        return formatter
    }()

    /// Render a byte count using `ByteCountFormatter`'s memory style — KB / MB / GB.
    @MainActor public static func bytes(_ bytes: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }
}
