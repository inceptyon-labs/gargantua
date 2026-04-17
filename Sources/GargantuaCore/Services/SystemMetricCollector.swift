import Foundation
import OSLog

#if canImport(Darwin)
import Darwin
#endif

private let logger = Logger(subsystem: "com.gargantua.core", category: "SystemMetricCollector")

/// Collects live system metrics (CPU, memory, disk, thermal) using native macOS APIs.
///
/// Usage:
/// ```swift
/// let collector = SystemMetricCollector()
/// let metrics = await collector.collect()
/// print("Health: \(metrics.healthScore)")
/// ```
public struct SystemMetricCollector: Sendable {
    public init() {}

    /// Collect a snapshot of current system metrics.
    ///
    /// All underlying queries (Mach host APIs, FileManager) are fast and
    /// synchronous; kept `async` so callers remain unchanged and so future
    /// metric sources (e.g. disk-backed history) can be added without a
    /// breaking API change.
    public func collect() async -> SystemMetrics {
        let cpu = collectCPU()
        let mem = collectMemory()
        let disk = collectDisk()
        let thermal = collectThermal()

        return SystemMetrics(
            cpuUsage: cpu,
            memoryPressure: mem.pressure,
            memoryTotal: mem.total,
            memoryUsed: mem.used,
            diskUsage: disk.usage,
            diskTotal: disk.total,
            diskUsed: disk.used,
            diskFree: disk.free,
            thermalLevel: thermal
        )
    }

    // MARK: - CPU

    /// CPU usage via Mach `host_processor_info`.
    ///
    /// Returns aggregate usage across all cores as a 0.0–1.0 fraction.
    private func collectCPU() -> Double {
        #if canImport(Darwin)
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCPUInfo
        )

        guard result == KERN_SUCCESS, let info = cpuInfo else {
            logger.warning("host_processor_info failed (\(result))")
            return 0
        }

        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(Int(numCPUInfo) * MemoryLayout<integer_t>.size)
            )
        }

        var totalUser: Double = 0
        var totalSystem: Double = 0
        var totalIdle: Double = 0
        var totalNice: Double = 0

        for i in 0..<Int(numCPUs) {
            let offset = Int(CPU_STATE_MAX) * i
            totalUser += Double(info[offset + Int(CPU_STATE_USER)])
            totalSystem += Double(info[offset + Int(CPU_STATE_SYSTEM)])
            totalIdle += Double(info[offset + Int(CPU_STATE_IDLE)])
            totalNice += Double(info[offset + Int(CPU_STATE_NICE)])
        }

        let totalTicks = totalUser + totalSystem + totalIdle + totalNice
        guard totalTicks > 0 else { return 0 }

        let usage = (totalUser + totalSystem) / totalTicks
        logger.debug("CPU usage: \(String(format: "%.1f", usage * 100))%")
        return usage
        #else
        return 0
        #endif
    }

    // MARK: - Memory

    private struct MemoryInfo {
        let pressure: Double
        let total: UInt64
        let used: UInt64
    }

    /// Memory usage via Mach `host_statistics64`.
    private func collectMemory() -> MemoryInfo {
        #if canImport(Darwin)
        let total = UInt64(ProcessInfo.processInfo.physicalMemory)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            logger.warning("host_statistics64 failed (\(result))")
            return MemoryInfo(pressure: 0, total: total, used: 0)
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let used = active + wired + compressed

        let pressure = total > 0 ? Double(used) / Double(total) : 0
        logger.debug("Memory: \(used / 1_073_741_824)GB / \(total / 1_073_741_824)GB (\(String(format: "%.1f", pressure * 100))%)")

        return MemoryInfo(pressure: pressure, total: total, used: used)
        #else
        return MemoryInfo(pressure: 0, total: 0, used: 0)
        #endif
    }

    // MARK: - Disk

    private struct DiskInfo {
        let usage: Double
        let total: UInt64
        let used: UInt64
        let free: UInt64
    }

    /// Disk usage via `FileManager.attributesOfFileSystem`.
    private func collectDisk() -> DiskInfo {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: "/")
            let total = (attrs[.systemSize] as? NSNumber).map { UInt64($0.uint64Value) } ?? 0
            let free = (attrs[.systemFreeSize] as? NSNumber).map { UInt64($0.uint64Value) } ?? 0
            let used = total > free ? total - free : 0
            let usage = total > 0 ? Double(used) / Double(total) : 0

            logger.debug("Disk: \(used / 1_073_741_824)GB / \(total / 1_073_741_824)GB (\(String(format: "%.1f", usage * 100))%)")
            return DiskInfo(usage: usage, total: total, used: used, free: free)
        } catch {
            logger.warning("FileManager disk query failed: \(error.localizedDescription)")
            return DiskInfo(usage: 0, total: 0, used: 0, free: 0)
        }
    }

    // MARK: - Thermal

    /// Thermal state via `ProcessInfo.thermalState`.
    private func collectThermal() -> ThermalLevel {
        let state = ProcessInfo.processInfo.thermalState
        let level = ThermalLevel(from: state)
        logger.debug("Thermal: \(level.rawValue)")
        return level
    }
}
