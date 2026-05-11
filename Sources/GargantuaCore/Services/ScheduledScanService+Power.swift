import Foundation
#if os(macOS)
    import IOKit.ps
#endif

/// Supplies whether the system is currently using battery power.
public protocol ScheduledScanPowerStateProviding: Sendable {
    /// Returns whether the system is currently running on battery power.
    func isOnBatteryPower() -> Bool
}

/// Power-state provider backed by macOS IOKit power source APIs.
public struct SystemScheduledScanPowerStateProvider: ScheduledScanPowerStateProviding {
    /// Creates the default system power-state provider.
    public init() {}

    /// Returns whether any active power source reports battery power.
    public func isOnBatteryPower() -> Bool {
        #if os(macOS)
            guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
                  let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
            else { return false }

            for source in list {
                guard let description = IOPSGetPowerSourceDescription(info, source)?
                    .takeUnretainedValue() as? [String: Any],
                    let state = description[kIOPSPowerSourceStateKey] as? String
                else { continue }

                if state == kIOPSBatteryPowerValue {
                    return true
                }
            }
        #endif
        return false
    }
}
