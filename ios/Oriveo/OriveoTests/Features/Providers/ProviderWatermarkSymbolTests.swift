import Testing
@testable import Oriveo

@Suite("Provider Watermark Symbol Tests")
struct ProviderWatermarkSymbolTests {

    @Test("Unified Provider Assets Are Not Opaque Tiles")
    func unifiedProviderAssetsAreNotOpaqueTiles() {
        let officialKinds = ProviderKind.allCases.filter { ![.relay, .openAI, .openAI].contains($0) }
        #expect(officialKinds.allSatisfy { !$0.brandLogoIsOpaqueTile })
    }

    @Test("Watermark Symbols Pass Through")
    func watermarkSymbolsPassThrough() {
        for kind in ProviderKind.allCases {
            #expect(kind.brandWatermarkSymbol == kind.menuSystemImage)
        }
    }
}
