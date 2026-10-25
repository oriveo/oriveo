import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Counts the requests the send chain issues; the response is just the shortest successful stream, since the budget already lands on the debug seam before the request is sent.
private final class PriceLineURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let url = request.url ?? URL(string: "https://price-line.invalid")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        let body = url.path.hasSuffix("/messages")
            ? "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
            : "data: [DONE]\n\n"
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PriceLineURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// The price line T is decoded by the production metadata decoder, and the window factory looks it up by (kind, modelId);
/// B reads the plan.budget produced after the send chain hands its parameters to ContextAssembler. Relay must not use T even with the same metadata.
@Suite("Context cap production path", .serialized, .sharedProcessState)
@MainActor
struct ContextCapProductionPathTests {
    private static let modelID = "grok-4.7"
    private static let window = 2_000_000

    /// The same grok-4.7 entry is placed under both the grok and relay provider keys:
    /// if Relay looked it up in the official catalog, it would get the same price line.
    private static func metadataJSON(longContext: String) -> String {
        let model = """
        {
          "canonicalModelId": "\(modelID)",
          "displayName": "Grok 4.7",
          "contextLength": \(window),
          "pricing": {
            "promptPerMToken": 2,
            "completionPerMToken": 6,
            "longContext": \(longContext)
          },
          "capabilities": ["text"],
          "profiles": {}
        }
        """
        let provider: (String) -> String = { name in
            """
            "\(name)": {
              "displayName": "\(name)",
              "defaultModelId": "\(modelID)",
              "resolveMap": { "\(modelID)": "\(modelID)" },
              "models": { "\(modelID)": \(model) }
            }
            """
        }
        return """
        {
          "version": 1,
          "updatedAt": "2026-10-15T00:00:00Z",
          "providers": {
            \(provider("grok")),
            \(provider("relay"))
          }
        }
        """
    }

    private static let validLongContext = """
    {"thresholdTokens": 200000, "promptPerMToken": 4, "completionPerMToken": 12, "cacheReadPerMToken": 1}
    """

