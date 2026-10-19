import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Compaction requests always answer 500: this group only reads the B recorded on the debug seam before compaction and needs no real summary.
private final class WindowURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://window.invalid")!
        let response = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WindowURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// The window used by manual compaction comes from the same source as sending (ChatRequestBuilder.contextWindowInput);
/// a stored "max output" value that the current profile no longer permits (dormant) does not enter the window's O.
extension ContextPipelineTests {

    @Test func dormant_max_output_not_in_window() async throws {
        await MetadataClient.shared.resetForTesting()
        var model = TestFactories.makeModel(id: "grok-window", name: "Grok Window", capabilities: [.text], isDefault: true)
        model.contextLength = 128_000
        let provider = Provider(
            id: UUID(),
            kind: .grok,
            status: .connected,
            models: [model],
            catalogModels: [],
            apiKey: "grok-key",
            apiKeyPreview: "...key",
            baseURLText: nil
        )
        let state = AppState(
            seedDemoData: false,
            sessionUID: "context-window-dormant-\(UUID().uuidString)",
            providerSession: WindowURLProtocol.session()
        )
        let messages = (0..<6).map { index in
            TestFactories.makeMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "Turn \(index): " + String(repeating: "context ", count: 40),
                providerID: provider.id,
                providerKind: .grok,
                modelID: model.id
            )
        }
        var conversation = TestFactories.makeConversation(
            providerID: provider.id,
            providerKind: .grok,
            modelID: model.id,
            messages: messages
        )
        conversation.contextCap = .unlimited
        state.providers = [provider]
        state.upsertConversationProjection(conversation)
        state.flushConversationPersistQueue()

        // The conversation layer stored max_output_tokens = 60000, but the current grok profile does not declare it: dormant.
        let store = GenerationParameterSettingsStore.shared
        let storedModelID = ModelResolver.preferredStoredModelIdentifier(for: model, providerKind: .grok)
        let fingerprint = GenerationParameterProfileFingerprint.make(provider: provider, model: model)
        store.setSessionOverrides(
            .init(values: ["max_output_tokens": .init(state: .value, value: .number(60_000))]),
            providerID: provider.id,
            modelID: storedModelID,
            conversationID: conversation.id,
            profileFingerprint: fingerprint
        )
        defer {
            store.setSessionOverrides(
                nil, providerID: provider.id, modelID: storedModelID,
                conversationID: conversation.id, profileFingerprint: fingerprint
            )
        }
        // The stored value itself is readable: without the dormant filter it would become the user output cap.
        let unfiltered = store.resolve(
            transient: nil, providerID: provider.id, modelID: storedModelID,
            conversationID: conversation.id, profileFingerprint: fingerprint
        )
        #expect(ChatRequestBuilder.userMaxOutputTokens(from: unfiltered) == 60_000)

        let withoutUser = ContextBudget.window(
            ChatRequestBuilder.contextWindowInput(providerKind: .grok, model: model, budgetCap: .unlimited)
        ).B
        let withDormant = ContextBudget.window(
            ChatRequestBuilder.contextWindowInput(
                providerKind: .grok, model: model, userMaxOutput: 60_000, budgetCap: .unlimited
            )
        ).B
        #expect(withoutUser != withDormant)

        _ = await state.chatManager.compactConversationNow(conversationId: conversation.id)

        #expect(state.chatManager.debugLastCompactionBudgetForTesting == withoutUser)
    }
}
