import Foundation
import Testing
@testable import Oriveo

/// Relay first-send protocol read points (the `firstSendCases` of the shared fixture `relay/first-send-readpoints.v1.json`).
/// Each case reads five points through the production entry points: the first-send protocol, the input entry (which protocol the
/// attachment entry reads the envelope with), the evidence identity (the protocol of `uiDispatchIdentity`), the catalog source
/// (model library protocol column and filter), and the advanced page's "Auto =".
/// It also covers the negative cache key (read and clear), the tool final transport, and the key a rejection is recorded under
/// (the protocol actually sent this turn); inputRevisionCases lock the input key revision.
@Suite("Relay first-send protocol read points contract", .serialized, .sharedProcessState)
@MainActor
struct RelayFirstSendReadpointsContractTests {
    private static let partitionID = "relay-first-send-readpoints-tests"

    private struct Case {
        let id: String
        let connectionProtocol: String
        let modelProtocol: String?
        let modelProtocolSource: String?
        let firstCandidate: String?
        var turnFellBackToChatForFiles = false
        let expect: JSONObject
    }

    private static func sharedFixtureURL(_ relativePath: String) throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/\(relativePath)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func cases() throws -> [Case] {
        let root = try JSONValue(data: Data(contentsOf: sharedFixtureURL("relay/first-send-readpoints.v1.json")))
        return try #require(root["firstSendCases"]?.arrayValue).map { item in
            Case(
                id: try #require(item["id"]?.stringValue),
                connectionProtocol: try #require(item["connectionProtocol"]?.stringValue),
                modelProtocol: item["modelProtocol"]?.stringValue,
                modelProtocolSource: item["modelProtocolSource"]?.stringValue,
                firstCandidate: item["firstCandidate"]?.stringValue,
                turnFellBackToChatForFiles: item["turnFellBackToChatForFiles"]?.boolValue ?? false,
                expect: try #require(item["expect"]?.objectValue)
            )
        }
    }

    private static func transport(_ name: String) throws -> RelayTransport {
        switch name {
        case "auto": return .auto
        case "chat": return .openaiChatCompletions
        case "responses": return .openaiResponses
        case "messages": return .anthropicMessages
        case "gemini": return .geminiGenerateContent
        default: throw CocoaError(.coderInvalidValue)
        }
    }

    private static func endpointType(_ name: String) throws -> String {
        switch name {
        case "chat": return "openai"
        case "responses": return "openai-response"
        case "messages": return "anthropic"
        case "gemini": return "gemini"
        default: throw CocoaError(.coderInvalidValue)
        }
    }

    /// One fixture case -> connection and model. The first candidate is written into this session's catalog endpoint types cache (keyed by each case's own connection address).
    private static func setup(_ item: Case, configure: (inout AIModel) -> Void = { _ in }) throws -> (Provider, AIModel) {
        let modelID = "first-send-\(item.id)"
        var model = TestFactories.makeModel(id: modelID, capabilities: [.text])
        configure(&model)
        if let own = item.modelProtocol {
            model.relayTransport = try transport(own)
            model.relayTransportSource = item.modelProtocolSource == "user" ? .user : .observed
        }
        let baseURL = "https://first-send-\(item.id).relay.test"
        var provider = TestFactories.makeProvider(
            kind: .relay, models: [model], catalogModels: [model],
            apiKey: "sk-test", apiKeyPreview: "sk-…test", baseURLText: baseURL
        )
        provider.relayRequested = RelayRequestedConfig(
            transport: try transport(item.connectionProtocol),
            authMode: .bearer, securityMode: .remoteHTTPS, engineProfile: nil
        )
        let types = try item.firstCandidate.map { [try endpointType($0)] } ?? []
        RelayCatalogEndpointTypesCache.shared.record(endpoint: baseURL, endpointTypesByModel: [modelID: types])
        return (provider, model)
    }

    private static func expected(_ item: Case, _ key: String) throws -> RelayTransport? {
        guard let value = item.expect[key] else { return nil }
        return try value.stringValue.map(transport)
    }

    private static func check(_ caseID: String) throws {
        let item = try #require(try cases().first { $0.id == caseID })
        let (provider, model) = try setup(item)
        defer { RelayCatalogEndpointTypesCache.shared.record(endpoint: provider.baseURLText ?? "", endpointTypesByModel: [:]) }

        // firstSend
        let firstSend = RelayFirstSendTransport.current(provider: provider, model: model)
        #expect(firstSend == (try expected(item, "firstSend")), "firstSend")

        // inputEntry: which protocol the attachment entry reads the Relay input envelope with.
        if item.expect.keys.contains("inputEntry") {
            var readWith: RelayTransport?
            let projection = CapabilityEvidenceProductionAdapter.capabilityProjection(
                provider: provider, model: model, identity: nil,
                keys: Set(CapabilityEvidenceFacade.inputCapabilityKeys)
            )
            _ = CapabilityEvidenceFacade.attachmentImportEntry(
                provider: provider, model: model, projection: projection,
                relayInputEnvelope: { readWith = $0; return nil }
            )
            #expect(readWith == (try expected(item, "inputEntry")), "inputEntry")
        }

        // evidenceIdentity: auto no longer fails closed; it takes the first-send protocol.
        if item.expect.keys.contains("evidenceIdentity") {
            let identity = CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
                provider: provider, model: model, partitionID: partitionID
            )
            #expect(identity?.query.effectiveTransport == (try expected(item, "evidenceIdentity"))?.rawValue, "evidenceIdentity")
        }

        // boardCatalogSource: the model library protocol column and the protocol filter share one source.
        if let source = try expected(item, "boardCatalogSource") {
            let row = RelayCatalogBoardModel.row(
                provider: provider, model: model, section: .enabled,
                isMissingFromCatalog: false, partitionID: partitionID
            )
            #expect(row.protocolTransport == source, "boardCatalogSource")
            #expect(RelayCatalogBoardModel.matches(.transport(source), provider: provider, model: model), "boardCatalogSource filter")
        }

        // boardAutoEquals: null only when the user chose the protocol (model-level user choice or the connection's chosen protocol).
        if item.expect.keys.contains("boardAutoEquals") {
            let board = RelayModelAdvancedBoard.make(provider: provider, model: model, partitionID: partitionID)
            var autoEquals: RelayTransport?
            if case let .relay(_, auto, _, _) = board.protocolRow, case let .detected(value)? = auto {
                autoEquals = value
            }
            #expect(autoEquals == (try expected(item, "boardAutoEquals")), "boardAutoEquals")
        }

        // negativeCacheKey: verdicts and the file read point read this key; capability overrides and tier changes clear this same key.
        if let key = try expected(item, "negativeCacheKey") {
            try checkNegativeCacheKey(provider: provider, model: model, key: key)
        }

        // toolFinalTransport: auto also has a conclusion (the first-send protocol) and is no longer undecided.
        if let tool = try expected(item, "toolFinalTransport") {
            let name = try #require(ToolCallCapabilityPolicy.transportKindName(for: tool))
            #expect(ToolCallCapabilityPolicy.finalTransportKindName(provider: provider, model: model) == name, "toolFinalTransport")
            let decision = ToolCallCapabilityPolicy.decide(provider: provider, model: model)
            #expect(decision.transport == name, "toolFinalTransport decide")
            #expect(decision.decided, "toolFinalTransport decided")
        }

        // turnSentWith: the protocol actually sent this turn uses the production send criterion (file fallback = carries a file with no extracted text that Messages cannot send natively).
        var turnSentWith: RelayTransport?
        if let expectedSent = try expected(item, "turnSentWith") {
            let textless = [fileAttachment(name: "scan.docx", hasExtractedText: false, messagesNative: false)]
            let sent = sentTransport(
                provider: provider, model: model,
                messages: [TestFactories.makeMessage(attachments: item.turnFellBackToChatForFiles ? textless : nil)]
            )
            #expect(sent == expectedSent, "turnSentWith")
            turnSentWith = sent
        }

        // rejectionRecordedUnder: a rejection is recorded under the protocol actually sent this turn (turnSentWith), not the first-send protocol.
        if let recorded = try expected(item, "rejectionRecordedUnder") {
            let sent = try #require(turnSentWith)
            let cache = freshNegativeCache()
            NativeFileFallback.rememberTextOnly(
                .relayScope(sent, connectionID: provider.id, modelID: model.id),
                rejectedStatusCode: 400, negativeCache: cache,
                capabilityNegativeCache: CapabilityNegativeCache(defaults: freshDefaults())
            )
            let connection = provider.id.uuidString
            #expect(cache.isRejected(connectionID: connection, modelID: model.id, transport: recorded.rawValue, kind: .file), "rejectionRecordedUnder")
            if recorded != firstSend {
                #expect(!cache.isRejected(connectionID: connection, modelID: model.id, transport: firstSend.rawValue, kind: .file), "rejectionRecordedUnder: no entry under the first-send key")
                #expect(!NativeFileFallback.isKnownTextOnly(
                    .relayScope(firstSend, connectionID: provider.id, modelID: model.id), negativeCache: cache
                ), "the first-send read point is unaffected by a rejection of the protocol actually sent")
            }
        }
    }

    private static var retainedStates: [AppState] = []

    private static func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "relay-first-send-readpoints-\(UUID().uuidString)")!
    }

    private static func freshNegativeCache() -> RelayNegativeCache {
        RelayNegativeCache(defaults: freshDefaults())
    }

    private static func checkNegativeCacheKey(provider: Provider, model: AIModel, key: RelayTransport) throws {
        let connection = provider.id.uuidString
        // Read: the tool verdict and the file read point (the same relayScope as the composer's attachment decision).
        let cache = freshNegativeCache()
        cache.record(connectionID: connection, modelID: model.id, transport: key.rawValue, kind: .toolCall)
        cache.record(connectionID: connection, modelID: model.id, transport: key.rawValue, kind: .file)
        #expect(ToolCallCapabilityPolicy.catalogVerdict(provider: provider, model: model, negativeCache: cache).verdict == false,
                "negativeCacheKey toolCall")
        #expect(NativeFileFallback.isKnownTextOnly(
            .relayScope(RelayFirstSendTransport.current(provider: provider, model: model), connectionID: provider.id, modelID: model.id),
            negativeCache: cache
        ), "negativeCacheKey file")

        // Clear: capability row overrides and reasoning tier changes go through the production ProviderManager and clear the same key.
        let state = AppState(seedDemoData: false, sessionUID: "relay-first-send-readpoints-\(UUID().uuidString)")
        retainedStates.append(state)
        state.providers = [provider]
        let shared = RelayNegativeCache.shared
        defer { shared.clearConnection(connection) }
        let kinds: [RelayNegativeCache.Kind] = [.toolCall, .file] + RelayReasoningTier.kinds.sorted { $0.rawValue < $1.rawValue }
        for kind in kinds {
            shared.record(connectionID: connection, modelID: model.id, transport: key.rawValue, kind: kind)
        }
        state.providerManager.setRelayCapabilityOverride(providerID: provider.id, modelID: model.id, key: .toolCall, value: true)
        state.providerManager.setRelayCapabilityOverride(providerID: provider.id, modelID: model.id, key: .file, value: true)
        state.providerManager.setRelayReasoningLevels(providerID: provider.id, modelID: model.id, levels: nil)
        for kind in kinds {
            #expect(!shared.isRejected(connectionID: connection, modelID: model.id, transport: key.rawValue, kind: kind),
                    "negativeCacheKey clear \(kind)")
        }
    }

    // MARK: - fileFallbackCases: a first-send Messages turn falls back to effectiveTransport because of files

    private struct FileSpec {
        let hasExtractedText: Bool
        let messagesNative: Bool
    }

    private struct FileFallbackCase {
        let id: String
        let firstSend: RelayTransport
        let effectiveTransport: RelayTransport
        let files: [FileSpec]
        let historyFiles: [FileSpec]
        let images: Int
        let turnSentWith: RelayTransport
    }

    private static func fileSpecs(_ value: JSONValue?) throws -> [FileSpec] {
        try (value?.arrayValue ?? []).map { file in
            FileSpec(
                hasExtractedText: try #require(file["hasExtractedText"]?.boolValue),
                messagesNative: try #require(file["messagesNative"]?.boolValue)
            )
        }
    }

    private static func fileFallbackCases() throws -> [FileFallbackCase] {
        let root = try JSONValue(data: Data(contentsOf: sharedFixtureURL("relay/first-send-readpoints.v1.json")))
        return try #require(root["fileFallbackCases"]?.arrayValue).map { item in
            FileFallbackCase(
                id: try #require(item["id"]?.stringValue),
                firstSend: try transport(try #require(item["firstSend"]?.stringValue)),
                effectiveTransport: try transport(try #require(item["effectiveTransport"]?.stringValue)),
                files: try fileSpecs(item["files"]),
                historyFiles: try fileSpecs(item["historyFiles"]),
                images: item["images"]?.intValue ?? 0,
                turnSentWith: try transport(try #require(item["expect"]?["turnSentWith"]?.stringValue))
            )
        }
    }

    /// What Messages can send natively = a PDF on the model's allowlist that carries the original; what it cannot = a docx outside the allowlist (text extraction only).
    private static let nativePdfMime = "application/pdf"

    private static func fileAttachment(name: String, hasExtractedText: Bool, messagesNative: Bool) -> Oriveo.Attachment {
        Oriveo.Attachment(
            id: UUID(), kind: .file, fileName: name,
            mimeType: messagesNative
                ? nativePdfMime
                : "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            base64Data: hasExtractedText ? Data("extracted text".utf8).base64EncodedString() : nil,
            originalBase64Data: Data("%PDF-1.4 original".utf8).base64EncodedString()
        )
    }

    private static func attachments(_ specs: [FileSpec], prefix: String) -> [Oriveo.Attachment] {
        specs.enumerated().map { index, spec in
            fileAttachment(
                name: "\(prefix)-\(index).\(spec.messagesNative ? "pdf" : "docx")",
                hasExtractedText: spec.hasExtractedText, messagesNative: spec.messagesNative
            )
        }
    }

    /// Production send criterion: the attachments of the whole outbound history go to `ChatManager.relayFirstSendTransport`; nil = send on the current route (effectiveTransport).
    private static func sentTransport(provider: Provider, model: AIModel, messages: [ChatMessage]) -> RelayTransport {
        let current = RelayEndpointResolver.effectiveTransport(provider: provider, model: model)
        return ChatManager.relayFirstSendTransport(
            provider: provider, model: model, current: current,
            attachments: messages.flatMap { $0.attachments ?? [] }
        ) ?? current
    }

    private static func checkFileFallback(_ caseID: String) throws {
        let item = try #require(try fileFallbackCases().first { $0.id == caseID })
        // The fixture only uses "first send Messages, effective Chat": an auto connection plus a catalog first candidate of Messages.
        let setupCase = Case(
            id: "file-\(item.id)", connectionProtocol: "auto", modelProtocol: nil, modelProtocolSource: nil,
            firstCandidate: item.firstSend == .anthropicMessages ? "messages" : nil, expect: JSONObject()
        )
        let (provider, model) = try setup(setupCase) { model in
            model.nativeFileMimes = [nativePdfMime]
            model.pdfNativeDefault = true
        }
        defer { RelayCatalogEndpointTypesCache.shared.record(endpoint: provider.baseURLText ?? "", endpointTypesByModel: [:]) }
        #expect(RelayFirstSendTransport.current(provider: provider, model: model) == item.firstSend, "firstSend")
        #expect(RelayEndpointResolver.effectiveTransport(provider: provider, model: model) == item.effectiveTransport, "effectiveTransport")

        let images = (0..<item.images).map { index in
            Oriveo.Attachment(id: UUID(), kind: .image, fileName: "image-\(index).png", mimeType: "image/png")
        }
        var messages: [ChatMessage] = []
        if !item.historyFiles.isEmpty {
            messages.append(TestFactories.makeMessage(text: "earlier", attachments: attachments(item.historyFiles, prefix: "history")))
            messages.append(TestFactories.makeMessage(role: .assistant, text: "reply"))
        }
        let current = attachments(item.files, prefix: "turn") + images
        messages.append(TestFactories.makeMessage(text: "now", attachments: current.isEmpty ? nil : current))

        #expect(sentTransport(provider: provider, model: model, messages: messages) == item.turnSentWith, "turnSentWith")
    }

    @Test("RELAY_FIRST_SEND fileFallbackCases id set matches the fixture")
    func fileFallbackIdSetLock() throws {
        #expect(try Self.fileFallbackCases().map(\.id) == [
            "all_files_textless_messages_cannot_native_falls_back",
            "file_with_text_stays_on_messages",
            "messages_sends_file_natively_stays",
            "one_textless_one_with_text_stays",
            "history_textless_file_falls_back",
            "images_only_never_fall_back",
        ])
    }

    @Test("RELAY_FIRST_SEND_all_files_textless_messages_cannot_native_falls_back")
    func allFilesTextlessMessagesCannotNativeFallsBack() throws {
        try Self.checkFileFallback("all_files_textless_messages_cannot_native_falls_back")
    }

    @Test("RELAY_FIRST_SEND_file_with_text_stays_on_messages")
    func fileWithTextStaysOnMessages() throws { try Self.checkFileFallback("file_with_text_stays_on_messages") }

    @Test("RELAY_FIRST_SEND_messages_sends_file_natively_stays")
    func messagesSendsFileNativelyStays() throws { try Self.checkFileFallback("messages_sends_file_natively_stays") }

    @Test("RELAY_FIRST_SEND_one_textless_one_with_text_stays")
    func oneTextlessOneWithTextStays() throws { try Self.checkFileFallback("one_textless_one_with_text_stays") }

    @Test("RELAY_FIRST_SEND_history_textless_file_falls_back")
    func historyTextlessFileFallsBack() throws { try Self.checkFileFallback("history_textless_file_falls_back") }

    @Test("RELAY_FIRST_SEND_images_only_never_fall_back")
    func imagesOnlyNeverFallBack() throws { try Self.checkFileFallback("images_only_never_fall_back") }

    // MARK: - inputRevisionCases: input key revision = hash of the verdict the facade synthesizes

    private struct RevisionCase {
        let id: String
        let key: String
        let connectionEvidence: String?
        let firstSend: String
        let canonical: String
        let revision: String
    }

    private static func revisionCases() throws -> [RevisionCase] {
        let root = try JSONValue(data: Data(contentsOf: sharedFixtureURL("relay/first-send-readpoints.v1.json")))
        return try #require(root["inputRevisionCases"]?.arrayValue).map { item in
            RevisionCase(
                id: try #require(item["id"]?.stringValue),
                key: try #require(item["key"]?.stringValue),
                connectionEvidence: item["connectionEvidence"]?.stringValue,
                firstSend: try #require(item["firstSend"]?.stringValue),
                canonical: try #require(item["canonical"]?.stringValue),
                revision: try #require(item["revision"]?.stringValue)
            )
        }
    }

    /// Connection evidence is given through override values (tested override true / false); null = no override, no engine declaration, and the list does not declare image recognition.
    private static func checkRevision(_ caseID: String) throws {
        let item = try #require(try revisionCases().first { $0.id == caseID })
        let modelID = "input-revision-\(item.id)"
        var model = TestFactories.makeModel(id: modelID, capabilities: [.text])
        switch item.connectionEvidence {
        case "supported"?: model.relayCapabilityOverrides = RelayCapabilityOverrides(image: true, source: .tested)
        case "unsupported"?: model.relayCapabilityOverrides = RelayCapabilityOverrides(image: false, source: .tested)
        case nil: break
        default: throw CocoaError(.coderInvalidValue)
        }
        let firstSend = try transport(item.firstSend)
        var provider = TestFactories.makeProvider(
            kind: .relay, models: [model], catalogModels: [model],
            apiKey: "sk-test", apiKeyPreview: "sk-…test", baseURLText: "https://input-revision-\(item.id).relay.test"
        )
        provider.relayRequested = RelayRequestedConfig(
            transport: firstSend, authMode: .bearer, securityMode: .remoteHTTPS, engineProfile: nil
        )
        #expect(RelayFirstSendTransport.current(provider: provider, model: model) == firstSend, "firstSend")
        let family = try #require(CapabilityEvidenceProductionAdapter.relayWireFamily(transport: firstSend, key: item.key))
        let verdict = CapabilityEvidenceProductionAdapter.relayInputVerdict(
            key: item.key,
            visionEvidence: CapabilityEvidenceProductionAdapter.relayVisionEvidence(provider: provider, model: model),
            wireFamily: family
        )
        #expect(Array(CapabilityNegativeCache.canonical(verdict).utf8) == Array(item.canonical.utf8), "canonical")
        #expect(CapabilityNegativeCache.verdictRevision(verdict) == item.revision, "revision")
        #expect(item.revision != CapabilityNegativeCache.verdictRevision(nil), "not the hash of a missing verdict")

        // The revision recorded on the write side (rejection loop) is byte-identical to the fixture: image recognition goes through recordImageRejection, files through rememberTextOnly.
        let v2 = CapabilityNegativeCache(defaults: freshDefaults())
        let rejected = RelayPreOutputRejection(
            status: 400, contentType: "application/json", body: Data(#"{"error":{"message":"x"}}"#.utf8)
        )
        switch item.key {
        case CapabilityEvidenceFacade.visionInputKey where item.connectionEvidence != "supported":
            #expect(RelayRejectionRecording.recordImageRejection(
                provider: provider, model: model, transport: firstSend, rejection: rejected,
                negativeCache: freshNegativeCache(), capabilityNegativeCache: v2
            ), "recordImageRejection")
        case CapabilityEvidenceFacade.fileInputKey:
            NativeFileFallback.rememberTextOnly(
                .relayScope(firstSend, connectionID: provider.id, modelID: model.id),
                rejectedStatusCode: 400, negativeCache: freshNegativeCache(), capabilityNegativeCache: v2
            )
        default:
            return
        }
        let entry = try #require(v2.entry(
            connectionId: provider.id.uuidString, modelId: model.id, wireFamily: family, capabilityKey: item.key
        ), "write-side v2 entry")
        #expect(entry.verdictRevision == item.revision, "write-side revision")
    }

    @Test("RELAY_FIRST_SEND inputRevisionCases id set matches the fixture")
    func inputRevisionIdSetLock() throws {
        #expect(try Self.revisionCases().map(\.id) == [
            "relay_vision_supported_chat",
            "relay_vision_unsupported_chat",
            "relay_vision_unknown_chat",
            "relay_vision_unknown_messages",
            "relay_file_silent_chat",
            "relay_video_silent_chat",
        ])
    }

    @Test("RELAY_FIRST_SEND_relay_vision_supported_chat")
    func relayVisionSupportedChat() throws { try Self.checkRevision("relay_vision_supported_chat") }

    @Test("RELAY_FIRST_SEND_relay_vision_unsupported_chat")
    func relayVisionUnsupportedChat() throws { try Self.checkRevision("relay_vision_unsupported_chat") }

    @Test("RELAY_FIRST_SEND_relay_vision_unknown_chat")
    func relayVisionUnknownChat() throws { try Self.checkRevision("relay_vision_unknown_chat") }

    @Test("RELAY_FIRST_SEND_relay_vision_unknown_messages")
    func relayVisionUnknownMessages() throws { try Self.checkRevision("relay_vision_unknown_messages") }

    @Test("RELAY_FIRST_SEND_relay_file_silent_chat")
    func relayFileSilentChat() throws { try Self.checkRevision("relay_file_silent_chat") }

    @Test("RELAY_FIRST_SEND_relay_video_silent_chat")
    func relayVideoSilentChat() throws { try Self.checkRevision("relay_video_silent_chat") }

    @Test("RELAY_FIRST_SEND case id set matches the fixture")
    func idSetLock() throws {
        #expect(try Self.cases().map(\.id) == [
            "auto_claude_family_messages",
            "auto_other_family_chat",
            "auto_no_candidate_chat",
            "model_protocol_wins",
            "model_protocol_detected_auto_equals",
            "connection_protocol_wins",
            "attachment_fallback_records_under_sent",
        ])
    }

    @Test("RELAY_FIRST_SEND_auto_claude_family_messages")
    func autoClaudeFamilyMessages() throws { try Self.check("auto_claude_family_messages") }

    @Test("RELAY_FIRST_SEND_auto_other_family_chat")
    func autoOtherFamilyChat() throws { try Self.check("auto_other_family_chat") }

    @Test("RELAY_FIRST_SEND_auto_no_candidate_chat")
    func autoNoCandidateChat() throws { try Self.check("auto_no_candidate_chat") }

    @Test("RELAY_FIRST_SEND_model_protocol_wins")
    func modelProtocolWins() throws { try Self.check("model_protocol_wins") }

    @Test("RELAY_FIRST_SEND_model_protocol_detected_auto_equals")
    func modelProtocolDetectedAutoEquals() throws { try Self.check("model_protocol_detected_auto_equals") }

    @Test("RELAY_FIRST_SEND_connection_protocol_wins")
    func connectionProtocolWins() throws { try Self.check("connection_protocol_wins") }

    @Test("RELAY_FIRST_SEND_attachment_fallback_records_under_sent")
    func attachmentFallbackRecordsUnderSent() throws { try Self.check("attachment_fallback_records_under_sent") }
}
