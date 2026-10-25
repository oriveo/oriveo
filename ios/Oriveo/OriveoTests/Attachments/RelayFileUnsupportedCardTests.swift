import Foundation
import Testing
@testable import Oriveo

/// File-rejection prompt card: for a relay, when a request carrying native file blocks is rejected the first time with a
/// rejection signal (400 / 404 / 415 / 422 before any output), and the fallback chain ultimately fails or every file is a
/// scan that cannot fall back, the failed message gets the local marker `relay_file_unsupported`. The recovery card body
/// then says these files are not supported, and the primary action reuses "Switch Model".
/// The error shown is still the first one; 413, a successful fallback, and non-relay connections get no marker.
/// Goes through the production `AppState.sendMessage`, with a scripted stand-in for HTTP.
@Suite("Relay file-rejection prompt card (iOS)", .serialized, .sharedProcessState)
@MainActor
struct RelayFileUnsupportedCardTests {

    // MARK: - Fixtures

    private func fixtureURL(_ relativePath: String) throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func loadSharedMetadata() async throws {
        let data = try Data(contentsOf: fixtureURL("shared/test-fixtures/relay/metadata-fixture.json"))
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: String(decoding: data, as: UTF8.self))
    }

    private func pdfModel(_ id: String) -> AIModel {
        var model = AIModel(
            id: id, name: id, capabilities: [.text, .file],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "",
            nativeFileMimes: ["application/pdf"], pdfNativeDefault: true
        )
        model.relayTransport = .openaiResponses
        model.relayTransportSource = .reachable
        return model
    }

    private func relayProvider(_ model: AIModel) -> Provider {
        Provider(
            id: UUID(), kind: .relay, status: .connected, models: [model], catalogModels: [],
            apiKey: "key", apiKeyPreview: "...key", baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions)
        )
    }

    private func textPdf() -> Oriveo.Attachment {
        Oriveo.Attachment(
            id: UUID(), kind: .file, fileName: "report.pdf", mimeType: "application/pdf",
            base64Data: Data("EXTRACTED-PDF-BODY".utf8).base64EncodedString(),
            extractedSizeBytes: 5_000, originalBase64Data: "JVBERi0xLjQ="
        )
    }

    private func scannedPdf() -> Oriveo.Attachment {
        Oriveo.Attachment(
            id: UUID(), kind: .file, fileName: "scan.pdf", mimeType: "application/pdf",
            extractedSizeBytes: 5_000, extractionErrorCode: "scanned_pdf", originalBase64Data: "JVBERi0xLjQ="
        )
    }

    private static let responsesOK = """
    event: response.output_text.delta
    data: {"delta":"ok"}

    event: response.completed
    data: {"type":"response.completed","response":{"usage":{"input_tokens":3,"output_tokens":1}}}

    """

    private func expectFileCard(_ message: ChatMessage, _ label: String) {
        #expect(message.state == .failed, "\(label)")
        let action = recoveryPrimaryAction(for: message)
        #expect(action == relayFileUnsupportedRecoveryAction, "\(label)")
        let layout = resolveMessageRecoveryCardActionLayout(
            for: .failed, shouldOfferModelSwitch: false, recoveryPrimaryAction: action
        )
        #expect(layout.primary == .switchModel, "\(label)")
        #expect(localizedMessageRecoveryActionTitle(layout.primary) == L10n.tr("Switch Model"), "\(label)")
        #expect(localizedMessageRecoveryBody(for: .failed, localPrimaryAction: action) == L10n.tr(
            "This model doesn't support these files. Switch to another model to send them.", table: .chat
        ), "\(label)")
    }

    // MARK: - Marks the message

    @Test("Native PDF rejected with 400 first and the text resend is also rejected: marks the message and shows the first error")
    func textResendAlsoRejectedMarksTheMessage() async throws {
        try await loadSharedMetadata()
        let model = pdfModel("relay-file-400")
        let provider = relayProvider(model)
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        FileCardScriptedProtocol.reset([
            .json(status: 400, body: #"{"error":{"message":"FIRST-REJECTION"}}"#),
            .json(status: 400, body: #"{"error":{"message":"SECOND-REJECTION"}}"#),
        ])
        let (_, message) = try await FileCardSend.send(provider: provider, modelID: model.id, attachments: [textPdf()])
        #expect(FileCardScriptedProtocol.bodies.first?.contains("JVBERi0xLjQ=") == true, "precondition: the first attempt carries a native PDF block")
        #expect(FileCardScriptedProtocol.urls.count == 2)
        expectFileCard(message, "400 → 400")
        let shown = (message.errorDetail ?? "") + message.text
        #expect(shown.contains("FIRST-REJECTION"), "\(shown)")
        #expect(!shown.contains("SECOND-REJECTION"), "\(shown)")
    }

    @Test("Only scanned files, so no fallback is possible: a first-attempt 422 marks the message")
    func scannedOnlyMarksTheMessage() async throws {
        try await loadSharedMetadata()
        let model = pdfModel("relay-file-scan")
        let provider = relayProvider(model)
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        FileCardScriptedProtocol.reset([.json(status: 422, body: #"{"error":{"message":"unsupported document"}}"#)])
        let (_, message) = try await FileCardSend.send(provider: provider, modelID: model.id, attachments: [scannedPdf()])
        #expect(FileCardScriptedProtocol.urls.count == 1)
        expectFileCard(message, "scan 422")
    }

    @Test("First attempt 404, text resend 404, and still failing after switching protocol: marks the message")
    func protocolFallbackThatAlsoFailsMarksTheMessage() async throws {
        try await loadSharedMetadata()
        let model = pdfModel("relay-file-404")
        let provider = relayProvider(model)
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        FileCardScriptedProtocol.reset([
            .json(status: 404, body: #"{"error":{"message":"not found"}}"#),
            .json(status: 404, body: #"{"error":{"message":"not found"}}"#),
            .json(status: 400, body: #"{"error":{"message":"chat also fails"}}"#),
        ])
        let (_, message) = try await FileCardSend.send(provider: provider, modelID: model.id, attachments: [textPdf()])
        #expect(FileCardScriptedProtocol.urls.count == 3, "\(FileCardScriptedProtocol.urls)")
        expectFileCard(message, "404 → 404 → switched 400")
    }

    // MARK: - Leaves no mark

    @Test("Text resend succeeds: no mark")
    func textResendSucceedsLeavesNoMark() async throws {
        try await loadSharedMetadata()
        let model = pdfModel("relay-file-ok")
        let provider = relayProvider(model)
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        FileCardScriptedProtocol.reset([
            .json(status: 400, body: #"{"error":{"message":"no documents"}}"#),
            .sse(body: Self.responsesOK),
        ])
        let (_, message) = try await FileCardSend.send(provider: provider, modelID: model.id, attachments: [textPdf()])
        #expect(message.state == .delivered, "\(message.errorDetail ?? "")")
        #expect(message.recoveryPrimaryAction == nil)
    }

    @Test("First attempt 400, and the text resend fails only after it started producing output: no mark")
    func resendThatStartedOutputLeavesNoMark() async throws {
        try await loadSharedMetadata()
        let model = pdfModel("relay-file-partial")
        let provider = relayProvider(model)
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        FileCardScriptedProtocol.reset([
            .json(status: 400, body: #"{"error":{"message":"no documents"}}"#),
            .sse(body: """
            event: response.output_text.delta
            data: {"delta":"partial answer"}

            event: response.failed
            data: {"type":"response.failed","response":{"error":{"code":"server_error","message":"boom"}}}

            data: [DONE]

            """),
        ])
        let (_, message) = try await FileCardSend.send(provider: provider, modelID: model.id, attachments: [textPdf()])
        #expect(FileCardScriptedProtocol.urls.count == 2, "precondition: the text fallback was resent once")
        #expect(message.state == .failed)
        #expect(message.text.contains("partial answer"), "precondition: the resend had already produced output")
        #expect(recoveryPrimaryAction(for: message) == nil)
    }

    @Test("First attempt 413 (not a rejection signal) and the text resend fails: no mark")
    func payloadTooLargeLeavesNoMark() async throws {
        try await loadSharedMetadata()
        let model = pdfModel("relay-file-413")
        let provider = relayProvider(model)
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        FileCardScriptedProtocol.reset([
            .json(status: 413, body: #"{"error":{"message":"too large"}}"#),
            .json(status: 400, body: #"{"error":{"message":"still bad"}}"#),
        ])
        let (_, message) = try await FileCardSend.send(provider: provider, modelID: model.id, attachments: [textPdf()])
        #expect(message.state == .failed)
        #expect(FileCardScriptedProtocol.urls.count == 2, "precondition: 413 still falls back to text as before")
        #expect(recoveryPrimaryAction(for: message) == nil)
    }

    @Test("The request has no native file block (plain text rejected): no mark")
    func plainTextRejectionLeavesNoMark() async throws {
        try await loadSharedMetadata()
        let model = pdfModel("relay-file-plain")
        let provider = relayProvider(model)
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        FileCardScriptedProtocol.reset([.json(status: 400, body: #"{"error":{"message":"bad request"}}"#)])
        let (_, message) = try await FileCardSend.send(provider: provider, modelID: model.id)
        #expect(message.state == .failed)
        #expect(recoveryPrimaryAction(for: message) == nil)
    }

    @Test("The decision requires a relay, native file blocks on the first attempt, and a first rejection that is a rejection signal")
    func decisionPredicate() {
        func rejection(_ status: Int) -> RelayPreOutputRejection {
            RelayPreOutputRejection(status: status, contentType: "application/json", body: Data())
        }
        for status in [400, 404, 415, 422] {
            #expect(NativeFileFallback.marksRelayFileUnsupported(
                isRelay: true, firstAttemptCarriedNativeFiles: true, firstRejection: rejection(status)
            ), "\(status)")
            // Non-relay connections get no mark.
            #expect(!NativeFileFallback.marksRelayFileUnsupported(
                isRelay: false, firstAttemptCarriedNativeFiles: true, firstRejection: rejection(status)
            ), "\(status)")
            #expect(!NativeFileFallback.marksRelayFileUnsupported(
                isRelay: true, firstAttemptCarriedNativeFiles: false, firstRejection: rejection(status)
            ), "\(status)")
        }
        for status in [401, 403, 413, 429, 500] {
            #expect(!NativeFileFallback.marksRelayFileUnsupported(
                isRelay: true, firstAttemptCarriedNativeFiles: true, firstRejection: rejection(status)
            ), "\(status)")
        }
        #expect(!NativeFileFallback.marksRelayFileUnsupported(
            isRelay: true, firstAttemptCarriedNativeFiles: true, firstRejection: nil
        ))
    }
}

// MARK: - Scripted upstream for the production send chain

private final class FileCardScriptedProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case json(status: Int, body: String)
        case sse(body: String)
    }

    nonisolated(unsafe) static var script: [Reply] = []
    nonisolated(unsafe) private static var _urls: [URL] = []
    nonisolated(unsafe) private static var _bodies: [String] = []
    private static let lock = NSLock()

    static func reset(_ replies: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        script = replies
        _urls = []
        _bodies = []
    }

    static var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }
    static var bodies: [String] { lock.lock(); defer { lock.unlock() }; return _bodies }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FileCardScriptedProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4_096)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            buffer.deallocate()
            stream.close()
        }
        let url = request.url ?? URL(string: "https://relay.invalid")!
        let reply: Reply = {
            Self.lock.lock(); defer { Self.lock.unlock() }
            Self._urls.append(url)
            Self._bodies.append(String(decoding: body, as: UTF8.self))
            let index = Self._urls.count - 1
            return index < Self.script.count ? Self.script[index] : .json(status: 500, body: #"{"error":{"message":"unscripted"}}"#)
        }()
        let status: Int
        let contentType: String
        let data: Data
        switch reply {
        case let .json(code, text):
            status = code; contentType = "application/json"; data = Data(text.utf8)
        case let .sse(text):
            status = 200; contentType = "text/event-stream"; data = Data(text.utf8)
        }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
private enum FileCardSend {
    static var retainedStates: [AppState] = []

    /// Sends one message through the production `AppState.sendMessage` and waits until the assistant message reaches a terminal state.
    static func send(
        provider: Provider,
        modelID: String,
        attachments: [Oriveo.Attachment] = []
    ) async throws -> (state: AppState, message: ChatMessage) {
        let state = AppState(
            seedDemoData: false,
            sessionUID: "relay-file-card-\(UUID().uuidString)",
            providerSession: FileCardScriptedProtocol.session()
        )
        retainedStates.append(state)
        let conversation = TestFactories.makeConversation(
            providerID: provider.id, providerKind: .relay, modelID: modelID
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)
        _ = await state.sendMessage("Summarize it", attachments: attachments, in: conversation.id)

        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if let message = state.conversation(for: conversation.id)?.messages.last,
               message.role == .assistant,
               message.state == .failed || message.state == .delivered {
                try await Task.sleep(nanoseconds: 300_000_000)
                return (state, state.conversation(for: conversation.id)?.messages.last ?? message)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw CancellationError()
    }
}
