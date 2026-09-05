import Foundation
import Testing
@testable import Oriveo

/// `tools:[{"type":"web_search"}]`**.
@Suite("Grok Official Web Search Injection Tests", .serialized)
struct GrokOfficialWebSearchInjectionTests {
    private static func productionSnapshot() throws -> String {
        let fixturePath = "shared/test-fixtures/model-facts/grok-official-responses-web.v1.json"
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.pathComponents.count > 1 {
            let candidate = dir.appendingPathComponent(fixturePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: fixturePath])
    }

    private func officialModel() -> AIModel {
        var model = TestFactories.makeModel(id: "grok-4.6", capabilities: [.text, .web, .reasoning])
        model.reasoningModeAvailable = true
        model.toolCall = true
        return model
    }

    @Test("Web Enabled Attaches Server Tool")
    func webEnabledAttachesServerTool() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.productionSnapshot())
        defer { GrokOfficialMockURLProtocol.handler = nil }

        let service = GrokService(session: GrokOfficialMockURLProtocol.session())
        GrokOfficialMockURLProtocol.reset()

        var options = ChatRequestOptions()
        options.capabilityEvidenceModel = officialModel()

        _ = try? await service.sendMessage(
            apiKey: "xai-test-key",
            modelID: "grok-4.6",
            messages: [ChatMessage(
                id: UUID(), role: .user, text: "What's the weather in Nanjing today",
                providerKind: .grok, providerName: "Grok", modelName: "grok-4.6", state: .delivered
            )],
            reasoningMode: .automatic,
            webSearchEnabled: true,
            requestOptions: options
        )

        let request = try #require(GrokOfficialMockURLProtocol.request)
        #expect(request.url?.absoluteString == "https://api.x.ai/v1/responses")
        let body = GrokOfficialMockURLProtocol.body()
        let tools = body["tools"] as? [[String: Any]]
        #expect(tools?.contains { $0["type"] as? String == "web_search" } == true)
    }

    @Test("Web Disabled Attaches Nothing")
    func webDisabledAttachesNothing() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.productionSnapshot())
        defer { GrokOfficialMockURLProtocol.handler = nil }

        let service = GrokService(session: GrokOfficialMockURLProtocol.session())
        GrokOfficialMockURLProtocol.reset()

        var options = ChatRequestOptions()
        options.capabilityEvidenceModel = officialModel()

        _ = try? await service.sendMessage(
            apiKey: "xai-test-key",
            modelID: "grok-4.6",
            messages: [ChatMessage(
                id: UUID(), role: .user, text: "What's the weather in Nanjing today",
                providerKind: .grok, providerName: "Grok", modelName: "grok-4.6", state: .delivered
            )],
            reasoningMode: .automatic,
            webSearchEnabled: false,
            requestOptions: options
        )

        let request = try #require(GrokOfficialMockURLProtocol.request)
        let body = GrokOfficialMockURLProtocol.body()
        let tools = body["tools"] as? [[String: Any]] ?? []
        #expect(!tools.contains { $0["type"] as? String == "web_search" })
        _ = request
    }
}

private final class GrokOfficialMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var request: URLRequest?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var handler: ((URLRequest) -> Void)?

    static func reset() { request = nil; capturedBody = nil }

    static func body() -> [String: Any] {
        guard let data = capturedBody,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokOfficialMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.request = request
        Self.capturedBody = request.httpBodyStream.map { stream in
            stream.open()
            var data = Data()
            let size = 8192
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        } ?? request.httpBody
        let payload = Data(#"{"id":"resp_1","object":"response","status":"completed","output":[{"id":"m1","type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
