import Foundation
import Testing
@testable import Oriveo

/// RL2-WEBPROBE-SEND: driven by `chatCases` in `shared/test-fixtures/relay/web-probe.v1.json`.
/// Sends one message through the production `AppState.sendMessage` (builder + first-send rerouting + transport
/// fallback + resend without the fragment), injects the upstream replies, and asserts the transport and fragment of
/// every attempt, the reply notice, the records written, and the panel row after sending.
@Suite("RL2-WEBPROBE-SEND · relay web send", .serialized, .sharedProcessState)
@MainActor
struct RelayWebSendContractTests {
    nonisolated private static func loadFixture(_ name: String) throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/relay/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                return (object as? [String: Any]) ?? [:]
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    nonisolated private static let fixture: [String: Any] = (try? loadFixture("web-probe.v1.json")) ?? [:]
    nonisolated private static let chatCases: [[String: Any]] =
        (fixture["chatCases"] as? [String: Any])?["cases"] as? [[String: Any]] ?? []
    nonisolated private static let chatCaseIds = chatCases.compactMap { $0["caseId"] as? String }

    private static var retainedStates: [AppState] = []

    /// Saved fragments that differ from the template (per transport), so a request body can be told apart as saved or template.
    private static let savedRaw: [RelayTransport: String] = [
        .openaiChatCompletions: #"{"web_search_options":{"search_context_size":"low"}}"#,
        .anthropicMessages: #"{"tools":[{"type":"web_search_20250305","name":"web_search","max_uses":2}]}"#,
    ]

    private static let accessDeniedBody =
        #"{"error":{"code":"model_not_found","message":"You do not have access to the model claude-sonnet-4"}}"#

