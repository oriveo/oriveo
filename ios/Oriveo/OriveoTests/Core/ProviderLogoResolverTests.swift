import Foundation
import Testing
@testable import Oriveo

@Suite("ProviderLogoResolver")
@MainActor
struct ProviderLogoResolverTests {
    /// The hero card reads the logo a dozen times per body and re-reads it on every providers write.
    /// Unchanged inference inputs must not re-run the substring search, and any changed input must
    /// recompute immediately instead of returning the previous logo.
    @Test("relay logo inference is memoized by its inputs and recomputes when any of them change")
    func relayLogoResolverRecomputesOnlyWhenInputsChange() {
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: [TestFactories.makeModel(id: "gpt-4o", name: "GPT-4o")],
            baseURLText: "https://relay.example.com/v1",
            customName: "Work Relay"
        )
        provider.relayKind = .custom
        let id = provider.id

        #expect(ProviderLogoResolver.logoKind(for: provider) == .openAI)
        for _ in 0..<10 {
            #expect(ProviderLogoResolver.logoKind(for: provider) == .openAI)
        }
        // Same shape as a providers write: unrelated fields change, models keep their storage.
        provider.lastCheckedAt = Date()
        provider.status = .syncing
        #expect(ProviderLogoResolver.logoKind(for: provider) == .openAI)
        #expect(ProviderLogoResolver.computationCountForTesting(providerID: id) == 1)

        // Equal contents in fresh storage (for example decoded again from disk): same result.
        provider.models = provider.models.map { $0 }
        #expect(ProviderLogoResolver.logoKind(for: provider) == .openAI)

        provider.models = [TestFactories.makeModel(id: "claude-sonnet-4", name: "Claude Sonnet 4")]
        #expect(ProviderLogoResolver.logoKind(for: provider) == .anthropic)

        provider.customName = "DeepSeek Gateway"
        #expect(ProviderLogoResolver.logoKind(for: provider) == .anthropic)
        provider.models = []
        #expect(ProviderLogoResolver.logoKind(for: provider) == .deepseek)

        provider.customName = nil
        provider.baseURLText = "https://api.moonshot.cn/v1"
        #expect(ProviderLogoResolver.logoKind(for: provider) == .moonshot)

        provider.baseURLText = "https://relay.example.com/v1"
        #expect(ProviderLogoResolver.logoKind(for: provider) == .relay)
        provider.relayKind = .geminiCompatible
        #expect(ProviderLogoResolver.logoKind(for: provider) == .gemini)

        // One initial inference plus six real input changes; equal contents in new storage do not count.
        #expect(ProviderLogoResolver.computationCountForTesting(providerID: id) == 7)
    }

    /// A relay whose name or address mentions the app itself says nothing about the upstream
    /// vendor, so it must fall back to the relay's protocol instead of borrowing a vendor logo.
    @Test("a relay that mentions the app name keeps its own fallback logo")
    func relayMentioningAppNameKeepsFallbackLogo() {
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: [],
            baseURLText: "https://oriveo-relay.example.com/v1",
            customName: "Oriveo Home Relay"
        )
        provider.relayKind = .custom
        #expect(ProviderLogoResolver.logoKind(for: provider) == .relay)

        provider.relayKind = .anthropicCompatible
        #expect(ProviderLogoResolver.logoKind(for: provider) == .anthropic)
    }
}
