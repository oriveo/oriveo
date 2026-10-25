import Foundation
import Testing
@testable import Oriveo

/// An official connection sends an image and the upstream rejects it by signature before any output:
/// a v2 negative-cache entry is recorded (revision taken from the verdict at that time). A miss, a request
/// that already had output, a request without an image, and Relay record nothing.
/// After recording, the production projection shows the vision input as rejected_recently and the outbound
/// part becomes a placeholder.
@Suite("InputRejectionFlow", .serialized, .sharedProcessState)
struct InputRejectionFlowTests {
    private static let metadataETag = "input-rejection-flow"
    private static let family = "openai_chat.image_url"
    private static let visionKey = CapabilityEvidenceFacade.visionInputKey
    private static let rejectedBody = #"{"error":{"message":"Unexpected item type in content.","type":"invalid_request_error"}}"#

    private static func control(state: String = "auto_available") throws -> MetadataClient.CapabilityControl {
        let json = #"{"state":"\#(state)","sourceRefs":["qwen.docs"],"wireFamily":"\#(family)"}"#
        return try JSONDecoder().decode(MetadataClient.CapabilityControl.self, from: Data(json.utf8))
    }

    private static func attempt(
        form: ProviderForm = .official,
        outputStarted: Bool = false,
        carried: Set<String> = [visionKey],
        status: Int? = 400,
        body: String? = rejectedBody,
        connectionId: String = UUID().uuidString
    ) throws -> InputRejectionFlow.Attempt {
        .init(
            form: form, connectionId: connectionId, modelId: "input-model",
            outputStarted: outputStarted, carriedCapabilityKeys: carried,
            httpStatus: status, rawBody: body, controls: [visionKey: try control()]
        )
    }

    private static func isolatedCache() -> CapabilityNegativeCache {
        let suite = "InputRejectionFlowTests.\(UUID().uuidString)"
        return CapabilityNegativeCache(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test("Official + before output + signature match + image carried: records a v2 entry")
    func recordsOnMatch() throws {
        let cache = Self.isolatedCache()
        let attempt = try Self.attempt()
        let rejection = try #require(InputRejectionFlow.record(attempt, negativeCache: cache))

        let expectedRevision = CapabilityNegativeCache.verdictRevision(.init(
            state: "auto_available", wireFamily: Self.family, sourceRefs: ["qwen.docs"]
        ))
        let entry = try #require(cache.entry(
            connectionId: attempt.connectionId, modelId: "input-model", wireFamily: Self.family, capabilityKey: Self.visionKey
        ))
        #expect(entry.signatureId == "dashscope.unexpected_item_type")
        #expect(entry.verdictRevision == expectedRevision)
        #expect(rejection.verdictRevision == expectedRevision)
        #expect(rejection.capabilityKey == Self.visionKey)
        #expect(rejection.signatureId == "dashscope.unexpected_item_type")
        #expect(rejection.wireFamily == Self.family)
    }

    @Test("No signature match / output already started / no image / Relay: nothing is recorded")
    func ignoresNonQualifyingFailures() throws {
        let cases: [(String, InputRejectionFlow.Attempt)] = [
            ("signature miss", try Self.attempt(body: #"{"error":{"message":"rate limited"}}"#)),
            ("status code mismatch", try Self.attempt(status: 500)),
            ("output already started", try Self.attempt(outputStarted: true)),
            ("no image carried", try Self.attempt(carried: [])),
            ("Relay", try Self.attempt(form: .relay)),
        ]
        for (label, attempt) in cases {
            let cache = Self.isolatedCache()
            #expect(InputRejectionFlow.record(attempt, negativeCache: cache) == nil, "\(label)")
            #expect(cache.entry(
                connectionId: attempt.connectionId, modelId: "input-model", wireFamily: Self.family, capabilityKey: Self.visionKey
            ) == nil, "\(label)")
        }
    }

