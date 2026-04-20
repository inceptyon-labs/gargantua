import Foundation
import Testing
@testable import GargantuaCore

@Suite("DeveloperToolPreviewAdapter size parsing")
struct DeveloperToolPreviewAdapterParserTests {

    // MARK: - parseSize: well-formed

    @Test("parseSize handles MB/GB/TB within Int64 range")
    func parseSizeWellFormed() {
        #expect(DeveloperToolPreviewAdapter.parseSize("512MB") == Int64(512_000_000))
        #expect(DeveloperToolPreviewAdapter.parseSize("1.5 GB") == Int64(1_500_000_000))
        // Stay inside Double's 2^53 exactly-representable range so the
        // assertion doesn't become a test of IEEE 754 rounding behavior.
        #expect(DeveloperToolPreviewAdapter.parseSize("100 TB") == Int64(100_000_000_000_000))
        #expect(DeveloperToolPreviewAdapter.parseSize("0B") == Int64(0))
    }

    @Test("parseSize accepts large-but-fitting values without trapping")
    func parseSizeLargeFitsInInt64() {
        // 9999 TB ≈ 9.999e15, which sits above Double's 2^53 exact-integer
        // boundary. We don't assert the exact byte count — we assert that
        // the parser returns *some* Int64 (doesn't trap, doesn't clamp to nil).
        #expect(DeveloperToolPreviewAdapter.parseSize("9999 TB") != nil)
    }

    @Test("parseSize is case-insensitive for the unit")
    func parseSizeCaseInsensitive() {
        #expect(DeveloperToolPreviewAdapter.parseSize("10gb") == 10_000_000_000)
    }

    // MARK: - parseSize: boundary / overflow tokens

    @Test("parseSize returns nil when value * multiplier overflows Int64")
    func parseSizeOverflowClampsToNil() {
        // 99,999,999,999,999 * 1e12 == 9.9999e25 → way past Int64.max
        #expect(DeveloperToolPreviewAdapter.parseSize("99999999999999 TB") == nil)
        // Many-digit values (no scientific notation) also overflow safely.
        #expect(DeveloperToolPreviewAdapter.parseSize("9999999999999999999999 KB") == nil)
    }

    @Test("parseSize rejects tokens the regex can't match (scientific, negative, NaN)")
    func parseSizeRejectsMalformedTokens() {
        // Scientific notation isn't allowed by the parser regex.
        #expect(DeveloperToolPreviewAdapter.parseSize("1e308 MB") == nil)
        // Negative values never match \d+.
        #expect(DeveloperToolPreviewAdapter.parseSize("-5 MB") == nil)
        // NaN / Inf literals never match \d+.
        #expect(DeveloperToolPreviewAdapter.parseSize("NaN MB") == nil)
        #expect(DeveloperToolPreviewAdapter.parseSize("Inf MB") == nil)
        // Empty / garbage tokens.
        #expect(DeveloperToolPreviewAdapter.parseSize("") == nil)
        #expect(DeveloperToolPreviewAdapter.parseSize("huge") == nil)
    }

    // MARK: - parseFirstSize (homebrew line)

    @Test("parseFirstSize picks the first sized token in a brew cleanup line")
    func parseFirstSize() {
        let line = "Would remove: node@18 (512MB)"
        #expect(DeveloperToolPreviewAdapter.parseFirstSize(in: line) == 512_000_000)
    }

    @Test("parseFirstSize returns nil when overflowing token is the only match")
    func parseFirstSizeOverflow() {
        let line = "Would remove: runaway (99999999999999 TB)"
        #expect(DeveloperToolPreviewAdapter.parseFirstSize(in: line) == nil)
    }

    // MARK: - parseDockerReclaimable

    @Test("parseDockerReclaimable strips parenthesised suffix and parses")
    func parseDockerReclaimableStripsSuffix() {
        #expect(DeveloperToolPreviewAdapter.parseDockerReclaimable("2.5GB(100%)") == 2_500_000_000)
        #expect(DeveloperToolPreviewAdapter.parseDockerReclaimable("2.5GB") == 2_500_000_000)
    }

    @Test("parseDockerReclaimable returns nil on overflow")
    func parseDockerReclaimableOverflow() {
        #expect(DeveloperToolPreviewAdapter.parseDockerReclaimable("99999999999999TB(100%)") == nil)
    }

    // MARK: - DeveloperToolPreview.reclaimableBytes saturation

    @Test("reclaimableBytes saturates at Int64.max instead of trapping on sum overflow")
    func reclaimableBytesSaturatesOnSumOverflow() {
        let huge = DeveloperToolPreviewItem(
            id: "a",
            tool: .docker,
            title: "big",
            reclaimableBytes: Int64.max - 10,
            commandPreview: []
        )
        let alsoHuge = DeveloperToolPreviewItem(
            id: "b",
            tool: .docker,
            title: "also big",
            reclaimableBytes: Int64.max - 10,
            commandPreview: []
        )
        let preview = DeveloperToolPreview(
            tool: .docker,
            commandPreview: [],
            items: [huge, alsoHuge],
            rawOutput: ""
        )
        #expect(preview.reclaimableBytes == Int64.max)
    }

    @Test("reclaimableBytes still sums normally when under Int64.max")
    func reclaimableBytesSumsNormally() {
        let a = DeveloperToolPreviewItem(
            id: "a", tool: .homebrew, title: "a",
            reclaimableBytes: 1_000_000_000, commandPreview: []
        )
        let b = DeveloperToolPreviewItem(
            id: "b", tool: .homebrew, title: "b",
            reclaimableBytes: 2_000_000_000, commandPreview: []
        )
        let preview = DeveloperToolPreview(
            tool: .homebrew,
            commandPreview: [],
            items: [a, b],
            rawOutput: ""
        )
        #expect(preview.reclaimableBytes == 3_000_000_000)
    }

    @Test("reclaimableBytes is zero when no items carry a size")
    func reclaimableBytesZeroWhenNoSizes() {
        let item = DeveloperToolPreviewItem(
            id: "x", tool: .homebrew, title: "x",
            reclaimableBytes: nil, commandPreview: []
        )
        let preview = DeveloperToolPreview(
            tool: .homebrew,
            commandPreview: [],
            items: [item],
            rawOutput: ""
        )
        #expect(preview.reclaimableBytes == 0)
    }
}
