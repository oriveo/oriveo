import Foundation
import Network
import Testing
@testable import Oriveo

private actor LocalSocketRequestCapture {
    private var data = Data()
    private var requests: [Data] = []
    func store(_ next: Data) { data = next; requests.append(next) }
    func value() -> Data { data }
    func all() -> [Data] { requests }
}

@Suite("Local HTTP ATS socket")
struct LocalHTTPATSSocketTests {
    @Test("simulator reaches an actual loopback cleartext socket")
    func loopbackCleartextSocket() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "oriveo.local-http-ats-test")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, _, _ in
                let response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 15\r\nConnection: close\r\n\r\n{\"status\":\"ok\"}".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }

        let port = try await waitForPort(listener)
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/health"))
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let json = try JSONSerialization.jsonObject(with: data)
        #expect(LocalEngineContract.classify(engine: .llamacpp, status: 200, contentType: "application/json", json: json) == .ready)
    }

    @Test("production auth-none ping injects no credential into an actual socket")
    func productionAuthNoneRecording() async throws {
        let capture = LocalSocketRequestCapture()
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "oriveo.local-http-recording-test")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.receiveHTTPRequest(connection) { requestData in
                let body = #"{"choices":[{"message":{"content":"ok"}}]}"#
                let response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
                Task {
                    await capture.store(requestData)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }

        let port = try await waitForPort(listener)
        let requested = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .none,
            securityMode: .localHTTP,
            headers: [RelayKeyValue(key: "Authorization", value: "Bearer secret")],
            queryParams: [RelayKeyValue(key: "api_key", value: "secret")],
            customUserAgent: "must-not-appear"
        )
        _ = try await OpenAIService().pingRelay(
            apiKey: "",
            baseURL: "http://127.0.0.1:\(port)/v1",
            modelID: "fixture-model",
            relayRequested: requested
        )

        let raw = String(decoding: await capture.value(), as: UTF8.self).lowercased()
        #expect(raw.contains("post /v1/chat/completions"))
        #expect(raw.contains("fixture-model"))
        #expect(!raw.contains("authorization:"))
        #expect(!raw.contains("api-key"))
        #expect(!raw.contains("api_key"))
        #expect(!raw.contains("bearer secret"))
        #expect(!raw.contains("must-not-appear"))
    }

    @Test("llama.cpp native ping uses root completion endpoint and native budget key")
    func llamaCppNativePing() async throws {
        let capture = LocalSocketRequestCapture()
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "oriveo.llamacpp-native-ping")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.receiveHTTPRequest(connection) { requestData in
                let body = #"{"content":"ok"}"#
                let response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
                Task {
                    await capture.store(requestData)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }

        let port = try await waitForPort(listener)
        _ = try await OpenAIService().pingRelay(
            apiKey: "",
            baseURL: "http://127.0.0.1:\(port)",
            modelID: nil,
            relayRequested: .init(transport: .llamacppNative, authMode: .none, securityMode: .localHTTP)
        )
        let raw = String(decoding: await capture.value(), as: UTF8.self).lowercased()
        #expect(raw.contains("post /completion"))
        #expect(raw.contains("\"n_predict\":1"))
        #expect(!raw.contains("authorization:"))
    }

    /// Starts a llama-server stand-in that answers every request with `{"content":"ok"}`, sends one non-streaming chat through the production Relay entry,
    /// and returns the send result and the prompt `/completion` received (an empty array if none was sent).
    private func llamaCppNativeChat(
        attachments: [Oriveo.Attachment], evidenceModel: AIModel?
    ) async throws -> (error: Error?, prompts: [String]) {
        let capture = LocalSocketRequestCapture()
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "oriveo.llamacpp-native-chat")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.receiveHTTPRequest(connection) { requestData in
                let body = #"{"content":"ok"}"#
                let response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
                Task {
                    await capture.store(requestData)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        let port = try await waitForPort(listener)

        var message = ChatMessage(
            id: UUID(), role: .user, text: "summarize the files", providerKind: .relay,
            providerName: "llama.cpp", modelID: "local", modelName: "local", state: .delivered
        )
        message.attachments = attachments
        var options = ChatRequestOptions()
        options.capabilityEvidenceModel = evidenceModel
        var sendError: Error?
        do {
            _ = try await OpenAIService().sendMessage(
                apiKey: "", modelID: "local", messages: [message],
                baseURL: "http://127.0.0.1:\(port)",
                requestOptions: options,
                relayRequested: .init(transport: .llamacppNative, authMode: .none, securityMode: .localHTTP)
            )
        } catch {
            sendError = error
        }
        let delimiter = Data("\r\n\r\n".utf8)
        let prompts: [String] = await capture.all().compactMap { raw in
            guard String(decoding: raw.prefix(64), as: UTF8.self).hasPrefix("POST /completion"),
                  let split = raw.range(of: delimiter),
                  let json = try? JSONSerialization.jsonObject(with: raw[split.upperBound...]) as? [String: Any]
            else { return nil }
            return json["prompt"] as? String
        }
        return (sendError, prompts)
    }

    private static func textFile(_ name: String) -> Oriveo.Attachment {
        let content = "content of \(name)"
        return Oriveo.Attachment(
            id: UUID(), kind: .file, fileName: name, mimeType: "text/plain",
            base64Data: Data(content.utf8).base64EncodedString(),
            extractedSizeBytes: content.utf8.count
        )
    }

    private static func evidenceModel() -> AIModel {
        AIModel(
            id: "local", name: "local", capabilities: [.text, .file],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "premium"
        )
    }

    @Test("llama.cpp native chat carries file attachments as text blocks inside the prompt")
    func llamaCppNativeChatInjectsFileAttachments() async throws {
        let outcome = try await llamaCppNativeChat(
            attachments: [Self.textFile("notes.txt")], evidenceModel: Self.evidenceModel()
        )
        #expect(outcome.error == nil, "\(String(describing: outcome.error))")
        let prompt = try #require(outcome.prompts.first)
        #expect(outcome.prompts.count == 1)
        #expect(prompt.hasPrefix("user: summarize the files"))
        #expect(prompt.contains("<ATTACHMENT_FILE>"))
        #expect(prompt.contains("notes.txt"))
        #expect(prompt.contains("content of notes.txt"))
        #expect(prompt.hasSuffix("\nassistant:"))
    }

    @Test("llama.cpp native chat blocks an outgoing turn whose files do not fit, before any completion request")
    func llamaCppNativeChatBlocksOverLimitOutgoingTurn() async throws {
        let outcome = try await llamaCppNativeChat(
            attachments: ["a.txt", "b.txt", "c.txt", "d.txt"].map(Self.textFile),
            evidenceModel: Self.evidenceModel()
        )
        guard case let .attachmentTextOverLimit(fileNames, fileCountLimit)? = outcome.error as? ProviderServiceError else {
            Issue.record("over-limit outgoing turn was not blocked: \(String(describing: outcome.error))")
            return
        }
        #expect(fileNames.isEmpty)
        #expect(fileCountLimit == FileExtractionLimits.default.maxFiles)
        #expect(outcome.prompts.isEmpty)
    }

    @Test("llama.cpp native chat without attachments keeps the plain transcript prompt")
    func llamaCppNativeChatWithoutAttachmentsIsUnchanged() async throws {
        let outcome = try await llamaCppNativeChat(attachments: [], evidenceModel: Self.evidenceModel())
        #expect(outcome.error == nil, "\(String(describing: outcome.error))")
        #expect(outcome.prompts == ["user: summarize the files\nassistant:"])
    }

    @Test("cross-origin redirect cannot deliver a prompt to an actual capture socket")
    func crossOriginRedirectDoesNotReachCaptureSocket() async throws {
        let capture = LocalSocketRequestCapture()
        let captureListener = try NWListener(using: .tcp, on: .any)
        let captureQueue = DispatchQueue(label: "oriveo.redirect-capture-target")
        captureListener.newConnectionHandler = { connection in
            connection.start(queue: captureQueue)
            Self.receiveHTTPRequest(connection) { requestData in
                Task { await capture.store(requestData) }
                let response = Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        captureListener.start(queue: captureQueue)
        defer { captureListener.cancel() }
        let capturePort = try await waitForPort(captureListener)

        let sourceListener = try NWListener(using: .tcp, on: .any)
        let sourceQueue = DispatchQueue(label: "oriveo.redirect-source")
        sourceListener.newConnectionHandler = { connection in
            connection.start(queue: sourceQueue)
            Self.receiveHTTPRequest(connection) { _ in
                let response = Data(
                    "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(capturePort)/capture\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8
                )
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        sourceListener.start(queue: sourceQueue)
        defer { sourceListener.cancel() }
        let sourcePort = try await waitForPort(sourceListener)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(sourcePort)/generate")!)
        request.httpMethod = "POST"
        request.httpBody = Data("private prompt".utf8)
        request.applyRelaySecurityMode(.init(
            transport: .openaiChatCompletions,
            authMode: .none,
            securityMode: .localHTTP
        ))

        let (_, response) = try await URLSession.shared.relayData(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 307)
        try await Task.sleep(for: .milliseconds(100))
        let captured = String(decoding: await capture.value(), as: UTF8.self)
        #expect(captured.isEmpty)
        #expect(!captured.contains("private prompt"))
    }

    private static func receiveHTTPRequest(
        _ connection: NWConnection,
        accumulated: Data = Data(),
        completion: @escaping @Sendable (Data) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            var request = accumulated
            if let data { request.append(data) }
            if isComplete || error != nil || isCompleteHTTPRequest(request) {
                completion(request)
            } else {
                receiveHTTPRequest(connection, accumulated: request, completion: completion)
            }
        }
    }

    private static func isCompleteHTTPRequest(_ data: Data) -> Bool {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter) else { return false }
        let headerText = String(decoding: data[..<headerRange.lowerBound], as: UTF8.self)
        let contentLength = headerText
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") }
            ?? 0
        return data.count >= headerRange.upperBound + contentLength
    }

    private func waitForPort(_ listener: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port!.rawValue)
                case let .failed(error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
        }
    }
}
