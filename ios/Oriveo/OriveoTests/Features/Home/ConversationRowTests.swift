import Testing
@testable import Oriveo

@Suite("ConversationRow", .serialized)
@MainActor
struct ConversationRowTests {
    private func withOpenAIMetadata<Result>(
        displayName: String = "GPT-4o Latest",
        _ operation: () async throws -> Result
    ) async throws -> Result {
        await MetadataClient.shared.resetForTesting()

        do {
            try await MetadataClient.shared.loadForTesting(json: """
            {
              "version": 1,
              "updatedAt": "2026-04-10T00:00:00Z",
              "providers": {
                "openAI": {
                  "displayName": "OpenAI",
                  "defaultModelId": "gpt-4o",
                  "resolveMap": {
                    "gpt-4o": "gpt-4o",
                    "gpt-4o-2024-08-06": "gpt-4o"
                  },
                  "models": {
                    "gpt-4o": {
                      "canonicalModelId": "gpt-4o",
                      "displayName": "\(displayName)"
                    }
                  }
                }
              }
            }
            """)

            let result = try await operation()
            await MetadataClient.shared.resetForTesting()
            return result
        } catch {
            await MetadataClient.shared.resetForTesting()
            throw error
        }
    }

    @Test("Resolved Model Name Avoids Catalog Projection")
    func resolvedModelNameAvoidsCatalogProjection() async throws {
        try await withOpenAIMetadata {
            let provider = TestFactories.makeProvider(
                kind: .openAI,
                models: [
                    TestFactories.makeModel(
                        id: "gpt-4o",
                        name: "GPT-4o Local",
                        canonicalModelId: "gpt-4o"
                    )
                ]
            )
            let conversation = TestFactories.makeConversation(
                providerID: provider.id,
                modelID: "gpt-4o-2024-08-06"
            )

            ProviderCatalogResolver.debugResolveCallCount = 0
            let resolvedModelName = ConversationRow.resolveModelName(
                for: conversation,
                provider: provider,
                metadata: MetadataClient.shared
            )

            #expect(resolvedModelName == "GPT-4o Latest")
            #expect(ProviderCatalogResolver.debugResolveCallCount == 0)
        }
    }
}
