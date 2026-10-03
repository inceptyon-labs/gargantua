import Foundation
import Testing
@testable import GargantuaCore

@Suite("UTF8ChunkDecoder")
struct UTF8ChunkDecoderTests {
    @Test("Splitting a multi-byte character across chunks loses nothing, at any split point")
    func splitAnywhereRoundTrips() {
        let text = "naïve 🚀 café — ok"
        let bytes = Data(text.utf8)
        for split in 0 ... bytes.count {
            let decoder = UTF8ChunkDecoder()
            let first = decoder.decode(bytes.prefix(split))
            let second = decoder.decode(bytes.suffix(from: split), isFinal: true)
            #expect(first + second == text, "split at \(split)")
        }
    }
}