    private static func object(_ raw: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private static func template(_ transport: RelayTransport) throws -> [String: Any] {
        try object(try #require(RelayWebFragments.template(for: transport), "template \(transport.rawValue)"))
    }

    private static func effective(_ transport: RelayTransport, saved: Set<RelayTransport>) throws -> [String: Any] {
        if saved.contains(transport) { return try object(try #require(savedRaw[transport])) }
        return try template(transport)
    }

    /// An unverified Claude-family model on an auto connection: the first catalog endpoint type is anthropic, so the first send uses Messages and the fallback is Chat.
    private static func firstSendMessagesProvider(userOverride: Bool? = nil) -> (Provider, AIModel) {
        var model = AIModel(
            id: "claude-sonnet-4", name: "claude-sonnet-4", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: ""
        )
        if let userOverride { model.relayCapabilityOverrides = RelayCapabilityOverrides(web: userOverride, source: .user) }
        var provider = Provider(
            id: UUID(), kind: .relay, status: .connected, models: [model], catalogModels: [],
            apiKey: "sk-relay", apiKeyPreview: "...elay", baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: .auto)
        )
        provider.baseURLText = "https://websend-\(provider.id.uuidString.lowercased()).example.com/v1"
        RelayCatalogEndpointTypesCache.shared.record(
            endpoint: provider.baseURLText ?? "", endpointTypesByModel: [model.id: ["anthropic", "openai"]]
        )
        return (provider, model)
    }

    private static func cleanUp(_ provider: Provider) {
        RelayWebFragmentStore.shared.deleteConnection(provider.id)
        RelayWebProbeStore.shared.clearConnection(provider.id.uuidString)
        RelayCatalogEndpointTypesCache.shared.record(endpoint: provider.baseURLText ?? "", endpointTypesByModel: [:])
    }

    private static func sseText(_ caseId: String) throws -> String {
        let testCase = try #require((fixture["evidenceCases"] as? [[String: Any]])?.first { $0["caseId"] as? String == caseId })
        return try #require(testCase["sse"] as? [String]).joined(separator: "\n") + "\n"
    }

    /// Fixture `sse` name -> an SSE stream for that transport: plain_text = ordinary body stream for the transport, chat_url_citation = a Chat citation sample.
    private static func sse(_ name: String, transport: RelayTransport) throws -> String {
        switch (name, transport) {
        case ("plain_text", .anthropicMessages): try sseText("messages_text_only_silent")
        case ("plain_text", .openaiChatCompletions): try sseText("chat_text_only_silent")
        case ("chat_url_citation", _): try sseText("chat_url_citation_searched")
        default: throw CocoaError(.featureUnsupported)
        }
    }

    private static func loadMetadata() async throws {
        // The shared metadata fixture has no Chat / Messages web profile: add it per the production catalog contract (same patch as RL2-WEBPROBE-09).
        var root = try loadFixture("metadata-fixture.json")
        var profiles = root["profiles"] as? [String: Any] ?? [:]
        var webSearch = profiles["webSearch"] as? [String: Any] ?? [:]
        webSearch["oai_web_tool"] = [
            "mergeParams": [String: Any](),
            "streamShape": [
                "citationTitleField": "url_citation.title",
                "citationUrlField": "url_citation.url",
                "citationsArrayPath": "choices.0.message.annotations",
            ],
        ]
        webSearch["ant_web_tool"] = [
            "mergeParams": ["tools": [["max_uses": 5, "name": "web_search", "type": "web_search_20250305"]]],
            "streamShape": ["citationSnippetField": "cited_text", "citationsBlockType": "web_search_tool_result"],
        ]
        profiles["webSearch"] = webSearch
        root["profiles"] = profiles
        let metadata = try JSONSerialization.data(withJSONObject: root)
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: String(decoding: metadata, as: UTF8.self))
    }

    private static func makeState(_ provider: Provider) -> AppState {
        let state = AppState(
            seedDemoData: false,
            sessionUID: "relay-web-send-\(UUID().uuidString)",
            providerSession: WebSendProtocol.session()
        )
        retainedStates.append(state)
        state.providers = [provider]
        return state
    }

    private static func waitForReply(_ state: AppState, conversationID: UUID, afterCount: Int) async throws -> ChatMessage? {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if let conversation = state.conversation(for: conversationID), conversation.messages.count > afterCount,
               let message = conversation.messages.last,
               message.role == .assistant, message.state == .failed || message.state == .delivered {
                return message
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return state.conversation(for: conversationID)?.messages.last
    }

    /// One outbound attempt: the transport is read from the path, the fragment from the request body (saved / template / none).
    private struct Attempt: Equatable, CustomStringConvertible {
        let transport: String
        let fragment: String?
        var description: String { "\(transport):\(fragment ?? "null")" }
    }

    private static func carries(_ fragment: [String: Any], in body: [String: Any]) -> Bool {
        fragment.allSatisfy { key, value in
            guard let actual = body[key] else { return false }
            // Array fields (tools) follow the merge rule: the fragment's elements come first, and host tools (such as memory) may follow.
            if let expected = value as? [Any], let actualArray = actual as? [Any] {
                guard actualArray.count >= expected.count else { return false }
                return zip(expected, actualArray).allSatisfy { ($1 as AnyObject).isEqual($0) }
            }
            return (actual as AnyObject).isEqual(value)
        }
    }

    private static func attempts(saved: Set<RelayTransport>) throws -> [Attempt] {
        try WebSendProtocol.requests.map { request in
            let path = request.url?.path ?? ""
            let transport: RelayTransport = path.hasSuffix("/messages") ? .anthropicMessages
                : path.hasSuffix("/responses") ? .openaiResponses : .openaiChatCompletions
            let data = request.httpBody ?? Data()
            let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let template = try template(transport)
            let fragment: String?
            if saved.contains(transport), let raw = savedRaw[transport], carries(try object(raw), in: body) {
                fragment = "saved"
            } else if carries(template, in: body) {
                fragment = "template"
            } else {
                // No web field may be present at all (a leftover that is neither the saved fragment nor the template is wrong too).
                // For array fields only check whether the fragment's elements got mixed in: host tools alone in tools are not a web leftover.
                fragment = template.contains { key, value in
                    guard let actual = body[key] else { return false }
                    guard let expected = value as? [Any], let actualArray = actual as? [Any] else { return true }
                    return expected.contains { element in actualArray.contains { ($0 as AnyObject).isEqual(element) } }
                } ? "partial" : nil
            }
            return Attempt(transport: transport.rawValue, fragment: fragment)
        }
    }

    private static func panelRow(_ state: AppState, providerID: UUID, modelID: String, conversationID: UUID) throws
        -> (row: String, isOn: Bool, transport: RelayTransport) {
        // The panel reads exactly this pair: switch resolution (preference store + default layer) -> web row fact.
        let provider = try #require(state.provider(for: providerID))
        let model = try #require(provider.models.first { $0.id == modelID })
        let preference = RelayWebSwitch.isOn(provider: provider, model: model, conversationID: conversationID)
        guard case let .relay(fact) = RelayWebProbe.panelFact(provider: provider, model: model, preference: preference) else {
            throw CocoaError(.featureUnsupported)
        }
        return (fact.row.rawValue, fact.isOn, RelayWebProbe.transport(provider: provider, model: model))
    }

    // MARK: SEND × chatCases

    @Test("RL2-WEBPROBE-SEND", arguments: chatCaseIds)
    func send(caseId: String) async throws {
        let label = "RL2-WEBPROBE-SEND-\(caseId)"
        #expect(Self.chatCaseIds.count == 10, "\(label) fixture count")
        let testCase = try #require(Self.chatCases.first { $0["caseId"] as? String == caseId }, "\(label)")
        let expect = try #require(testCase["expect"] as? [String: Any])
        let expectedAttempts = try #require(expect["attempts"] as? [[String: Any]])
        let (provider, model) = Self.firstSendMessagesProvider(userOverride: testCase["userOverride"] as? Bool)
        defer { Self.cleanUp(provider) }
        #expect(RelayWebProbe.transport(provider: provider, model: model).rawValue == testCase["firstTransport"] as? String,
                "\(label) precondition: first transport")

        let saved = Set((testCase["savedFragments"] as? [String] ?? []).compactMap(RelayTransport.init(rawValue:)))
        for transport in saved {
            #expect(RelayWebFragmentStore.shared.save(
                connectionID: provider.id, transport: transport, raw: try #require(Self.savedRaw[transport])
            ) == nil, "\(label) saved fragment")
        }
        var before: [RelayTransport: RelayWebProbeRecord] = [:]
        for (key, result) in testCase["records"] as? [String: String] ?? [:] {
            let transport = try #require(RelayTransport(rawValue: key))
            RelayWebProbeStore.shared.record(
                connectionID: provider.id.uuidString, modelID: model.id, transport: key,
                result: try #require(RelayWebProbeRecord.Result(rawValue: result)), source: .tested,
                fragmentHash: RelayWebProbe.fragmentHash(try Self.effective(transport, saved: saved))
            )
            before[transport] = RelayWebProbeStore.shared.record(connectionID: provider.id.uuidString, modelID: model.id, transport: key)
        }

        var replies: [(Int, String)] = []
        for (index, attempt) in (testCase["attempts"] as? [[String: Any]] ?? []).enumerated() {
            let status = try #require(attempt["status"] as? Int)
            if let name = attempt["sse"] as? String {
                let transport = try #require(RelayTransport(rawValue: expectedAttempts[index]["transport"] as? String ?? ""))
                replies.append((status, try Self.sse(name, transport: transport)))
            } else if attempt["classification"] as? String == "model_access_denied" {
                replies.append((status, Self.accessDeniedBody))
            } else {
                replies.append((status, try #require(attempt["body"] as? String)))
            }
        }

        try await Self.loadMetadata()
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        WebSendProtocol.reset(replies)
        let state = Self.makeState(provider)
        let conversation = TestFactories.makeConversation(providerID: provider.id, providerKind: .relay, modelID: model.id)
        state.upsertConversationProjection(conversation)
        // The user flips the switch in the panel (conversation scope).
        RelayWebSwitch.write(testCase["webOn"] as? Bool == true, provider: provider, model: model, conversationID: conversation.id)
        _ = await state.sendMessage("search the news", attachments: [], in: conversation.id, capabilitySelection: ChatCapabilitySelection())
        let message = try #require(try await Self.waitForReply(state, conversationID: conversation.id, afterCount: 0), "\(label) no reply")

        let sent = try Self.attempts(saved: saved)
        let wanted = expectedAttempts.map {
            Attempt(transport: $0["transport"] as? String ?? "", fragment: $0["fragment"] as? String)
        }
        #expect(sent == wanted, "\(label) attempts")
        let sendFails = expect["sendFails"] as? Bool == true
        #expect(message.state == (sendFails ? .failed : .delivered), "\(label) delivered: \(message.state) \(message.errorDetail ?? "")")
        let notice = state.chatManager.relayWebReplyNotice(messageID: message.id)
        #expect(notice?.rawValue == expect["replyNotice"] as? String, "\(label) replyNotice: \(String(describing: notice))")

        let writes = expect["recordWrites"] as? [[String: Any]] ?? []
        for transport in [RelayTransport.anthropicMessages, .openaiChatCompletions] {
            let record = RelayWebProbeStore.shared.record(
                connectionID: provider.id.uuidString, modelID: model.id, transport: transport.rawValue
            )
            if let write = writes.first(where: { $0["transport"] as? String == transport.rawValue }) {
                #expect(record?.result.rawValue == write["result"] as? String, "\(label) \(transport.rawValue) result: \(String(describing: record))")
                #expect(record?.source.rawValue == write["source"] as? String, "\(label) \(transport.rawValue) source")
                #expect(record?.fragmentHash == RelayWebProbe.fragmentHash(try Self.effective(transport, saved: saved)),
                        "\(label) \(transport.rawValue) current hash")
            } else {
                #expect(record == before[transport], "\(label) \(transport.rawValue) not written: \(String(describing: record))")
            }
        }

        let panel = try #require(expect["panelAfter"] as? [String: Any])
        let row = try Self.panelRow(state, providerID: provider.id, modelID: model.id, conversationID: conversation.id)
        #expect(row.row == panel["row"] as? String, "\(label) panelAfter.row")
        #expect(row.isOn == panel["isOn"] as? Bool, "\(label) panelAfter.isOn")
    }

    // MARK: First-chat scenario (chatCases.scenario)

    @Test("RL2-WEBPROBE-SEND-first_chat_toggle_survives: turn web on in a new conversation -> first send on Messages gets 404 -> fallback to Chat is delivered -> the panel and a reopen still show on, and the second send goes to Chat with the template")
    func firstChatToggleSurvives() async throws {
        let label = "RL2-WEBPROBE-SEND-first_chat_toggle_survives"
        let scenario = try #require((Self.fixture["chatCases"] as? [String: Any])?["scenario"] as? [String: Any])
        let expect = try #require(scenario["expect"] as? [String: Any])
        let (provider, model) = Self.firstSendMessagesProvider()
        defer { Self.cleanUp(provider) }
        let notFound = #"{"error":{"message":"Invalid URL (POST /v1/messages)"}}"#

        try await Self.loadMetadata()
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        WebSendProtocol.reset([(404, notFound), (200, try Self.sse("plain_text", transport: .openaiChatCompletions))])
        let state = Self.makeState(provider)
        state.setActiveModel(providerID: provider.id, modelID: model.id)

        // A new conversation (no conversation id yet): the panel and the composer both address by the draft id; the user turns web on in the panel.
        let draft = UUID()
        #expect(RelayWebSwitch.isOn(provider: provider, model: model, conversationID: draft) == false, "\(label) precondition: never set = off")
        RelayWebSwitch.write(true, provider: provider, model: model, conversationID: draft)
        let composerOn = RelayWebProbe.fact(
            provider: provider, model: model,
            preference: RelayWebSwitch.isOn(provider: provider, model: model, conversationID: draft)
        )?.isOn
        #expect(composerOn == true, "\(label) precondition: composer web is on")
        var selection = ChatCapabilitySelection()
        selection.webSearchEnabled = composerOn == true

        _ = await state.sendMessage(
            "search the news", attachments: [], in: nil, generationParameterDraftSessionID: draft, capabilitySelection: selection
        )
        let conversationID = try #require(state.conversations.first?.id, "\(label) sending creates the conversation")
        let first = try #require(try await Self.waitForReply(state, conversationID: conversationID, afterCount: 0))
        #expect(first.state == .delivered, "\(label) first message delivered: \(first.errorDetail ?? "")")
        let firstAttempts = try Self.attempts(saved: [])
        #expect(firstAttempts == [
            Attempt(transport: "anthropic_messages", fragment: "template"),
            Attempt(transport: "openai_chat_completions", fragment: "template"),
        ], "\(label) first message, two attempts")

