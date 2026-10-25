import Foundation
import GRDB
import Testing
@testable import Oriveo

/// Anthropic allows at most 4 cache breakpoints per request. With 5 images in the current turn plus images in history,
/// the official route and Relay follow the same rule: no top-level `cache_control`, and exactly one on the last non-[D] block of the last user message.
@Suite("Anthropic cache breakpoints", .serialized, .sharedProcessState)
struct AnthropicCacheBreakpointTests {

    @Test("Official Anthropic: 5 images plus a history image yield a single cache_control on the last block of the last user message")
    func officialKeepsSingleBlockBreakpoint() async throws {
        try await Self.loadOfficialCatalog(promptCache: Self.explicitPromptCache)
        AnthropicCaptureURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnthropicCaptureURLProtocol.self]
        let service = AnthropicService(session: URLSession(configuration: config))

        do {
            for try await _ in service.sendMessageStream(
                apiKey: "sk-test",
                modelID: "claude-sonnet-4-5",
                messages: Self.messagesWithManyImages(),
                reasoningMode: .automatic,
                webSearchEnabled: false,
                requestOptions: Self.visionOptions()
            ) {}
        } catch {
            // Only the outgoing request body matters; how the stub response parses is out of scope here
        }

        let body = try #require(AnthropicCaptureURLProtocol.bodies().first)
        let text = String(decoding: body, as: UTF8.self)
        #expect(Self.occurrences(of: "cache_control", in: text) == 1)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["cache_control"] == nil)
        let lastUser = try #require((json["messages"] as? [[String: Any]])?.last { $0["role"] as? String == "user" })
        let lastBlocks = try #require(lastUser["content"] as? [[String: Any]])
        #expect((lastBlocks.last?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")

