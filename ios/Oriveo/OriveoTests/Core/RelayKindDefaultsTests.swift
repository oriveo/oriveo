import Foundation
import Testing
@testable import Oriveo

@Suite("Relay kind defaults contract")
struct RelayKindDefaultsTests {

    @Test("custom default falls back to OpenAI Chat Completions and bearer")
    func customDefaultFallback() {
        let requested = RelayKindDefaults.makeRequested(for: .custom)

        #expect(requested.transport == .openaiChatCompletions)
        #expect(requested.authMode == .bearer)
        #expect(requested.stream == true)
        #expect(requested.reasoningEffort == .automatic)
    }

    @Test("relay endpoint policy accepts secure LAN and VPN addresses")
    func endpointPolicyAcceptsSecureLanAndVpnAddresses() {
        #expect(RelaySetupView.normalizedRelayEndpoint("relay.example.com/v1") == "https://relay.example.com/v1")
        #expect(RelaySetupView.normalizedRelayEndpoint(" https://relay.example.com/v1/ ") == "https://relay.example.com/v1")
        #expect(RelaySetupView.normalizedRelayEndpoint("https://192.168.1.20:8443/v1") == "https://192.168.1.20:8443/v1")
        #expect(RelaySetupView.normalizedRelayEndpoint("relay.local/v1") == "https://relay.local/v1")
        #expect(RelaySetupView.normalizedRelayEndpoint("relay.corp-vpn.example/v1") == "https://relay.corp-vpn.example/v1")
    }

    @Test("relay endpoint policy rejects insecure and credential-bearing addresses")
    func endpointPolicyRejectsUnsafeAddresses() {
        #expect(RelaySetupView.normalizedRelayEndpoint("http://192.168.1.20:8080/v1") == nil)
        #expect(RelaySetupView.normalizedRelayEndpoint("ftp://relay.example.com") == nil)
        #expect(RelaySetupView.normalizedRelayEndpoint("https://user:secret@relay.example.com/v1") == nil)
        #expect(RelaySetupView.normalizedRelayEndpoint("https://") == nil)
        #expect(RelaySetupView.normalizedRelayEndpoint("   ") == nil)
    }

    @Test("relay kind picker keeps provider examples out of the main choice cards")
    func pickerCardsDoNotExposeRelayBrandExamples() {
        #expect(RelayKindMeta.meta(for: .openaiCompatible).examples == nil)
        #expect(RelayKindMeta.meta(for: .codexStyle).examples == nil)
        #expect(RelayKindMeta.meta(for: .codexStyle).warning == nil)
        #expect(!RelayKindMeta.meta(for: .codexStyle).title.localizedCaseInsensitiveContains("Codex"))
        #expect(RelayKindMeta.meta(for: .openaiCompatible).endpointPath == "/v1/chat/completions")
        #expect(RelayKindMeta.meta(for: .codexStyle).endpointPath == "/v1/responses")
    }
}
