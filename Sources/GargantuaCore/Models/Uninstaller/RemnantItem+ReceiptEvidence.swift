import Foundation

/// Receipt-evidence accessors for `RemnantItem`.
///
/// Pure derivation from existing fields (`tags`, `ruleID`) populated by
/// `ReceiptRemnantBuilder` — the model itself stays provenance-agnostic and
/// the UI doesn't have to reach into the builder's tag literal.
extension RemnantItem {
    /// True when this row was discovered via a `pkgutil` BOM expansion.
    public var isReceiptEvidence: Bool {
        tags.contains(ReceiptRemnantBuilder.receiptTag)
    }

    /// Reverse-DNS package ID that owns this path, or `nil` when the row
    /// did not come from `ReceiptRemnantBuilder`.
    ///
    /// `ReceiptRemnantBuilder` formats `ruleID` as `"pkgutil-bom:<pkgID>"`;
    /// this strips the prefix so the UI can render the package identifier
    /// in monospace next to the path.
    public var receiptPkgID: String? {
        guard isReceiptEvidence else { return nil }
        let prefix = "\(ReceiptRemnantBuilder.receiptTag):"
        guard ruleID.hasPrefix(prefix) else { return nil }
        let pkgID = String(ruleID.dropFirst(prefix.count))
        return pkgID.isEmpty ? nil : pkgID
    }
}