        // The official route's vision evidence is unavailable in tests, so sendMessageStream turns images into
        // placeholders; encode blocks through the same production buildRequestMessage and confirm no image block
        // carries a breakpoint (the single breakpoint is placed at the request-body level).
        let blocksJSON = try AnthropicService.encodedWireMessages(
            Self.messagesWithManyImages(), transport: .anthropicMessages, model: nil
        )
        let blocksText = String(decoding: blocksJSON, as: UTF8.self)
        #expect(Self.occurrences(of: "\"type\":\"image\"", in: blocksText) == 6, "images are actually encoded as blocks")
        #expect(Self.occurrences(of: "cache_control", in: blocksText) == 0)
    }

    @Test("Official Anthropic: catalog missing promptCache / missing policyRef / not explicit / catalog unavailable -> 0 breakpoints, [D] is still split off")
    func officialWithoutExplicitPolicyHasNoBreakpoint() async throws {
        for promptCache in [nil, "{}", #"{"policyRef":"anthropic.automatic"}"#, #"{"policyRef":7}"#] {
            try await Self.loadOfficialCatalog(promptCache: promptCache)
            let body = try #require(try await Self.officialBody(dynamic: true, loadCatalog: false))
            #expect(Self.occurrences(of: "cache_control", in: String(decoding: body, as: UTF8.self)) == 0, "\(promptCache ?? "nil")")
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            let blocks = try #require((json["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])
            #expect(blocks.count == 2, "[D] is still split into its own last block")
        }
        await MetadataClient.shared.resetForTesting()
        let body = try #require(try await Self.officialBody(dynamic: false, loadCatalog: false))
        #expect(Self.occurrences(of: "cache_control", in: String(decoding: body, as: UTF8.self)) == 0, "metadata unavailable")
    }

    @Test("The catalog promptCache.policyRef decodes into the resolved model and round-trips unchanged through ModelMetadataEntry")
    func promptCachePolicyRefDecodesAndRoundTrips() async throws {
        try await Self.loadOfficialCatalog(promptCache: Self.explicitPromptCache)
        let resolved = MetadataClient.shared.syncResolveCatalogModel(modelID: "claude-sonnet-4-5", providerKind: .anthropic)
        #expect(resolved?.promptCachePolicyRef == "anthropic.explicit")
        let entryJSON = #"{"canonicalModelId":"claude-sonnet-4-5","promptCache":{"policyRef":"anthropic.explicit","extra":1}}"#
        let entry = try JSONDecoder().decode(MetadataClient.ModelMetadataEntry.self, from: Data(entryJSON.utf8))
        #expect(entry.promptCachePolicyRef == "anthropic.explicit")
        let reencoded = try JSONDecoder().decode(
            MetadataClient.ModelMetadataEntry.self, from: try JSONEncoder().encode(entry)
        )
        #expect(reencoded.promptCachePolicyRef == "anthropic.explicit")
        let raw = try #require(
            (try JSONSerialization.jsonObject(with: try JSONEncoder().encode(entry)) as? [String: Any])?["promptCache"] as? [String: Any]
        )
        #expect((raw["extra"] as? NSNumber)?.intValue == 1)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Relay Anthropic: 5 images plus a history image put the only breakpoint on the last block of the last user")
    func relayKeepsSingleBreakpointOnLastUserBlock() throws {
        let request = try AnthropicService().buildRelayMessagesRequest(
            modelID: "golden-relay-model",
            messages: Self.messagesWithManyImages(),
            apiKey: "sk-test",
            baseURL: "https://relay.example.com",
            stream: true,
            reasoningMode: .automatic,
            requestOptions: Self.visionOptions(),
            relayRequested: RelayRequestedConfig(transport: .anthropicMessages),
            keepImageAttachments: true
        )
        let body = try #require(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        #expect(Self.occurrences(of: "cache_control", in: text) == 1)

        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["cache_control"] == nil)
        #expect(Self.imageBlockCount(in: json) >= 5)
        let messages = try #require(json["messages"] as? [[String: Any]])
        let lastUser = try #require(messages.last { $0["role"] as? String == "user" })
        let blocks = try #require(lastUser["content"] as? [[String: Any]])
        #expect((blocks.last?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    }

    @Test("Relay Anthropic: a text-only last user expands into a single text block carrying the only breakpoint")
    func relayTextOnlyLastUserGetsBreakpoint() throws {
        let request = try AnthropicService().buildRelayMessagesRequest(
            modelID: "golden-relay-model",
            messages: [
                TestFactories.makeMessage(role: .user, text: "Hello", providerKind: .anthropic),
                TestFactories.makeMessage(role: .assistant, text: "Hi there.", providerKind: .anthropic),
                TestFactories.makeMessage(role: .user, text: "Summarize.", providerKind: .anthropic),
            ],
            apiKey: "sk-test",
            baseURL: "https://relay.example.com",
            stream: true,
            reasoningMode: .automatic,
            relayRequested: RelayRequestedConfig(transport: .anthropicMessages)
        )
        let body = try #require(request.httpBody)
        #expect(Self.occurrences(of: "cache_control", in: String(decoding: body, as: UTF8.self)) == 1)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.first?["content"] as? String == "Hello", "only the last user message is touched")
        let blocks = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks.first?["type"] as? String == "text")
        #expect(blocks.first?["text"] as? String == "Summarize.")
        #expect(blocks.first?["cache_control"] != nil)
    }

    // MARK: - [D] as a standalone last block

    @Test("Official Anthropic: [D] is a standalone last block of the last user message, and the only breakpoint is on the block before it")
    func anthropic_official_dynamic_block_last_breakpoint_before_it() async throws {
        let wire = try #require(try await Self.officialBody(dynamic: true))
        try Self.expectMatchesFixture(wire)
    }

    @Test("Relay Anthropic: [D] is a standalone last block of the last user message, and the only breakpoint is on the block before it")
    func anthropic_relay_dynamic_block_last_breakpoint_before_it() throws {
        let wire = try Self.relayBody(dynamic: true)
        try Self.expectMatchesFixture(wire)
    }

    @Test("Official / Relay Anthropic: without [D], the only breakpoint is on the last block of the last user message")
    func anthropic_without_dynamic_breakpoint_on_last_block() async throws {
        let official = try #require(try await Self.officialBody(dynamic: false))
        for body in [official, try Self.relayBody(dynamic: false)] {
            #expect(Self.occurrences(of: "cache_control", in: String(decoding: body, as: UTF8.self)) == 1)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["cache_control"] == nil)
            let messages = try #require(json["messages"] as? [[String: Any]])
            let blocks = try #require(messages.last?["content"] as? [[String: Any]])
            #expect(blocks.count == 1)
            #expect(blocks.last?["text"] as? String == "Write chapter 2.")
            #expect((blocks.last?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        }
    }

    @Test("Library / MCP tool leg (Relay Anthropic): the only breakpoint is on the notice, the last block of the request's last user message (the tool_result turn)")
    @MainActor
    func anthropic_tool_loop_breakpoint_on_last_tool_result_turn() async throws {
        let dynamic = "<oriveo-reminder>\nWrite only in Arabic.\n</oriveo-reminder>"
        var model = AIModel(
            id: "relay-agent-model", name: "Relay Agent", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "standard"
        )
        model.toolCall = true
        let provider = Provider(
            id: UUID(), kind: .relay, status: .connected, models: [model], catalogModels: [],
            apiKey: "relay-key", apiKeyPreview: "...key", baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: .anthropicMessages)
        )
        var options = ChatRequestOptions(systemPrompt: "System.")
        options.dynamicText = dynamic
        AnthropicCaptureURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnthropicCaptureURLProtocol.self]
        let pair = try ToolLoopLegRunnerFactory.make(
            provider: provider, model: model, modelID: model.id, reasoningMode: .automatic,
            requestOptions: options, accessToken: nil, toolCallMemory: try Self.makeMemoryStore(),
            session: URLSession(configuration: config)
        )
        let adapter = pair.adapter
        #expect(adapter.transport == TransportKind.anthropicMessages.rawValue)
        let notice = "Step limit reached."
        let call = ToolLoopToolCall(id: "call_1", function: .init(name: "echo", arguments: "{}"))
        do {
            for try await _ in pair.runner.run(request: ToolLoopLegRequest(
                messages: [
                    ToolLoopMessage(role: "system", content: "System."),
                    ToolLoopMessage(role: "user", content: "Find it\n\n" + dynamic),
                    adapter.encodeAssistantToolCalls(
                        text: "Checking.", reasoning: nil, toolCalls: [call], replayBlocks: [], assistantReplay: nil
                    ),
                    adapter.encodeToolResult(callID: "call_1", toolName: "echo", content: #"{"ok":true}"#),
                    ToolCallLoop.loopNotice(notice),
                ],
                tools: [], toolChoice: .none
            )) {}
        } catch {
            // Only the outgoing request body matters
        }
        let body = try #require(AnthropicCaptureURLProtocol.bodies().first)
        #expect(Self.occurrences(of: "cache_control", in: String(decoding: body, as: UTF8.self)) == 1)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["cache_control"] == nil)
        let messages = try #require(json["messages"] as? [[String: Any]])
        let last = try #require(messages.last)
        #expect(last["role"] as? String == "user")
        let blocks = try #require(last["content"] as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == ["tool_result", "text"])
        #expect(blocks.last?["text"] as? String == notice)
        #expect((blocks.last?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    }

    // MARK: - [D] carriage

    @Test("Relay Anthropic: with an empty body and only an image, text == [D] is still split into the last block, and the only breakpoint is on the image")
    func anthropic_image_only_dynamic_breakpoint_on_image() throws {
        var options = Self.visionOptions()
        options.dynamicText = Self.dynamic
        let request = try AnthropicService().buildRelayMessagesRequest(
            modelID: "golden-relay-model",
            messages: [
                TestFactories.makeMessage(role: .user, text: "Hello", providerKind: .anthropic),
                TestFactories.makeMessage(role: .assistant, text: "Hi there.", providerKind: .anthropic),
                TestFactories.makeMessage(
                    role: .user, text: Self.dynamic, providerKind: .anthropic, attachments: [Self.image("photo.png")]
                ),
            ],
            apiKey: "sk-test", baseURL: "https://relay.example.com", stream: true, reasoningMode: .automatic,
            requestOptions: options, relayRequested: RelayRequestedConfig(transport: .anthropicMessages),
            keepImageAttachments: true
        )
        let body = try #require(request.httpBody)
        #expect(Self.occurrences(of: "cache_control", in: String(decoding: body, as: UTF8.self)) == 1)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let blocks = try #require((json["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == ["image", "text"])
        #expect(blocks.last?["text"] as? String == Self.dynamic)
        #expect(blocks.last?["cache_control"] == nil)
        #expect((blocks.first?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    }

    @Test("Relay Anthropic: extracted file text is injected before [D], and [D] is still split into a standalone last block of the last user message")
    func anthropic_file_text_injected_before_dynamic() throws {
        var options = ChatRequestOptions(systemPrompt: "System.")
        options.dynamicText = Self.dynamic
        let content = "Quarterly numbers: 42."
        let file = Oriveo.Attachment(
            id: UUID(), kind: .file, fileName: "notes.txt", mimeType: "text/plain",
            base64Data: Data(content.utf8).base64EncodedString(), extractedSizeBytes: content.utf8.count
        )
        let request = try AnthropicService().buildRelayMessagesRequest(
            modelID: "golden-relay-model",
            messages: [
                TestFactories.makeMessage(
                    role: .user, text: "Summarize the file.\n\n" + Self.dynamic, providerKind: .anthropic,
                    attachments: [file]
                ),
            ],
            apiKey: "sk-test", baseURL: "https://relay.example.com", stream: true, reasoningMode: .automatic,
            requestOptions: options, relayRequested: RelayRequestedConfig(transport: .anthropicMessages)
        )
        let body = try #require(request.httpBody)
        #expect(Self.occurrences(of: "cache_control", in: String(decoding: body, as: UTF8.self)) == 1)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let blocks = try #require((json["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])
        #expect(blocks.count == 2)
        let head = try #require(blocks.first?["text"] as? String)
        #expect(head.hasPrefix("Summarize the file.\n\n"))
        #expect(head.contains(content))
        #expect(!head.contains(Self.dynamic))
        #expect((blocks.first?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect(blocks.last?["text"] as? String == Self.dynamic)
        #expect(blocks.last?["cache_control"] == nil)
    }

    @Test("Library / MCP tool leg (Relay Anthropic): every leg splits [D] on the current user message, and the prefix stays unchanged across legs")
    @MainActor
    func anthropic_tool_leg_keeps_dynamic_split_on_current_user() async throws {
        var model = AIModel(
            id: "relay-agent-model", name: "Relay Agent", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "standard"
        )
        model.toolCall = true
        let provider = Provider(
            id: UUID(), kind: .relay, status: .connected, models: [model], catalogModels: [],
            apiKey: "relay-key", apiKeyPreview: "...key", baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: .anthropicMessages)
        )
        var options = ChatRequestOptions(systemPrompt: "System.")
        options.dynamicText = Self.dynamic
        AnthropicCaptureURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnthropicCaptureURLProtocol.self]
        let pair = try ToolLoopLegRunnerFactory.make(
            provider: provider, model: model, modelID: model.id, reasoningMode: .automatic,
            requestOptions: options, accessToken: nil, toolCallMemory: try Self.makeMemoryStore(),
            session: URLSession(configuration: config)
        )
        let adapter = pair.adapter
        let call = ToolLoopToolCall(id: "call_1", function: .init(name: "echo", arguments: "{}"))
        let firstLeg = [
            ToolLoopMessage(role: "system", content: "System."),
            ToolLoopMessage(role: "user", content: "Find it\n\n" + Self.dynamic),
        ]
        let secondLeg = firstLeg + [
            adapter.encodeAssistantToolCalls(
                text: "Checking.", reasoning: nil, toolCalls: [call], replayBlocks: [], assistantReplay: nil
            ),
            adapter.encodeToolResult(callID: "call_1", toolName: "echo", content: #"{"ok":true}"#),
        ]
        for legMessages in [firstLeg, secondLeg] {
            do {
                for try await _ in pair.runner.run(request: ToolLoopLegRequest(
                    messages: legMessages, tools: [], toolChoice: .none
                )) {}
            } catch {
                // Only the outgoing request body matters
            }
        }
        let bodies = AnthropicCaptureURLProtocol.bodies()
        #expect(bodies.count == 2)
        var legs: [[[String: Any]]] = []
        for body in bodies {
            #expect(Self.occurrences(of: "cache_control", in: String(decoding: body, as: UTF8.self)) == 1)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            legs.append(try #require(json["messages"] as? [[String: Any]]))
        }
        let first = try #require(legs.first?.first?["content"] as? [[String: Any]])
        #expect(first.map { $0["text"] as? String } == ["Find it", Self.dynamic])
        #expect((first.first?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect(first.last?["cache_control"] == nil)

        let second = try #require(legs.last)
        let current = try #require(second.first?["content"] as? [[String: Any]])
        #expect(current.map { $0["text"] as? String } == ["Find it", Self.dynamic])
        #expect(current.allSatisfy { $0["cache_control"] == nil })
        let lastBlocks = try #require(second.last?["content"] as? [[String: Any]])
        #expect(second.last?["role"] as? String == "user")
        #expect(lastBlocks.map { $0["type"] as? String } == ["tool_result"])
        #expect((lastBlocks.last?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    }

    private static let dynamic = "<oriveo-reminder>\nWrite only in Arabic.\n</oriveo-reminder>"

    /// A standalone GRDB database (runs the full migrator) that does not touch DatabaseManager's current user pool.
    private static func makeMemoryStore() throws -> ToolCallMemoryStore {
        let uid = "toolcall-memory-\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: AppSessionStore.userDir(for: uid), withIntermediateDirectories: true)
        let pool = try DatabasePool(
            path: AppSessionStore.databasePath(for: uid).path,
            configuration: DatabaseSchema.makeConfiguration()
        )
        let files = AttachmentFileStore(rootDirectory: AppSessionStore.filesDir(for: uid))
        try DatabaseSchema.makeMigrator(attachmentFileStore: files).migrate(pool)
        return ToolCallMemoryStore(poolProvider: { pool })
    }

    private static func wireSystemCase() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/context-contracts/wire-system.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
                let cases = try #require(object["cases"] as? [[String: Any]])
                return try #require(cases.first { $0["id"] as? String == "system_history_and_dynamic_block" })
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// Projects the fixture plan into chat inputs: same shape as PlannedChatRequest, with [D] appended after a blank line at the end of the last user message and also written into dynamicText.
    private static func fixtureInput(dynamic: Bool) throws -> ([ChatMessage], ChatRequestOptions) {
        let plan = try #require(try wireSystemCase()["plan"] as? [String: Any])
        var options = ChatRequestOptions(systemPrompt: try #require(plan["system"] as? String))
        var dynamicTexts: [String] = []
        let messages: [ChatMessage] = try #require(plan["messages"] as? [[String: Any]]).map { message in
            let blocks = message["blocks"] as? [[String: Any]] ?? []
            let texts = blocks.filter { $0["kind"] as? String == "text" }.compactMap { $0["text"] as? String }
            let dynamics = blocks.filter { $0["kind"] as? String == "dynamic" }.compactMap { $0["text"] as? String }
            dynamicTexts += dynamics
            let text = (texts + (dynamic ? dynamics : [])).joined(separator: "\n\n")
            let role: ChatRole = message["role"] as? String == "assistant" ? .assistant : .user
            return TestFactories.makeMessage(role: role, text: text, providerKind: .anthropic)
        }
        if dynamic { options.dynamicText = dynamicTexts.joined(separator: "\n\n") }
        return (messages, options)
    }

    private static let explicitPromptCache = #"{"policyRef":"anthropic.explicit"}"#

    /// Injects an official Anthropic catalog containing only claude-sonnet-4-5; `promptCache` is JSON spliced verbatim into the model entry, nil = the key is omitted.
    private static func loadOfficialCatalog(promptCache: String?) async throws {
        await MetadataClient.shared.resetForTesting()
        let promptCacheField = promptCache.map { ",\n              \"promptCache\": \($0)" } ?? ""
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-10-19T00:00:00Z",
          "profiles": { "reasoning": {}, "webSearch": {}, "imageGen": {} },
          "providers": {
            "anthropic": {
              "displayName": "Anthropic",
              "defaultModelId": "claude-sonnet-4-5",
              "validationModelId": "claude-sonnet-4-5",
              "resolveMap": { "claude-sonnet-4-5": "claude-sonnet-4-5" },
              "models": {
                "claude-sonnet-4-5": {
                  "canonicalModelId": "claude-sonnet-4-5",
                  "displayName": "Claude Sonnet 4.5",
                  "capabilities": ["text"]\(promptCacheField)
                }
              }
            }
          }
        }
        """, metadataETag: "anthropic-cache-breakpoint-\(UUID().uuidString)")
    }

    private static func officialBody(dynamic: Bool, loadCatalog: Bool = true) async throws -> Data? {
        if loadCatalog { try await loadOfficialCatalog(promptCache: explicitPromptCache) }
        AnthropicCaptureURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnthropicCaptureURLProtocol.self]
        let service = AnthropicService(session: URLSession(configuration: config))
        let (messages, options) = try fixtureInput(dynamic: dynamic)
        do {
            for try await _ in service.sendMessageStream(
                apiKey: "sk-test", modelID: "claude-sonnet-4-5", messages: messages,
                reasoningMode: .automatic, webSearchEnabled: false, requestOptions: options
            ) {}
        } catch {
            // Only the outgoing request body matters
        }
        return AnthropicCaptureURLProtocol.bodies().first
    }

    private static func relayBody(dynamic: Bool) throws -> Data {
        let (messages, options) = try fixtureInput(dynamic: dynamic)
        let request = try AnthropicService().buildRelayMessagesRequest(
            modelID: "golden-relay-model", messages: messages, apiKey: "sk-test",
            baseURL: "https://relay.example.com", stream: true, reasoningMode: .automatic,
            requestOptions: options, relayRequested: RelayRequestedConfig(transport: .anthropicMessages)
        )
        return try #require(request.httpBody)
    }

    /// The system and the last user message's content are byte-identical to the fixture's expected.anthropic (serialized with sorted keys), and the whole request body has exactly one cache_control.
    private static func expectMatchesFixture(_ body: Data) throws {
        #expect(occurrences(of: "cache_control", in: String(decoding: body, as: UTF8.self)) == 1)
        let expected = try #require(
            (try wireSystemCase()["expected"] as? [String: Any])?["anthropic"] as? [String: Any]
        )
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["cache_control"] == nil)
        #expect(json["system"] as? String == expected["system"] as? String)
        let actualLast = try #require((json["messages"] as? [[String: Any]])?.last)
        let expectedLast = try #require((expected["messages"] as? [[String: Any]])?.last)
        #expect(actualLast["role"] as? String == "user")
        let actualContent = try JSONSerialization.data(withJSONObject: try #require(actualLast["content"]), options: [.sortedKeys])
        let expectedContent = try JSONSerialization.data(withJSONObject: try #require(expectedLast["content"]), options: [.sortedKeys])
        #expect(String(decoding: actualContent, as: UTF8.self) == String(decoding: expectedContent, as: UTF8.self))
    }

    // MARK: - Fixtures

    /// Model evidence declaring vision support; without it images become placeholders and never reach the body.
    private static func visionOptions() -> ChatRequestOptions {
        var options = ChatRequestOptions(systemPrompt: "System.")
        options.capabilityEvidenceModel = TestFactories.makeModel(id: "claude-sonnet-4-5", capabilities: [.text, .image])
        return options
    }

    private static func image(_ name: String) -> Oriveo.Attachment {
        Oriveo.Attachment(
            id: UUID(),
            kind: .image,
            fileName: name,
            mimeType: "image/png",
            base64Data: "iVBORw0KGgo="
        )
    }

    private static func messagesWithManyImages() -> [ChatMessage] {
        [
            TestFactories.makeMessage(
                role: .user, text: "Earlier picture", providerKind: .anthropic,
                attachments: [image("history.png")]
            ),
            TestFactories.makeMessage(role: .assistant, text: "Seen.", providerKind: .anthropic),
            TestFactories.makeMessage(
                role: .user, text: "Compare these", providerKind: .anthropic,
                attachments: (1...5).map { image("current-\($0).png") }
            ),
        ]
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private static func imageBlockCount(in json: [String: Any]) -> Int {
        let messages = json["messages"] as? [[String: Any]] ?? []
        return messages.reduce(0) { count, message in
            let blocks = message["content"] as? [[String: Any]] ?? []
            return count + blocks.filter { $0["type"] as? String == "image" }.count
        }
    }
}

private final class AnthropicCaptureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [Data] = []

    static func reset() { lock.withLock { captured = [] } }
    static func bodies() -> [Data] { lock.withLock { captured } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let size = 4_096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            buffer.deallocate()
            stream.close()
            body = data
        }
        Self.lock.withLock { Self.captured.append(body ?? Data()) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
