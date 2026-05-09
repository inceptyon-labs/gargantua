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

    /// Render a byte count using `ByteCountFormatter`'s memory style — KB / MB / GB.
    public static func bytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        formatter.countStyle = .memory
        formatter.includesUnit = true
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }
}
