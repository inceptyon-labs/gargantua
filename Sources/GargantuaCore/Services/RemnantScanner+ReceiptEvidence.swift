import Foundation

/// `pkgutil`-receipt evidence integration for `RemnantScanner`.
///
/// Lives in an extension file so the receipt-expansion code can grow without
/// pushing `RemnantScanner.swift` past its lint threshold and so the
/// integration stays mechanically separable from the YAML-rule pipeline.
public extension RemnantScanner {
    /// Return a copy of this scanner with `pkgutil` receipt expansion
    /// enabled. Candidate paths pass through `ReceiptRemnantBuilder` and are
    /// appended to the regular YAML-rule remnants, deduped against the rule
    /// output so the same path is never emitted twice.
    func withReceiptEvidence(
        expander: PackageReceiptExpander,
        builder: ReceiptRemnantBuilder = ReceiptRemnantBuilder()
    ) -> RemnantScanner {
        RemnantScanner(
            rules: rules,
            scanRoots: scanRoots,
            expander: self.expander,
            receiptExpander: expander,
            receiptBuilder: builder,
            observer: observer
        )
    }
}

extension RemnantScanner {
    /// Append receipt-evidence remnants to `remnants` for `app`, updating
    /// `seenPaths` so paths already emitted by the YAML rule pass are not
    /// duplicated as BOM evidence.
    func appendReceiptEvidence(
        into remnants: inout [RemnantItem],
        seenPaths: inout Set<String>,
        for app: AppInfo
    ) {
        guard let receiptExpander, let receiptBuilder else { return }

        let candidates = receiptExpander.expand(for: app)
        let receiptItems = receiptBuilder.build(
            from: candidates,
            for: app,
            seenPaths: &seenPaths
        )
        for item in receiptItems {
            remnants.append(item)
            observer?.didEmit(ScanProgressEvent(
                path: item.path,
                outcome: .match,
                bytes: item.size
            ))
        }
    }
}
