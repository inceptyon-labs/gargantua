import Foundation

/// Exposes helper-binary resolution for release smoke tests without launching
/// a full scan.
public enum VendoredBinarySelfCheck {
    public static func resolveLines(
        fclonesResolver: FclonesBinaryResolver = FclonesBinaryResolver(),
        czkawkaResolver: CzkawkaBinaryResolver = CzkawkaBinaryResolver()
    ) throws -> [String] {
        let fclones = try fclonesResolver.resolve()
        let czkawka = try czkawkaResolver.resolve()

        return [
            "fclones: \(fclones.path)",
            "czkawka_cli: \(czkawka.path)",
        ]
    }
}
