import Foundation

extension RemnantItem {
    /// Project this remnant into the generic `ScanResult` shape used by
    /// confirmation modals, the cleanup engine, and audit writers.
    public func toScanResult() -> ScanResult {
        ScanResult(
            id: id,
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            size: size,
            safety: safety,
            confidence: confidence,
            explanation: explanation,
            source: source,
            lastAccessed: lastAccessed,
            category: category.rawValue,
            tags: tags,
            regenerates: regenerates
        )
    }
}
