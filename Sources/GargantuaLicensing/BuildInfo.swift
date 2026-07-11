import Foundation

/// Compile-time build flavor. The GARGANTUA_LICENSING define only exists in
/// this target, so UI code elsewhere reads it through this flag.
public enum GargantuaBuildInfo {
    public static let isLicensedBuild: Bool = {
        #if GARGANTUA_LICENSING
            return true
        #else
            return false
        #endif
    }()
}
