import CoreGraphics
import Testing
@testable import GargantuaCore

@Suite("DiskTreemapLayout")
struct DiskTreemapLayoutTests {
    @Test("positive-sized items receive proportional rectangle areas")
    func positiveItemsUseProportionalAreas() {
        let items = [
            makeItem("large", size: 300),
            makeItem("small", size: 100),
        ]
        let tiles = DiskTreemapLayout.tiles(
            for: items,
            in: CGRect(x: 0, y: 0, width: 400, height: 100)
        )

        #expect(tiles.count == 2)
        #expect(abs(area(of: tiles[0]) - 30_000) < 0.001)
        #expect(abs(area(of: tiles[1]) - 10_000) < 0.001)
    }

    @Test("recursive layout fills the full container area")
    func recursiveLayoutFillsContainer() {
        let items = [
            makeItem("a", size: 8),
            makeItem("b", size: 4),
            makeItem("c", size: 2),
            makeItem("d", size: 2),
        ]
        let bounds = CGRect(x: 0, y: 0, width: 240, height: 180)
        let tiles = DiskTreemapLayout.tiles(for: items, in: bounds)
        let totalArea = tiles.reduce(0.0) { $0 + area(of: $1) }

        #expect(tiles.count == 4)
        #expect(abs(totalArea - Double(bounds.width * bounds.height)) < 0.001)
        #expect(tiles.allSatisfy { bounds.contains($0.rect) })
    }

    @Test("all zero-sized items are allocated equal visible areas")
    func allZeroSizedItemsSplitEqually() {
        let items = [
            makeItem("empty-a", size: 0),
            makeItem("empty-b", size: 0),
        ]
        let tiles = DiskTreemapLayout.tiles(
            for: items,
            in: CGRect(x: 0, y: 0, width: 120, height: 80)
        )

        #expect(tiles.count == 2)
        #expect(abs(area(of: tiles[0]) - area(of: tiles[1])) < 0.001)
        #expect(area(of: tiles[0]) > 0)
    }

    @Test("permission-denied zero-size items remain visible beside sized siblings")
    func permissionDeniedItemsGetAffordanceArea() {
        let items = [
            makeItem("known", size: 1_000),
            makeItem("blocked", size: 0, isPermissionDenied: true),
        ]
        let tiles = DiskTreemapLayout.tiles(
            for: items,
            in: CGRect(x: 0, y: 0, width: 300, height: 100)
        )
        let blocked = tiles.first { $0.item.name == "blocked" }

        #expect(blocked != nil)
        #expect((blocked.map(area) ?? 0) > 0)
    }

    @Test("empty input and empty bounds produce no tiles")
    func emptyInputsProduceNoTiles() {
        let item = makeItem("a", size: 1)

        #expect(DiskTreemapLayout.tiles(for: [], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        #expect(DiskTreemapLayout.tiles(for: [item], in: .zero).isEmpty)
    }

    private func makeItem(
        _ name: String,
        size: Int64,
        isPermissionDenied: Bool = false
    ) -> DirectoryItem {
        DirectoryItem(
            name: name,
            path: "/tmp/\(name)",
            size: size,
            isPermissionDenied: isPermissionDenied
        )
    }

    private func area(of tile: DiskTreemapTile) -> Double {
        Double(tile.rect.width * tile.rect.height)
    }
}
