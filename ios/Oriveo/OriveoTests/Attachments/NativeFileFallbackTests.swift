import XCTest
@testable import Oriveo

/// Text fallback after the upstream rejects a native file block: through the real Service send chain (build the request, send it, read the status code, resend), with a scripted HTTP stand-in.
final class NativeFileFallbackTests: XCTestCase {

    private var holdsSharedProcessStateLock = false

    // MARK: - HTTP stand-in (scripted status codes and recorded request bodies)

    final class ScriptedProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var script: [(status: Int, body: String)] = []
        nonisolated(unsafe) static var bodies: [String] = []
        private static let lock = NSLock()

        static func reset(_ responses: [(Int, String)]) {
            lock.withLock {
                script = responses.map { ($0.0, $0.1) }
                bodies = []
            }
        }

        static func recordedBodies() -> [String] { lock.withLock { bodies } }

        static func session() -> URLSession {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ScriptedProtocol.self]
            return URLSession(configuration: config)
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let bodyData: Data = {
                if let body = request.httpBody { return body }
                guard let stream = request.httpBodyStream else { return Data() }
                stream.open(); defer { stream.close() }
                var data = Data()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: 4096)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                return data
            }()
            let next: (status: Int, body: String) = Self.lock.withLock {
                Self.bodies.append(String(decoding: bodyData, as: UTF8.self))
                return Self.script.isEmpty ? (200, "") : Self.script.removeFirst()
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: next.status, httpVersion: nil,
                headerFields: ["Content-Type": next.status == 200 ? "text/event-stream" : "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(next.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    // MARK: - Fixtures

    private static let okStream = [
        ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":3}}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}"#),
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#),
        ("message_stop", #"{"type":"message_stop"}"#),
    ].map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined()

    private static let okJSON = #"{"content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":3,"output_tokens":1}}"#

    private static func rejection(_ marker: String) -> String {
        #"{"type":"error","error":{"type":"invalid_request_error","message":"\#(marker)"}}"#
    }

    private let model = AIModel(
        id: "claude-sonnet-4-5", name: "claude-sonnet-4-5", capabilities: [.text, .image, .file],
        reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "premium",
        nativeFileMimes: ["application/pdf"], pdfNativeDefault: true
    )

    private func textPdf() -> Attachment {
        Attachment(
            id: UUID(), kind: .file, fileName: "report.pdf", mimeType: "application/pdf",
            base64Data: Data("EXTRACTED-PDF-BODY".utf8).base64EncodedString(),
            extractedSizeBytes: 5_000, originalBase64Data: "JVBERi0xLjQ="
        )
    }

    private func scannedPdf() -> Attachment {
        Attachment(
            id: UUID(), kind: .file, fileName: "scan.pdf", mimeType: "application/pdf",
            extractedSizeBytes: 5_000, extractionErrorCode: "scanned_pdf", originalBase64Data: "JVBERi0xLjQ="
        )
    }

    private func message(_ attachments: [Attachment], kind: ProviderKind = .relay) -> ChatMessage {
        ChatMessage(
            id: UUID(), role: .user, text: "summarize", providerKind: kind, providerName: "P",
            modelID: model.id, modelName: model.name, state: .delivered, attachments: attachments
        )
    }

    private func options(connection: UUID?) -> ChatRequestOptions {
        var options = ChatRequestOptions()
        options.capabilityEvidenceModel = model
        options.attachmentConnectionID = connection
        return options
    }

    /// Production sends always run under a dispatch identity: the file_input projection reads from it;
    /// without an identity, official native files are stripped of raw data fail-closed, which is not the fallback under test here.
    private func withDispatchIdentity<T>(
        kind: ProviderKind = .relay,
        connection: UUID?,
        model dispatchModel: AIModel? = nil,
        _ body: () async throws -> T
    ) async throws -> T {
        let sendModel = dispatchModel ?? model
        let provider = Provider(
            id: connection ?? UUID(), kind: kind, status: .connected,
            models: [sendModel], catalogModels: [sendModel],
            apiKey: "", apiKeyPreview: "",
            relayRequested: kind == .relay ? RelayRequestedConfig(transport: .anthropicMessages) : nil
        )
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: sendModel, partitionID: "native-file-fallback",
            hasExplicitValue: true, effectiveTransport: "anthropic_messages",
            metadataETag: CapabilityRuntimeFixtures.defaultRevision
        )
        return try await CapabilityEvidenceRequestContext.$current.withValue(identity) {
            try await body()
        }
    }

    private func relayStream(_ attachments: [Attachment], connection: UUID?) async throws -> String {
        try await withDispatchIdentity(connection: connection) {
            let stream = AnthropicService(session: ScriptedProtocol.session()).sendMessageStream(
                apiKey: "relay-key", modelID: model.id, messages: [message(attachments)],
                baseURL: "https://relay.test", requestOptions: options(connection: connection),
                relayRequested: RelayRequestedConfig(transport: .anthropicMessages)
            )
            var text = ""
            for try await event in stream {
                if case let .delta(chunk) = event { text += chunk }
            }
            return text
        }
    }

    private func hasDocumentBlock(_ body: String) -> Bool {
        body.contains(#""type":"document""#) && body.contains("JVBERi0xLjQ=")
    }

    override func setUp() async throws {
        // The process-wide shared snapshot is serialized against Swift Testing cases marked .sharedProcessState (see SharedProcessStateTrait)
        await SharedProcessStateLock.shared.acquire(holder: "xctest:\(name)")
        holdsSharedProcessStateLock = true
        try await super.setUp()
        await MetadataClient.shared.resetForTesting()
        // Ship capabilityRuntime like production does, so the dispatch identity can resolve the projection.
        try await MetadataClient.shared.loadForTesting(
            json: relayFixture(nativeFileWhitelist: false),
            metadataETag: CapabilityRuntimeFixtures.defaultRevision
        )
        NativeFileFallback.resetMemoryForTesting()
    }

    override func tearDown() async throws {
        NativeFileFallback.resetMemoryForTesting()
        ScriptedProtocol.reset([])
        if holdsSharedProcessStateLock {
            holdsSharedProcessStateLock = false
            await SharedProcessStateLock.shared.release()
        }
        try await super.tearDown()
    }

    // MARK: - Fallback

    func testRelayStreamRejectedNativeFileIsResentAsTextAndTheConnectionIsRemembered() async throws {
        let connection = UUID()
        ScriptedProtocol.reset([(400, Self.rejection("document blocks are not supported")), (200, Self.okStream)])

        let text = try await relayStream([textPdf()], connection: connection)
        XCTAssertEqual(text, "ok")
        let bodies = ScriptedProtocol.recordedBodies()
        XCTAssertEqual(bodies.count, 2)
        // First attempt: the same routing as a direct connection; a text PDF (pdfNativeDefault) goes as a document block and the body carries no extracted text.
        XCTAssertTrue(hasDocumentBlock(bodies[0]), String(bodies[0].prefix(400)))
        XCTAssertFalse(bodies[0].contains("EXTRACTED-PDF-BODY"))
        // Resend: text injection, with no file block.
        XCTAssertFalse(hasDocumentBlock(bodies[1]), String(bodies[1].prefix(400)))
        XCTAssertTrue(bodies[1].contains("EXTRACTED-PDF-BODY"))
        XCTAssertTrue(bodies[1].contains("ATTACHMENT_FILE"))
        // Relay memory now lives in the local negative cache (connection x model x protocol x file), no longer the in-process connection x protocol.
        XCTAssertTrue(NativeFileFallback.isKnownTextOnly(.relayScope(.anthropicMessages, connectionID: connection, modelID: model.id)))

        // The next message on the same connection: straight to text, with a single request.
        ScriptedProtocol.reset([(200, Self.okStream)])
        let followUp = try await relayStream([textPdf()], connection: connection)
        XCTAssertEqual(followUp, "ok")
        let second = ScriptedProtocol.recordedBodies()
        XCTAssertEqual(second.count, 1)
        XCTAssertFalse(hasDocumentBlock(second[0]))
        XCTAssertTrue(second[0].contains("EXTRACTED-PDF-BODY"))

        // The memory is per connection: another connection still sends the file block first.
        ScriptedProtocol.reset([(200, Self.okStream)])
        _ = try await relayStream([textPdf()], connection: UUID())
        XCTAssertTrue(hasDocumentBlock(ScriptedProtocol.recordedBodies()[0]))
    }

    func testRelayNonStreamingFallsBackTheSameWay() async throws {
        let connection = UUID()
        ScriptedProtocol.reset([(422, Self.rejection("unprocessable")), (200, Self.okJSON)])
        let result = try await withDispatchIdentity(connection: connection) {
            try await AnthropicService(session: ScriptedProtocol.session()).sendMessage(
                apiKey: "relay-key", modelID: model.id, messages: [message([textPdf()])],
                baseURL: "https://relay.test", requestOptions: options(connection: connection),
                relayRequested: RelayRequestedConfig(transport: .anthropicMessages)
            )
        }
        XCTAssertEqual(result.text, "ok")
        let bodies = ScriptedProtocol.recordedBodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(hasDocumentBlock(bodies[0]))
        XCTAssertFalse(hasDocumentBlock(bodies[1]))
        XCTAssertTrue(bodies[1].contains("EXTRACTED-PDF-BODY"))
        XCTAssertTrue(NativeFileFallback.isKnownTextOnly(.relayScope(.anthropicMessages, connectionID: connection, modelID: model.id)))
    }

    // MARK: - No fallback

    func testScannedOnlyRejectionIsShownAsIsWithoutAResend() async throws {
        let connection = UUID()
        ScriptedProtocol.reset([(400, Self.rejection("FIRST-REJECTION")), (200, Self.okStream)])
        do {
            _ = try await relayStream([scannedPdf()], connection: connection)
            XCTFail("expected the upstream rejection to surface")
        } catch let error as ProviderServiceError {
            XCTAssertTrue(error.technicalDetail.contains("FIRST-REJECTION") || error.message.contains("FIRST-REJECTION"), "\(error)")
        }
        XCTAssertEqual(ScriptedProtocol.recordedBodies().count, 1)
        XCTAssertTrue(hasDocumentBlock(ScriptedProtocol.recordedBodies()[0]))
        XCTAssertFalse(NativeFileFallback.isKnownTextOnly(.relayScope(.anthropicMessages, connectionID: connection, modelID: model.id)))
    }

    func testAuthRateLimitAndServerErrorsDoNotFallBack() async throws {
        for status in [401, 403, 429, 500] {
            let connection = UUID()
            ScriptedProtocol.reset([(status, Self.rejection("nope")), (200, Self.okStream)])
            do {
                _ = try await relayStream([textPdf()], connection: connection)
                XCTFail("HTTP \(status) should surface")
            } catch is ProviderServiceError {}
            XCTAssertEqual(ScriptedProtocol.recordedBodies().count, 1, "HTTP \(status)")
            XCTAssertFalse(
                NativeFileFallback.isKnownTextOnly(.relayScope(.anthropicMessages, connectionID: connection, modelID: model.id)),
                "HTTP \(status)"
            )
        }
    }

    func testResendThatAlsoFailsShowsTheFirstErrorAndRemembersNothing() async throws {
        let connection = UUID()
        ScriptedProtocol.reset([(400, Self.rejection("FIRST-REJECTION")), (400, Self.rejection("SECOND-REJECTION"))])
        do {
            _ = try await relayStream([textPdf()], connection: connection)
            XCTFail("expected a failure")
        } catch let error as ProviderServiceError {
            let shown = error.technicalDetail + error.message
            XCTAssertTrue(shown.contains("FIRST-REJECTION"), shown)
            XCTAssertFalse(shown.contains("SECOND-REJECTION"), shown)
        }
        XCTAssertEqual(ScriptedProtocol.recordedBodies().count, 2)
        XCTAssertFalse(NativeFileFallback.isKnownTextOnly(.relayScope(.anthropicMessages, connectionID: connection, modelID: model.id)))
    }

    func testDirectAnthropicDoesNotFallBack() async throws {
        ScriptedProtocol.reset([(400, Self.rejection("FIRST-REJECTION")), (200, Self.okStream)])
        let connection = UUID()
        // The dispatch route of an official direct connection is resolved from the catalog row: use claude-sonnet-4.5 from the fixture (it carries a route); this model still carries the allowlist.
        let direct = AIModel(
            id: "claude-sonnet-4.5", name: "claude-sonnet-4.5", capabilities: [.text, .image, .file],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "premium",
            nativeFileMimes: ["application/pdf"], pdfNativeDefault: true
        )
        var directOptions = options(connection: connection)
        directOptions.capabilityEvidenceModel = direct
        let turn = ChatMessage(
            id: UUID(), role: .user, text: "summarize", providerKind: .anthropic, providerName: "P",
            modelID: direct.id, modelName: direct.name, state: .delivered, attachments: [textPdf()]
        )
        do {
            try await withDispatchIdentity(kind: .anthropic, connection: connection, model: direct) {
                let stream = AnthropicService(session: ScriptedProtocol.session()).sendMessageStream(
                    apiKey: "sk-ant-test", modelID: direct.id, messages: [turn],
                    requestOptions: directOptions
                )
                for try await _ in stream {}
            }
            XCTFail("expected the upstream rejection to surface")
        } catch is ProviderServiceError {}
        XCTAssertEqual(ScriptedProtocol.recordedBodies().count, 1)
        XCTAssertTrue(hasDocumentBlock(ScriptedProtocol.recordedBodies()[0]))
    }

    func testPlainTextRequestRejectedWith400IsNotResent() async throws {
        ScriptedProtocol.reset([(400, Self.rejection("bad request")), (200, Self.okStream)])
        do {
            _ = try await relayStream([], connection: UUID())
            XCTFail("expected a failure")
        } catch is ProviderServiceError {}
        XCTAssertEqual(ScriptedProtocol.recordedBodies().count, 1)
    }

    // MARK: - Relay models inherit the official allowlist (production path)

    /// The shared fixture plus capabilityRuntime; with `nativeFileWhitelist`, a native-file allowlist is injected in memory for anthropic claude-sonnet-4.5. The shared fixture file itself is left untouched.
    private func relayFixture(nativeFileWhitelist: Bool) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Attachments/
            .deletingLastPathComponent() // OriveoTests/
            .deletingLastPathComponent() // Oriveo/
            .deletingLastPathComponent() // ios/
            .deletingLastPathComponent() // repository root
        let url = repoRoot.appendingPathComponent("shared/test-fixtures/relay/metadata-fixture.json")
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        root["capabilityRuntime"] = try CapabilityRuntimeFixtures.runtimeEnvelope()
        var providers = try XCTUnwrap(root["providers"] as? [String: Any])
        var anthropic = try XCTUnwrap(providers["anthropic"] as? [String: Any])
        var models = try XCTUnwrap(anthropic["models"] as? [String: Any])
        var sonnet = try XCTUnwrap(models["claude-sonnet-4.5"] as? [String: Any])
        // Ship the catalog route as production does, so the official builder can resolve the dispatch route.
        sonnet["transport"] = "anthropic_messages"
        if nativeFileWhitelist {
            sonnet["nativeFileMimes"] = ["application/pdf"]
            sonnet["pdfNativeDefault"] = false
            sonnet["attachmentExtraction"] = ["maxLines": 1234]
        }
        models["claude-sonnet-4.5"] = sonnet
        anthropic["models"] = models
        providers["anthropic"] = anthropic
        root["providers"] = providers
        return String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }

    /// The model that is sent comes straight out of Relay catalog resolution, with no hand-built allowlist: a scanned PDF must go out as a native block.
    func testRelayCatalogResolvedModelSendsScannedPdfAsNativeDocumentBlock() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: relayFixture(nativeFileWhitelist: true),
            metadataETag: CapabilityRuntimeFixtures.defaultRevision
        )
        ProviderCatalogResolver.resetMemoForTesting()

        let local = AIModel(
            id: "claude-sonnet-4.5", name: "claude-sonnet-4.5", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: ""
        )
        let provider = Provider(
            id: UUID(), kind: .relay, status: .connected,
            models: [local], catalogModels: [local],
            apiKey: "", apiKeyPreview: "",
            relayRequested: RelayRequestedConfig(transport: .anthropicMessages)
        )
        let resolved = try XCTUnwrap(
            ProviderCatalogResolver.resolve(provider: provider).catalog.first { $0.model.id == local.id }
        ).model
        XCTAssertEqual(resolved.canonicalModelId, "claude-sonnet-4.5")

        var requestOptions = ChatRequestOptions()
        requestOptions.capabilityEvidenceModel = AttachmentTransportResolver.evidenceModel(provider: provider, model: resolved)
        requestOptions.attachmentConnectionID = provider.id

        ScriptedProtocol.reset([(200, Self.okStream)])
        let turn = ChatMessage(
            id: UUID(), role: .user, text: "summarize", providerKind: .relay, providerName: "P",
            modelID: resolved.id, modelName: resolved.name, state: .delivered, attachments: [scannedPdf()]
        )
        // Before the fix this could throw outright (a scan has no text and cannot go as a native block); either way the verdict lands on the request body assertions.
        do {
            try await withDispatchIdentity(connection: provider.id, model: resolved) {
                let stream = AnthropicService(session: ScriptedProtocol.session()).sendMessageStream(
                    apiKey: "relay-key", modelID: resolved.id, messages: [turn],
                    baseURL: "https://relay.test", requestOptions: requestOptions,
                    relayRequested: RelayRequestedConfig(transport: .anthropicMessages)
                )
                for try await _ in stream {}
            }
        } catch {}

        let bodies = ScriptedProtocol.recordedBodies()
        XCTAssertFalse(bodies.isEmpty, "a scanned PDF should produce a request")
        XCTAssertTrue(bodies.first.map(hasDocumentBlock) ?? false, "the first request body should carry a native document block")
    }
}
