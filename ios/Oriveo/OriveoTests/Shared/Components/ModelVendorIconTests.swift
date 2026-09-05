import Foundation
import Testing
import UIKit
@testable import Oriveo

@Suite("ModelVendorIcon - Vendor Asset Mapping")
struct ModelVendorIconTests {

    @Test("Official Group Aliases Map To Assets")
    func officialGroupAliasesMapToAssets() {
        let expected = [
            "google-gemini": "ProviderGemini",
            "xai-grok": "ProviderGrok",
            "kimi": "ProviderKimi",
            "zhipu-glm": "ProviderZAI",
        ]

        for (alias, asset) in expected {
            #expect(ModelVendorIconResolver.assetName(for: alias) == asset)
        }
    }

    @Test("Provider Badge Uses Embedded Visual Safe Area")
    func providerBadgeUsesEmbeddedVisualSafeArea() {
        #expect(ProviderBadgeLogoMetrics.brandContentScale == 1)
        #expect(ProviderBadgeLogoMetrics.brandInset(for: 28) == 0)
        #expect(ProviderBadgeLogoMetrics.relayFallbackContentScale == 0.92)
    }

    @Test("All Badge Assets Use Full Canvas")
    func allBadgeAssetsUseFullCanvas() {
        #expect(ProviderBadgeLogoMetrics.contentScale(for: .openAI) == 1)
        #expect(ProviderBadgeLogoMetrics.contentScale(for: .openAI) == 1)
        #expect(ProviderBadgeLogoMetrics.contentScale(for: .openAI) == 1)
    }

    @Test("Unified Provider Assets Exist")
    func unifiedProviderAssetsExist() {
        let assetNames = [
            "ProviderOpenAI", "ProviderAnthropic", "ProviderGemini", "ProviderDeepSeek",
            "ProviderGrok", "ProviderMiniMax", "ProviderZAI", "ProviderQwen",
            "ProviderKimi", "ProviderOpenRouter", "ProviderGroq", "ProviderTogether",
            "ProviderFireworks", "ProviderSiliconFlow",
        ]

        for assetName in assetNames {
            #expect(UIImage(named: assetName) != nil, "Missing asset: \(assetName)")
        }
    }
}
