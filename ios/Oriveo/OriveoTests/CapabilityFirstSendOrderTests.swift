import Foundation
import Testing
@testable import Oriveo

/// First send from a new chat: the composer reads capability preferences by the real conversation
/// id the moment the chat page switches to it (`ChatComposerBar.onChange(conversationID)`), so the
/// draft-scoped values must already live under the real id when navigation changes.
@Suite("Capability preferences first-send order", .serialized, .sharedProcessState)
@MainActor
struct CapabilityFirstSendOrderTests {
    private static var retainedStates: [AppState] = []

    @Test("First send migrates draft capability preferences before presenting the real conversation")
    func firstSendMigratesCapabilityDraftBeforePresentingChat() async throws {
        var model = TestFactories.makeModel(id: "gpt-5.6-sol", capabilities: [.text, .web, .reasoning], isDefault: true)
        model.reasoningModeAvailable = true
        model.upstreamReasoningLevels = ["low", "medium", "high"]
        var provider = TestFactories.makeProvider(kind: .openAI, models: [model], catalogModels: [model])
        provider.authMode = .subscription
        let identity = try #require(CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model))

        let state = AppState(
            seedDemoData: false,
            sessionUID: "capability-first-send-order-\(UUID().uuidString)",
            providerSession: FirstSendOrderURLProtocol.session()
        )
        Self.retainedStates.append(state)
        state.providers = [provider]
        state.setActiveModel(providerID: provider.id, modelID: model.id)

        // The user flips web search and reasoning on the new-chat composer before the first send.
        let draft = UUID()
        let dialed = CapabilityPreferenceValues(web: .automatic, reasoningIntent: "high")
        GenerationParameterSettingsStore.shared.setCapabilityPreferences(
            dialed, providerID: provider.id, modelID: identity.canonicalModelID,
            conversationID: draft, transportIdentity: identity.wireValue
        )

        // Observation point: the navigation change that swaps the chat page to the real conversation id.
        // Reads the store synchronously, exactly like the composer's onChange(conversationID) does.
        var seenAtPresent: [UUID: CapabilityPreferenceValues] = [:]
        let navigation = state.navigation
        let previousObserver = navigation.onPathChange
        navigation.onPathChange = { old, new in
            previousObserver?(old, new)
            guard case let .chat(conversationID: realID?)? = new.last else { return }
            seenAtPresent[realID] = GenerationParameterSettingsStore.shared.displayCapabilityPreferences(
                providerID: provider.id, modelID: identity.canonicalModelID,
                conversationID: realID, skillID: nil, transportIdentity: identity.wireValue
            )
        }
        defer { navigation.onPathChange = previousObserver }

        _ = await state.sendMessageOutcome(
            "hello", in: nil, generationParameterDraftSessionID: draft
        )
        try await Self.waitForSendsToSettle(state)

        let realID = try #require(state.conversations.first?.id, "first send created a conversation")
        let atPresent = try #require(seenAtPresent[realID], "chat page was presented with the real conversation id")
        #expect(atPresent == dialed, "real-id read at presentChat sees the draft values (got \(atPresent))")
    }

    private static func waitForSendsToSettle(_ state: AppState) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while state.chatManager.isAnyStreaming
            || state.conversations.contains(where: { $0.messages.contains { $0.state == .generating } }) {
            if ContinuousClock.now >= deadline {
                Issue.record("Timed out waiting for the first send to settle")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// Every request fails fast with a JSON 500; the test only cares about the order before the wire.
private final class FirstSendOrderURLProtocol: URLProtocol, @unchecked Sendable {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirstSendOrderURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://first-send-order.test")!
        let response = HTTPURLResponse(
            url: url, statusCode: 500, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":{"message":"stub"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