    private static func installMetadata(longContext: String = validLongContext) async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: metadataJSON(longContext: longContext))
    }

    private static func windowedModel() -> AIModel {
        var model = TestFactories.makeModel(id: modelID, name: "Grok 4.7", capabilities: [.text], isDefault: true)
        model.contextLength = window
        return model
    }

    private struct SendOutcome {
        var budget: ContextPlanBudget
        var window: ContextWindowInput?
        var precheckBudget: ContextPlanBudget?
    }

    /// Runs the production send chain through AppState.sendMessage and returns the plan.budget it recorded.
    private func sendAndReadBudget(
        provider: Provider,
        configure: ((AppState) -> Void)? = nil
    ) async throws -> ContextPlanBudget {
        try await send(provider: provider, configure: configure).budget
    }

    /// The window parameters the send chain actually hands to ContextAssembler, the plan.budget, and the plan.budget built by the reject precheck.
    private func send(
        provider: Provider,
        prepare: (inout Conversation) throws -> Void = { _ in },
        install: ((AppState, Conversation) async throws -> Void)? = nil,
        configure: ((AppState) -> Void)? = nil
    ) async throws -> SendOutcome {
        let state = AppState(
            seedDemoData: false,
            sessionUID: "context-cap-production-\(UUID().uuidString)",
            providerSession: PriceLineURLProtocol.session()
        )
        var conversation = TestFactories.makeConversation(
            providerID: provider.id,
            providerKind: provider.kind,
            modelID: Self.modelID,
            messages: []
        )
        try prepare(&conversation)
        state.providers = [provider]
        if let install {
            try await install(state, conversation)
        } else {
            state.upsertConversationProjection(conversation)
        }
        configure?(state)

        PriceLineURLProtocol.requestCount = 0
        _ = await state.sendMessage(
            "Hello",
            in: conversation.id,
            capabilitySelection: ChatCapabilitySelection(reasoningMode: .automatic, webSearchEnabled: false)
        )
        let deadline = ContinuousClock.now + .seconds(5)
        while state.chatManager.debugLastContextBudgetForTesting == nil, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let budget = try #require(
            state.chatManager.debugLastContextBudgetForTesting,
            "send pipeline produced no context budget"
        )
        let outcome = SendOutcome(
            budget: budget,
            window: state.chatManager.debugLastContextWindowForTesting,
            precheckBudget: state.chatManager.debugLastContextRejectPrecheckBudgetForTesting
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        state.cancelGeneration(in: conversation.id)
        return outcome
    }

    private static func grokProvider() -> Provider {
        Provider(
            id: UUID(),
            kind: .grok,
            status: .connected,
            models: [windowedModel()],
            catalogModels: [],
            apiKey: "grok-key",
            apiKeyPreview: "...key",
            baseURLText: nil
        )
    }

    @Test func grok_auto_price_line_caps_budget() async throws {
        try await Self.installMetadata()
        let provider = Provider(
            id: UUID(),
            kind: .grok,
            status: .connected,
            models: [Self.windowedModel()],
            catalogModels: [],
            apiKey: "grok-key",
            apiKeyPreview: "...key",
            baseURLText: nil
        )
        let budget = try await sendAndReadBudget(provider: provider)
        #expect(budget.W == Self.window)
        #expect(budget.B == 200_000)
    }

    @Test func relay_ignores_price_line() async throws {
        try await Self.installMetadata()
        let provider = Provider(
            id: UUID(),
            kind: .relay,
            status: .connected,
            models: [Self.windowedModel()],
            catalogModels: [],
            apiKey: "relay-key",
            apiKeyPreview: "...key",
            baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: .anthropicMessages)
        )
        let budget = try await sendAndReadBudget(provider: provider)
        #expect(budget.W == Self.window)
        #expect(budget.B == 256_000)
    }

    @Test func metadata_decodes_long_context() async throws {
        try await Self.installMetadata()
        let resolved = try #require(
            MetadataClient.shared.resolveCatalogModel(modelID: Self.modelID, providerKind: .grok)
        )
        let longContext = try #require(resolved.longContext)
        #expect(longContext.thresholdTokens == 200_000)
        #expect(longContext.promptPerMToken == 4)
        #expect(longContext.completionPerMToken == 12)
        #expect(longContext.cacheReadPerMToken == 1)

        // cacheRead may be absent.
        try await Self.installMetadata(longContext: """
        {"thresholdTokens": 200000, "promptPerMToken": 4, "completionPerMToken": 12}
        """)
        let withoutCacheRead = MetadataClient.shared.resolveCatalogModel(modelID: Self.modelID, providerKind: .grok)
        #expect(withoutCacheRead?.longContext?.thresholdTokens == 200_000)
        #expect(withoutCacheRead?.longContext?.cacheReadPerMToken == nil)

        // A floating-point spelling of an integer value is accepted.
        try await Self.installMetadata(longContext: """
        {"thresholdTokens": 200000.0, "promptPerMToken": 4, "completionPerMToken": 12}
        """)
        #expect(
            MetadataClient.shared.resolveCatalogModel(modelID: Self.modelID, providerKind: .grok)?
                .longContext?.thresholdTokens == 200_000
        )

        // A malformed shape drops only longContext: the rest of the pricing and the model decode as usual.
        let badShapes = [
            #""oops""#,
            #"{"thresholdTokens": "200000", "promptPerMToken": 4, "completionPerMToken": 12}"#,
            #"{"thresholdTokens": 200000, "promptPerMToken": 4}"#,
            #"{"thresholdTokens": 0, "promptPerMToken": 4, "completionPerMToken": 12}"#,
            #"{"thresholdTokens": -5, "promptPerMToken": 4, "completionPerMToken": 12}"#,
            #"{"thresholdTokens": 200000.5, "promptPerMToken": 4, "completionPerMToken": 12}"#,
            #"{"thresholdTokens": 2147483648, "promptPerMToken": 4, "completionPerMToken": 12}"#,
            #"{"thresholdTokens": 200000, "promptPerMToken": -1, "completionPerMToken": 12}"#,
        ]
        for shape in badShapes {
            try await Self.installMetadata(longContext: shape)
            let resolved = MetadataClient.shared.resolveCatalogModel(modelID: Self.modelID, providerKind: .grok)
            #expect(resolved != nil, "model dropped for longContext \(shape)")
            #expect(resolved?.longContext == nil, "longContext kept for \(shape)")
            #expect(resolved?.contextLength == Self.window)
            #expect(resolved?.promptPerToken == 2.0 / 1_000_000)
            #expect(resolved?.completionPerToken == 6.0 / 1_000_000)
        }
        await MetadataClient.shared.resetForTesting()
    }

    // MARK: - Conversation cap ?? global default through the production path
    // The conversation-cap group installs metadata with T = 200000: the tier (custom / unlimited) overrides the price line.

    @Test func backup_restored_cap_drives_budget() async throws {
        try await Self.installMetadata()
        let provider = Self.grokProvider()
        let outcome = try await send(provider: provider) { conversation in
            conversation.contextCap = .custom(190_000)
        } install: { state, conversation in
            // The production BackupService exports a ZIP, then it is parsed and imported with "import new data only" into an AppState that does not have the conversation yet.
            let archive = try await BackupService.exportBackup(
                providers: [provider],
                conversations: [conversation],
                preferences: AppPreference(theme: .system, language: .english),
                lastUsedModelRef: nil, includeKeys: false, password: nil
            )
            let (backupFile, images) = try BackupService.parseBackup(from: archive)
            #expect(state.conversation(for: conversation.id) == nil)
            _ = try await BackupService.executeImport(
                backupFile: backupFile, images: images, mode: .importNewOnly, password: nil, appState: state
            )
            let restored = try #require(state.conversation(for: conversation.id), "backup import dropped the conversation")
            #expect(restored.contextCap == .custom(190_000))
        }
        #expect(outcome.budget.B == 190_000)
    }

    @Test func global_custom_cap_applies_when_following() async throws {
        try await Self.installMetadata()
        let outcome = try await send(provider: Self.grokProvider()) { conversation in
            conversation.contextCap = nil
        } configure: { state in
            state.preferences.contextDefaultCap = .custom(300_000)
        }
        #expect(outcome.budget.B == 300_000)
    }

    @Test func conversation_unlimited_overrides_global() async throws {
        try await Self.installMetadata()
        let outcome = try await send(provider: Self.grokProvider()) { conversation in
            conversation.contextCap = .unlimited
        } configure: { state in
            state.preferences.contextDefaultCap = .custom(64_000)
        }
        let window = try #require(outcome.window)
        let U = try #require(ContextBudget.window(window).U)
        #expect(U > ContextBudget.autoCapDefault)
        #expect(outcome.budget.B == U)
    }

    @Test func compaction_uses_conversation_cap() async throws {
        await MetadataClient.shared.resetForTesting()
        let provider = Self.grokProvider()
        let state = AppState(
            seedDemoData: false,
            sessionUID: "context-cap-compaction-\(UUID().uuidString)",
            providerSession: PriceLineURLProtocol.session()
        )
        let messages = (0..<6).map { index in
            TestFactories.makeMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "Turn \(index): " + String(repeating: "context ", count: 40),
                providerID: provider.id,
                providerKind: .grok,
                modelID: Self.modelID
            )
        }
        var conversation = TestFactories.makeConversation(
            providerID: provider.id,
            providerKind: .grok,
            modelID: Self.modelID,
            messages: messages
        )
        conversation.contextCap = .custom(64_000)
        state.providers = [provider]
        state.preferences.contextDefaultCap = .auto
        state.upsertConversationProjection(conversation)
        state.flushConversationPersistQueue()

        _ = await state.chatManager.compactConversationNow(conversationId: conversation.id)

        #expect(state.chatManager.debugLastCompactionBudgetForTesting == 64_000)
    }

    @Test func reject_precheck_uses_conversation_cap() async throws {
        await MetadataClient.shared.resetForTesting()
        let outcome = try await send(provider: Self.grokProvider()) { conversation in
            conversation.contextCap = .custom(64_000)
        } configure: { state in
            state.preferences.contextDefaultCap = .auto
        }
        // Rejection only compares U: a 64000 conversation cap only changes B and does not reject, so the send proceeds to assembly as usual.
        let precheck = try #require(outcome.precheckBudget, "reject precheck produced no plan budget")
        #expect(precheck.B == 64_000)
        #expect(outcome.budget.B == 64_000)
    }
}