    @Test("After recording, the production projection shows vision as rejected_recently with a placeholder outbound")
    func recordedRejectionProjectsRejectedRecently() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "capabilityRuntime": {
            "schemaVersion": \(RequestPreferenceResolver.runtimeSchemaVersion),
            "revision": "sha256:input-rejection", "generatedAt": "2026-10-19T02:00:00Z",
            "recipes": {}, "controlDefinitions": {}, "sourceIndex": {}
          },
          "providers": {"qwen": {"resolveMap": {"input-model": "input-model"},
            "models": {"input-model": {
              "canonicalModelId": "input-model", "transport": "openai_chat",
              "capabilities": ["text", "image"], "profiles": {},
              "capabilityControls": {
                "vision_input": {"state": "auto_available", "sourceRefs": ["qwen.docs"], "wireFamily": "\(Self.family)"}
              }
            }}
          }}
        }
        """, metadataETag: Self.metadataETag)
        let persisted = TestFactories.makeModel(id: "input-model", capabilities: [.text, .image])
        let model = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(persisted, providerKind: .qwen)
        let provider = TestFactories.makeProvider(id: UUID(), kind: .qwen, models: [model])
        defer { CapabilityNegativeCache.shared.clearConnection(provider.id.uuidString) }
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "u1",
            hasExplicitValue: false, metadataETag: Self.metadataETag
        )
        func vision() -> CapabilityEvidenceFacade.InputCapabilityProjection? {
            CapabilityEvidenceProductionAdapter.capabilityProjection(
                provider: provider, model: model, identity: identity, keys: [Self.visionKey]
            ).inputProjection(for: Self.visionKey)
        }
        #expect(vision()?.outbound == .nativePart, "Precondition: sent natively before recording")

        let modelID = identity.query.effectiveModelID
        let rejection = InputRejectionFlow.record(.init(
            form: ProviderForm.of(provider),
            connectionId: provider.id.uuidString, modelId: modelID,
            outputStarted: false, carriedCapabilityKeys: [Self.visionKey],
            httpStatus: 400, rawBody: Self.rejectedBody,
            controls: MetadataClient.shared.syncCapabilityRecipeRuntime(modelID: modelID, providerKind: provider.kind).controls
        ))
        #expect(rejection != nil)

        let after = try #require(vision())
        #expect(after.disabledReason == .rejectedRecently)
        #expect(after.disabledReason?.rawValue == "disabled.rejected_recently")
        #expect(after.outbound == .placeholder)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Recovery card: the primary action for an official rejection is \"resend without images\", then Switch Model")
    func recoveryLayoutOffersResendWithoutImages() {
        let layout = resolveMessageRecoveryCardActionLayout(
            for: .failed, shouldOfferModelSwitch: true,
            recoveryPrimaryAction: officialImageRejectedRecoveryAction
        )
        #expect(layout.primary == .resendWithoutImages)
        #expect(layout.secondary == .switchModel)
        #expect(localizedMessageRecoveryActionTitle(.resendWithoutImages) == InputCapabilityCopy.resendWithout(.image))
    }

    // MARK: - Three keys, carried judged by the actual outbound, missing-family fallback

    private static let fileKey = CapabilityEvidenceFacade.fileInputKey
    private static let videoKey = CapabilityEvidenceFacade.videoInputKey

    /// The built-in signature table currently only has the vision signature; file and video go through the same
    /// decision with an injected table of the same format.
    private static func mediaSignatures() throws -> InputRejectionSignatures {
        let json = #"""
        {"byWireFamily": {
          "openai_chat.file": [{"signatureId": "test.file_rejected", "httpStatus": 400,
            "messagePattern": "file input is not supported", "kind": "input_rejected", "capabilityKey": "file_input"}],
          "openai_chat.video_url": [{"signatureId": "test.video_rejected", "httpStatus": 400,
            "messagePattern": "video input is not supported", "kind": "input_rejected", "capabilityKey": "video_input"}]
        }, "byProtocol": {}}
        """#
        return try #require(InputRejectionSignatures(data: Data(json.utf8)))
    }

    private static func control(family: String) throws -> MetadataClient.CapabilityControl {
        let json = #"{"state":"auto_available","sourceRefs":["qwen.docs"],"wireFamily":"\#(family)"}"#
        return try JSONDecoder().decode(MetadataClient.CapabilityControl.self, from: Data(json.utf8))
    }

    @Test("File / video rejected: records the matching key, and the recovery card offers resend without files / videos")
    func fileAndVideoRejectionRecordsActualKey() throws {
        let signatures = try Self.mediaSignatures()
        let cases: [(String, String, String, String, MessageRecoveryActionKind, InputCapabilityCopy.Medium)] = [
            (Self.fileKey, "openai_chat.file", "test.file_rejected", "file input is not supported", .resendWithoutFiles, .file),
            (Self.videoKey, "openai_chat.video_url", "test.video_rejected", "video input is not supported", .resendWithoutVideos, .video),
        ]
        for (key, family, signatureId, message, action, medium) in cases {
            let cache = Self.isolatedCache()
            let attempt = InputRejectionFlow.Attempt(
                form: .official, connectionId: UUID().uuidString, modelId: "input-model",
                outputStarted: false, carriedCapabilityKeys: [Self.visionKey, key],
                httpStatus: 400, rawBody: #"{"error":{"message":"\#(message)"}}"#,
                controls: [Self.visionKey: try Self.control(), key: try Self.control(family: family)],
                transport: "openai_chat"
            )
            let rejection = try #require(InputRejectionFlow.record(
                attempt, signatures: signatures, negativeCache: cache
            ), "\(key)")
            #expect(rejection.capabilityKey == key)
            #expect(rejection.wireFamily == family)
            #expect(cache.entry(
                connectionId: attempt.connectionId, modelId: "input-model", wireFamily: family, capabilityKey: key
            )?.signatureId == signatureId, "\(key)")
            // With an image carried as well, only the key of the matching signature is recorded.
            #expect(cache.entry(
                connectionId: attempt.connectionId, modelId: "input-model", wireFamily: Self.family, capabilityKey: Self.visionKey
            ) == nil, "\(key)")

            let recovery = try #require(officialInputRejectedRecoveryAction(capabilityKey: key))
            var failed = TestFactories.makeMessage(role: .assistant, text: "", providerKind: .qwen)
            failed.state = .failed
            failed.recoveryPrimaryAction = recovery
            let layout = resolveMessageRecoveryCardActionLayout(
                for: .failed, shouldOfferModelSwitch: true, recoveryPrimaryAction: recoveryPrimaryAction(for: failed)
            )
            #expect(layout.primary == action)
            #expect(layout.secondary == .switchModel)
            #expect(localizedMessageRecoveryActionTitle(action) == InputCapabilityCopy.resendWithout(medium))
        }
    }

    @Test("Carried is judged by the actual outbound: media stripped to a placeholder by the projection is not carried, so a repeat rejection is not recorded again")
    func strippedMediaIsNotCarried() throws {
        let image = Oriveo.Attachment(id: UUID(), kind: .image, fileName: "p.png", mimeType: "image/png", base64Data: "AA==")
        let file = Oriveo.Attachment(id: UUID(), kind: .file, fileName: "a.pdf", mimeType: "application/pdf", base64Data: "AA==")
        var message = TestFactories.makeMessage(role: .user, text: "hi")
        message.attachments = [image, file]
        let carried = InputRejectionFlow.carriedCapabilityKeys(messages: [message]) { $0 != Self.visionKey }
        #expect(carried == [Self.fileKey])

        let cache = Self.isolatedCache()
        let attempt = try Self.attempt(carried: carried)
        #expect(InputRejectionFlow.record(attempt, negativeCache: cache) == nil)
        #expect(cache.entry(
            connectionId: attempt.connectionId, modelId: "input-model", wireFamily: Self.family, capabilityKey: Self.visionKey
        ) == nil)
    }

    @Test("Recipe is missing the vision_input key (unknown): falls back to the transport's family and records a v2 entry, with the missing-key revision")
    func missingKeyFallsBackToTransportFamily() throws {
        let cache = Self.isolatedCache()
        var attempt = try Self.attempt()
        attempt.controls = [:]
        attempt.transport = "openai_chat"
        let rejection = try #require(InputRejectionFlow.record(attempt, negativeCache: cache))
        #expect(rejection.wireFamily == Self.family)
        #expect(rejection.verdictRevision == CapabilityNegativeCache.verdictRevision(nil))
        #expect(cache.entry(
            connectionId: attempt.connectionId, modelId: "input-model", wireFamily: Self.family, capabilityKey: Self.visionKey
        )?.verdictRevision == CapabilityNegativeCache.verdictRevision(nil))

        // The transport cannot give a family (text-only transport / no transport): nothing is recorded.
        for transport in ["dashscope_native", nil] as [String?] {
            var other = attempt
            other.transport = transport
            other.connectionId = UUID().uuidString
            #expect(InputRejectionFlow.record(other, negativeCache: cache) == nil, "\(String(describing: transport))")
        }
    }

    @Test("Through the production ChatManager failure branch: an image rejected under an unknown (missing-key) verdict records the transport's family, projects rejected_recently, the recovery card offers removing images; sending again strips the image to a placeholder and a repeat rejection is not recorded again")
    @MainActor
    func productionFailureBranchRecordsByTransportFamily() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "capabilityRuntime": {
            "schemaVersion": \(RequestPreferenceResolver.runtimeSchemaVersion),
            "revision": "sha256:input-rejection-ir2", "generatedAt": "2026-10-19T02:00:00Z",
            "recipes": {}, "controlDefinitions": {}, "sourceIndex": {}
          },
          "providers": {"qwen": {"resolveMap": {"input-model": "input-model"},
            "models": {"input-model": {
              "canonicalModelId": "input-model", "transport": "openai_chat",
              "capabilities": ["text", "image"], "profiles": {},
              "capabilityControls": {}
            }}
          }}
        }
        """)
        let model = TestFactories.makeModel(id: "input-model", capabilities: [.text, .image], isDefault: true)
        let provider = Provider(
            id: UUID(), kind: .qwen, status: .connected, models: [model], catalogModels: [],
            apiKey: "fixture-only", apiKeyPreview: "", baseURLText: nil
        )
        defer { CapabilityNegativeCache.shared.clearConnection(provider.id.uuidString) }
        let image = Oriveo.Attachment(
            id: UUID(), kind: .image, fileName: "p.png", mimeType: "image/png", base64Data: Self.imageBase64
        )
        func entry() -> CapabilityNegativeCache.Entry? {
            CapabilityNegativeCache.shared.entry(
                connectionId: provider.id.uuidString, modelId: "input-model",
                wireFamily: Self.family, capabilityKey: Self.visionKey
            )
        }

        InputRejectionScriptedProtocol.reset(status: 400, body: Self.rejectedBody)
        let first = try await InputRejectionSend.send(provider: provider, modelID: model.id, attachments: [image])
        let firstBody = String(decoding: try #require(InputRejectionScriptedProtocol.bodies.first), as: UTF8.self)
            .replacingOccurrences(of: "\\/", with: "/")
        #expect(firstBody.contains(Self.imageBase64), "Precondition: an unknown verdict sends the original image")
        #expect(InputRejectionScriptedProtocol.bodies.count == 1, "No retry")
        #expect(first.state == .failed)
        let recorded = try #require(entry())
        #expect(recorded.signatureId == "dashscope.unexpected_item_type")
        #expect(recorded.verdictRevision == CapabilityNegativeCache.verdictRevision(nil))
        #expect(first.recoveryPrimaryAction == officialImageRejectedRecoveryAction)
        #expect(resolveMessageRecoveryCardActionLayout(
            for: .failed, shouldOfferModelSwitch: true, recoveryPrimaryAction: recoveryPrimaryAction(for: first)
        ).primary == .resendWithoutImages)

        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "u1", hasExplicitValue: false
        )
        let vision = try #require(CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider, model: model, identity: identity, keys: [Self.visionKey]
        ).inputProjection(for: Self.visionKey))
        #expect(vision.disabledReason == .rejectedRecently)
        #expect(vision.outbound == .placeholder)

        // Send again: the projection already strips the image, so the same error body no longer counts as a vision rejection.
        InputRejectionScriptedProtocol.reset(status: 400, body: Self.rejectedBody)
        let second = try await InputRejectionSend.send(provider: provider, modelID: model.id, attachments: [image])
        let secondBody = String(decoding: try #require(InputRejectionScriptedProtocol.bodies.first), as: UTF8.self)
            .replacingOccurrences(of: "\\/", with: "/")
        #expect(!secondBody.contains(Self.imageBase64), "The outbound image is stripped after a negative-cache hit")
        #expect(second.state == .failed)
        #expect(second.recoveryPrimaryAction != officialImageRejectedRecoveryAction)
        #expect(entry() == recorded, "Not recorded again")
    }

    private static let imageBase64 = RelayCapabilityTest.imagePNGBase64
}

