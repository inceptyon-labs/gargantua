import Foundation
import OSLog

#if canImport(Darwin)
import Darwin
#endif

private let logger = Logger(subsystem: "com.gargantua.core", category: "SystemMetricCollector")

/// Collects live system metrics (CPU, memory, disk, thermal) using native macOS APIs.
///
/// Falls back to `mo status` via `MoleRunner` when native APIs are unavailable
/// (e.g., sandboxed environments that restrict Mach host ports).
///
/// Usage:
/// ```swift
/// let collector = SystemMetricCollector()
/// let metrics = try await collector.collect()
/// print("Health: \(metrics.healthScore)")
/// ```
public struct SystemMetricCollector: Sendable {
    private let runner: MoleRunner?

    /// Create a collector.
    ///
    /// - Parameter runner: Optional `MoleRunner` for `mo status` fallback.
    ///   Pass `nil` to use native APIs only (no fallback on failure).
    public init(runner: MoleRunner? = nil) {
        self.runner = runner
    }

    /// Collect a snapshot of current system metrics.
    public func collect() async throws -> SystemMetrics {
        async let cpu = collectCPU()
        async let mem = collectMemory()
        async let disk = collectDisk()
        let thermal = collectThermal()

        let (cpuResult, memResult, diskResult) = try await (cpu, mem, disk)

        return SystemMetrics(
            cpuUsage: cpuResult,
            memoryPressure: memResult.pressure,
            memoryTotal: memResult.total,
            memoryUsed: memResult.used,
            diskUsage: diskResult.usage,
            diskTotal: diskResult.total,
            diskUsed: diskResult.used,
            diskFree: diskResult.free,
            thermalLevel: thermal
        )
    }

    // MARK: - CPU

    /// CPU usage via Mach `host_processor_info`.
    ///
    /// Returns aggregate usage across all cores as a 0.0–1.0 fraction.
    private func collectCPU() async throws -> Double {
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
            logger.warning("host_processor_info failed (\(result)), falling back to mo status")
            return try await cpuFromMoStatus()
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
        return try await cpuFromMoStatus()
        #endif
    }

    // MARK: - Memory

    private struct MemoryInfo {
        let pressure: Double
        let total: UInt64
        let used: UInt64
    }

    /// Memory usage via Mach `host_statistics64`.
    private func collectMemory() async throws -> MemoryInfo {
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
            logger.warning("host_statistics64 failed (\(result)), falling back to mo status")
            return try await memoryFromMoStatus()
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
        return try await memoryFromMoStatus()
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
    private func collectDisk() async throws -> DiskInfo {
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
            return try await diskFromMoStatus()
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

    // MARK: - mo status Fallbacks

    private func cpuFromMoStatus() async throws -> Double {
        let json = try await runMoStatus()
        guard let cpu = json["cpu_usage"] as? Double else {
            logger.error("mo status missing cpu_usage field")
            return 0
        }
        // mo status returns percentage (0-100), convert to fraction
        return cpu / 100.0
    }

    private func memoryFromMoStatus() async throws -> MemoryInfo {
        let json = try await runMoStatus()
        let total = (json["memory_total"] as? NSNumber).map { UInt64($0.uint64Value) } ?? 0
        let used = (json["memory_used"] as? NSNumber).map { UInt64($0.uint64Value) } ?? 0
        let pressure = total > 0 ? Double(used) / Double(total) : 0
        return MemoryInfo(pressure: pressure, total: total, used: used)
    }

    private func diskFromMoStatus() async throws -> DiskInfo {
        let json = try await runMoStatus()
        let total = (json["disk_total"] as? NSNumber).map { UInt64($0.uint64Value) } ?? 0
        let free = (json["disk_free"] as? NSNumber).map { UInt64($0.uint64Value) } ?? 0
        let used = total > free ? total - free : 0
        let usage = total > 0 ? Double(used) / Double(total) : 0
        return DiskInfo(usage: usage, total: total, used: used, free: free)
    }

    /// Run `mo status --json` and parse the response.
    private func runMoStatus() async throws -> [String: Any] {
        guard let runner else {
            throw MetricCollectionError.noFallbackAvailable
        }

        let result = try await runner.run(command: "status", arguments: ["--json"])
        guard let json = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw MetricCollectionError.invalidMoStatusOutput
        }
        return json
    }
}

// MARK: - Errors

/// Errors specific to metric collection.
public enum MetricCollectionError: Error, LocalizedError, Sendable {
    case noFallbackAvailable
    case invalidMoStatusOutput

    public var errorDescription: String? {
        switch self {
        case .noFallbackAvailable:
            "Native metric collection failed and no MoleRunner fallback is configured"
        case .invalidMoStatusOutput:
            "Failed to parse mo status output as JSON"
        }
    }
}
