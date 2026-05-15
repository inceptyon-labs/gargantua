import Testing
@testable import GargantuaCore

@Suite("CodexModelCatalog")
struct CodexModelCatalogTests {
    @Test("Baked-in list has distinct IDs and non-empty display names")
    func bakedInListIsValid() {
        let ids = Set(CodexModelCatalog.bakedInModels.map(\.id))
        #expect(ids.count == CodexModelCatalog.bakedInModels.count)
        for model in CodexModelCatalog.bakedInModels {
            #expect(!model.id.isEmpty)
            #expect(!model.displayName.isEmpty)
        }
    }

    @Test("First entry is the newest tier (display order is newest-first)")
    func newestFirst() {
        let first = CodexModelCatalog.bakedInModels.first
        #expect(first?.id == "gpt-5.5")
    }
}