        let panel = try #require(expect["panelAfter"] as? [String: Any])
        // Opening the model options panel after sending (`ModelControlsSheet.restoreStoredSelection`) and reopening the
        // conversation (`ChatView` re-reading the composer web state) read the same pair: switch resolution addressed by
        // the conversation id + the web row fact. State lives only in the preference store and the model, so both reads must agree.
        for moment in ["panel", "reopen"] {
            let row = try Self.panelRow(state, providerID: provider.id, modelID: model.id, conversationID: conversationID)
            #expect(row.row == panel["row"] as? String, "\(label) \(moment) row")
            let draftOn = RelayWebSwitch.isOn(provider: provider, model: model, conversationID: draft)
            #expect(row.isOn == panel["isOn"] as? Bool, "\(label) \(moment) isOn (still reads \(String(describing: draftOn)) under the draft id)")
            #expect(row.transport == .openaiChatCompletions, "\(label) \(moment) first transport is now recorded as Chat")
        }

        let second = try #require(expect["secondSendFirstAttempt"] as? [String: Any])
        WebSendProtocol.reset([(200, try Self.sse("plain_text", transport: .openaiChatCompletions))])
        let count = state.conversation(for: conversationID)?.messages.count ?? 0
        _ = await state.sendMessage("again", attachments: [], in: conversationID, capabilitySelection: selection)
        let reply = try #require(try await Self.waitForReply(state, conversationID: conversationID, afterCount: count))
        #expect(reply.state == .delivered, "\(label) second message delivered: \(reply.errorDetail ?? "")")
        let secondFirst = try Self.attempts(saved: []).first
        #expect(secondFirst == Attempt(
            transport: second["transport"] as? String ?? "", fragment: second["fragment"] as? String
        ), "\(label) second first-send")
    }
}

private final class WebSendProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var _requests: [URLRequest] = []
    nonisolated(unsafe) private static var _script: [(status: Int, body: String)] = []
    private static let lock = NSLock()

    static func reset(_ replies: [(Int, String)] = []) {
        lock.withLock {
            _requests = []
            _script = replies.map { ($0.0, $0.1) }
        }
    }

    static var requests: [URLRequest] { lock.withLock { _requests } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebSendProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func readStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let data = Self.readStream(request.httpBodyStream) {
            recorded.httpBody = data
        }
        // Still sending after the script ran out means one request too many: answer 599 so it fails and the attempt list shows up in the assertion.
        let next: (status: Int, body: String) = Self.lock.withLock {
            Self._requests.append(recorded)
            return Self._script.isEmpty ? (599, #"{"error":{"message":"unscripted"}}"#) : Self._script.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://relay.invalid")!, statusCode: next.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": next.status == 200 ? "text/event-stream" : "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
