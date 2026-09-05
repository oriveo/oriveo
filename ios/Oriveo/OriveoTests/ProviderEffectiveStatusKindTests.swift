import Foundation
import Testing
@testable import Oriveo

@Suite("Provider effective status derivation")
struct ProviderEffectiveStatusKindTests {
    private func decodedRequested(_ json: String) throws -> RelayRequestedConfig {
        try JSONDecoder().decode(RelayRequestedConfig.self, from: Data(json.utf8))
    }

    private func keylessRelay(baseURL: String) -> Provider {
        Provider(
            id: UUID(), kind: .relay, status: .connected,
            models: [], catalogModels: [],
            apiKey: "", apiKeyPreview: "",
            baseURLText: baseURL
        )
    }

    @Test("Local Engine Empty Key Is Not Needs Key")
    func localEngineEmptyKeyIsNotNeedsKey() throws {
        var provider = keylessRelay(baseURL: "http://192.168.31.250:1234")
        provider.relayRequested = try decodedRequested(
            #"{"transport":"openai_chat_completions","authMode":"none","securityMode":"local_http","engineProfile":"lmstudio"}"#
        )
        #expect(provider.effectiveStatusKind == .connected)
    }

    @Test("Manual Keyless Relay Is Not Needs Key")
    func manualKeylessRelayIsNotNeedsKey() throws {
        var provider = keylessRelay(baseURL: "https://relay.example.com/v1")
        provider.relayRequested = try decodedRequested(
            #"{"transport":"openai_chat_completions","authMode":"none","securityMode":"remote_https"}"#
        )
        #expect(provider.effectiveStatusKind == .connected)
    }

    @Test("Cloud Relay Empty Key Stays Needs Key")
    func cloudRelayEmptyKeyStaysNeedsKey() throws {
        var provider = keylessRelay(baseURL: "https://api.example.com/v1")
        provider.relayRequested = try decodedRequested(
            #"{"transport":"openai_chat_completions","authMode":"bearer","securityMode":"remote_https"}"#
        )
        #expect(provider.effectiveStatusKind == .needsKey)

        var legacy = keylessRelay(baseURL: "https://api.example.com/v1")
        legacy.relayRequested = try decodedRequested(#"{"transport":"auto"}"#)
        #expect(legacy.effectiveStatusKind == .needsKey)
    }

    @Test("Official Provider Empty Key Stays Needs Key")
    func officialProviderEmptyKeyStaysNeedsKey() {
        let provider = Provider(
            id: UUID(), kind: .openAI, status: .connected,
            models: [], catalogModels: [],
            apiKey: "", apiKeyPreview: "",
            baseURLText: nil
        )
        #expect(provider.effectiveStatusKind == .needsKey)
    }
}
