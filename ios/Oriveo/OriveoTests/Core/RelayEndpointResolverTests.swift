import Foundation
import Testing
@testable import Oriveo

@Suite("Relay endpoint resolver")
struct RelayEndpointResolverTests {
    @Test("host input prefers the protocol default version then a versionless fallback")
    func hostCandidates() throws {
        let descriptor = try RelayEndpointResolver.describe("relay.example.com")
        let candidates = RelayEndpointResolver.candidates(
            for: descriptor,
            transport: .openaiChatCompletions
        )

        #expect(descriptor.origin == "https://relay.example.com")
        #expect(descriptor.pathPrefix.isEmpty)
        #expect(descriptor.explicitVersion == nil)
        #expect(candidates.map(\.apiBaseURL) == [
            "https://relay.example.com/v1",
            "https://relay.example.com"
        ])
    }

    @Test("proxy prefix and explicit version are preserved")
    func proxyPrefixAndVersion() throws {
        let descriptor = try RelayEndpointResolver.describe(
            "https://relay.example.com/proxy/openai/v1"
        )
        let candidates = RelayEndpointResolver.candidates(
            for: descriptor,
            transport: .openaiResponses
        )

        #expect(descriptor.pathPrefix == "/proxy/openai")
        #expect(descriptor.explicitVersion == "v1")
        #expect(candidates.map(\.apiBaseURL) == [
            "https://relay.example.com/proxy/openai/v1",
            "https://relay.example.com/proxy/openai"
        ])
    }

    @Test("full OpenAI endpoint is reduced to its exact API root without duplicate paths")
    func fullOpenAIEndpoint() throws {
        let descriptor = try RelayEndpointResolver.describe(
            "https://relay.example.com/proxy/v1/chat/completions"
        )
        let candidate = try #require(
            RelayEndpointResolver.candidates(
                for: descriptor,
                transport: .openaiChatCompletions
            ).first
        )
        let url = try RelayEndpointResolver.endpointURL(
            apiBaseURL: candidate.apiBaseURL,
            endpointPath: "/chat/completions"
        )

        #expect(descriptor.explicitTransport == .openaiChatCompletions)
        #expect(candidate.apiBaseURL == "https://relay.example.com/proxy/v1")
        #expect(url.absoluteString == "https://relay.example.com/proxy/v1/chat/completions")
    }

    @Test("explicit versionless full endpoint is tried before adding v1")
    func explicitVersionlessEndpoint() throws {
        let descriptor = try RelayEndpointResolver.describe(
            "https://relay.example.com/proxy/responses"
        )
        let candidates = RelayEndpointResolver.candidates(
            for: descriptor,
            transport: .openaiResponses
        )

        #expect(descriptor.explicitTransport == .openaiResponses)
        #expect(candidates.map(\.apiBaseURL) == [
            "https://relay.example.com/proxy",
            "https://relay.example.com/proxy/v1"
        ])
        #expect(candidates.first?.evidence == .explicitRoute)
    }

    @Test("Gemini keeps an explicit v1 first and then tries v1beta and versionless")
    func geminiVersionCandidates() throws {
        let descriptor = try RelayEndpointResolver.describe("https://relay.example.com/gemini/v1")
        let candidates = RelayEndpointResolver.candidates(
            for: descriptor,
            transport: .geminiGenerateContent
        )

        #expect(candidates.map(\.apiBaseURL) == [
            "https://relay.example.com/gemini/v1",
            "https://relay.example.com/gemini/v1beta",
            "https://relay.example.com/gemini"
        ])
    }

    @Test("full Gemini generateContent endpoint is reduced to v1beta API root")
    func fullGeminiEndpoint() throws {
        let descriptor = try RelayEndpointResolver.describe(
            "https://relay.example.com/v1beta/models/gemini-2.5-pro:generateContent"
        )

        #expect(descriptor.explicitTransport == .geminiGenerateContent)
        #expect(descriptor.explicitVersion == "v1beta")
        #expect(descriptor.pathPrefix.isEmpty)
    }

    @Test("resolved API root is the runtime authority, including versionless roots")
    func resolvedAPIRootWinsAtRuntime() throws {
        let requested = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .bearer,
            resolvedAPIBaseURL: "https://relay.example.com/proxy"
        )
        let result = try RelayEndpointResolver.runtimeAPIBaseURL(
            rawBaseURL: "https://relay.example.com/proxy/v1/chat/completions",
            relayRequested: requested,
            defaultVersion: "v1",
            acceptedVersions: ["v1"]
        )

        #expect(result == "https://relay.example.com/proxy")
    }

    @Test("embedded query and fragment are detected for setup security handling")
    func embeddedQueryAndFragment() throws {
        let descriptor = try RelayEndpointResolver.describe(
            "https://relay.example.com/v1?tenant=a#section"
        )

        #expect(descriptor.containsEmbeddedQuery)
        #expect(descriptor.containsFragment)
    }
}