/// Fake upstream for the production send chain: every request gets the same response and its body is recorded.
private final class InputRejectionScriptedProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var status = 500
    nonisolated(unsafe) private static var body = ""
    nonisolated(unsafe) private static var _bodies: [Data] = []
    private static let lock = NSLock()

    static func reset(status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        self.status = status
        self.body = body
        _bodies = []
    }

    static var bodies: [Data] { lock.lock(); defer { lock.unlock() }; return _bodies }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InputRejectionScriptedProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4_096)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            buffer.deallocate()
            stream.close()
        }
        let (status, body): (Int, String) = {
            Self.lock.lock(); defer { Self.lock.unlock() }
            Self._bodies.append(data)
            return (Self.status, Self.body)
        }()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://upstream.invalid")!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
private enum InputRejectionSend {
    static var retainedStates: [AppState] = []

    /// Sends one message through production `AppState.sendMessage` and waits until the assistant message reaches a terminal state.
    static func send(
        provider: Provider, modelID: String, attachments: [Oriveo.Attachment]
    ) async throws -> ChatMessage {
        let state = AppState(
            seedDemoData: false,
            sessionUID: "input-rejection-\(UUID().uuidString)",
            providerSession: InputRejectionScriptedProtocol.session()
        )
        retainedStates.append(state)
        let conversation = TestFactories.makeConversation(
            providerID: provider.id, providerKind: provider.kind, modelID: modelID
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)
        _ = await state.sendMessage("Describe it", attachments: attachments, in: conversation.id)

        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if let message = state.conversation(for: conversation.id)?.messages.last,
               message.role == .assistant,
               message.state == .failed || message.state == .delivered {
                try await Task.sleep(nanoseconds: 300_000_000)
                return state.conversation(for: conversation.id)?.messages.last ?? message
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw CancellationError()
    }
}
