import Foundation
import Testing
@testable import Oriveo

//   - candidates[].finishReason ∈ {SAFETY, RECITATION, PROHIBITED_CONTENT, BLOCKLIST, SPII}

final class GeminiMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = GeminiMockURLProtocol.requestHandler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeGeminiMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [GeminiMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func geminiHTTPResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

private func geminiUserMessage(_ text: String = "hello") -> ChatMessage {
    ChatMessage(
        id: UUID(),
        role: .user,
        text: text,
        providerKind: .gemini,
        providerName: "Gemini",
        modelName: "gemini-2.5-flash",
        state: .delivered
    )
}

private struct GeminiStreamRunResult {
    var deltas = ""
    var sawDone = false
    var thrown: Error?
}

private func driveGeminiStream(
    _ stream: AsyncThrowingStream<StreamEvent, Error>
) async -> GeminiStreamRunResult {
    var result = GeminiStreamRunResult()
    do {
        for try await event in stream {
            switch event {
            case let .delta(text):
                result.deltas += text
            case .done:
                result.sawDone = true
            case .reasoning, .imagePart, .citations, .toolCallDeltas:
                break
            }
        }
    } catch {
        result.thrown = error
    }
    return result
}

private func expectGeminiUpstream200(
    _ error: Error?,
    detailContains fragment: String,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let providerError = try #require(
        error as? ProviderServiceError,
        "expected ProviderServiceError, got \(String(describing: error))",
        sourceLocation: sourceLocation
    )
    guard case let .upstream(statusCode, detail) = providerError else {
        Issue.record(
            "expected .upstream, got \(providerError)",
            sourceLocation: sourceLocation
        )
        return
    }
    #expect(statusCode == 200, sourceLocation: sourceLocation)
    #expect(detail.contains(fragment), Comment(rawValue: "detail=\(detail)"), sourceLocation: sourceLocation)
}

@Suite("Gemini Service", .serialized)
struct GeminiServiceTests {

    @Test("Stream Safety Finish Reason Throws")
    func streamSafetyFinishReasonThrows() async throws {
        await MetadataClient.shared.resetForTesting()
        GeminiMockURLProtocol.requestHandler = nil
        defer { GeminiMockURLProtocol.requestHandler = nil }

        GeminiMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let body = """
            data: {"candidates":[{"content":{"parts":[{"text":"partial text"}]}}]}
            data: {"candidates":[{"finishReason":"SAFETY","content":{"parts":[]}}]}

            """
            return (geminiHTTPResponse(url: url, statusCode: 200), Data(body.utf8))
        }

        let service = GeminiService(session: makeGeminiMockSession())
        let result = await driveGeminiStream(
            service.sendMessageStream(
                apiKey: "test-key",
                modelID: "gemini-2.5-flash",
                messages: [geminiUserMessage()]
            )
        )

        #expect(result.deltas == "partial text",
                Comment(rawValue: "partial text already emitted before intercept is kept on the Failed path, as expected"))
        #expect(!result.sawDone,
                Comment(rawValue: "a content-policy cut must never be delivered as Done (normal completion)"))
        try expectGeminiUpstream200(result.thrown, detailContains: "finishReason=SAFETY")
    }

    @Test("Stream Block Reason Throws")
    func streamBlockReasonThrows() async throws {
        await MetadataClient.shared.resetForTesting()
        GeminiMockURLProtocol.requestHandler = nil
        defer { GeminiMockURLProtocol.requestHandler = nil }

        GeminiMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let body = """
            data: {"promptFeedback":{"blockReason":"PROHIBITED_CONTENT"}}

            """
            return (geminiHTTPResponse(url: url, statusCode: 200), Data(body.utf8))
        }

        let service = GeminiService(session: makeGeminiMockSession())
        let result = await driveGeminiStream(
            service.sendMessageStream(
                apiKey: "test-key",
                modelID: "gemini-2.5-flash",
                messages: [geminiUserMessage()]
            )
        )

        #expect(!result.sawDone,
                Comment(rawValue: "a full block (zero output) that does not throw falls through to generic EmptyResponse, leaving the user with no diagnosis"))
        try expectGeminiUpstream200(result.thrown, detailContains: "blockReason=PROHIBITED_CONTENT")
    }

    @Test("streaming STOP / MAX_TOKENS is normal completion and must not be intercepted", arguments: ["STOP", "MAX_TOKENS"])
    func streamNormalFinishReasonNotIntercepted(finishReason: String) async throws {
        await MetadataClient.shared.resetForTesting()
        GeminiMockURLProtocol.requestHandler = nil
        defer { GeminiMockURLProtocol.requestHandler = nil }

        GeminiMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let body = """
            data: {"candidates":[{"content":{"parts":[{"text":"Final"}]}}]}
            data: {"candidates":[{"finishReason":"\(finishReason)","content":{"parts":[{"text":" answer"}]}}],"usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":5}}

            """
            return (geminiHTTPResponse(url: url, statusCode: 200), Data(body.utf8))
        }

        let service = GeminiService(session: makeGeminiMockSession())
        let result = await driveGeminiStream(
            service.sendMessageStream(
                apiKey: "test-key",
                modelID: "gemini-2.5-flash",
                messages: [geminiUserMessage()]
            )
        )

        #expect(result.thrown == nil,
                Comment(rawValue: "finishReason=\(finishReason) is normal completion and must not throw"))
        #expect(result.deltas == "Final answer")
        #expect(result.sawDone)
    }

    @Test("Stream Mid Stream Error Payload Throws")
    func streamMidStreamErrorPayloadThrows() async throws {
        await MetadataClient.shared.resetForTesting()
        GeminiMockURLProtocol.requestHandler = nil
        defer { GeminiMockURLProtocol.requestHandler = nil }

        GeminiMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let body = """
            data: {"candidates":[{"content":{"parts":[{"text":"first half"}]}}]}
            data: {"error":{"code":429,"message":"Resource has been exhausted (e.g. check quota).","status":"RESOURCE_EXHAUSTED"}}

            """
            return (geminiHTTPResponse(url: url, statusCode: 200), Data(body.utf8))
        }

        let service = GeminiService(session: makeGeminiMockSession())
        let result = await driveGeminiStream(
            service.sendMessageStream(
                apiKey: "test-key",
                modelID: "gemini-2.5-flash",
                messages: [geminiUserMessage()]
            )
        )

        #expect(result.deltas == "first half")
        #expect(!result.sawDone,
                Comment(rawValue: "a mid-stream error that does not throw would deliver accumulated text as normal completion"))
        try expectGeminiUpstream200(result.thrown, detailContains: "RESOURCE_EXHAUSTED")
    }

    @Test("Relay Stream Safety Finish Reason Throws")
    func relayStreamSafetyFinishReasonThrows() async throws {
        await MetadataClient.shared.resetForTesting()
        GeminiMockURLProtocol.requestHandler = nil
        defer { GeminiMockURLProtocol.requestHandler = nil }

        GeminiMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let body = """
            data: {"candidates":[{"content":{"parts":[{"text":"partial"}]}}]}
            data: {"candidates":[{"finishReason":"SAFETY","content":{"parts":[]}}]}

            """
            return (geminiHTTPResponse(url: url, statusCode: 200), Data(body.utf8))
        }

        let service = GeminiService(session: makeGeminiMockSession())
        let result = await driveGeminiStream(
            service.sendMessageStream(
                apiKey: "test-key",
                modelID: "gemini-2.5-flash",
                messages: [geminiUserMessage()],
                baseURL: "https://relay.example.com/v1beta"
            )
        )

        #expect(result.deltas == "partial")
        #expect(!result.sawDone)
        try expectGeminiUpstream200(result.thrown, detailContains: "finishReason=SAFETY")
    }

    @Test("Non Stream Block Reason Throws Upstream")
    func nonStreamBlockReasonThrowsUpstream() async throws {
        await MetadataClient.shared.resetForTesting()
        GeminiMockURLProtocol.requestHandler = nil
        defer { GeminiMockURLProtocol.requestHandler = nil }

        GeminiMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let body = """
            {"promptFeedback":{"blockReason":"SAFETY"},"candidates":[]}
            """
            return (geminiHTTPResponse(url: url, statusCode: 200), Data(body.utf8))
        }

        let service = GeminiService(session: makeGeminiMockSession())
        var thrown: Error?
        do {
            _ = try await service.sendMessage(
                apiKey: "test-key",
                modelID: "gemini-2.5-flash",
                messages: [geminiUserMessage()]
            )
            Issue.record("a blockReason response must not return normally")
        } catch {
            thrown = error
        }

        try expectGeminiUpstream200(thrown, detailContains: "blockReason=SAFETY")
    }
}
