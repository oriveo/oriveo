import Foundation
import Testing
@testable import Oriveo

@Suite("Qwen Dash Scope Native Tests")
struct QwenDashScopeNativeTests {

    @Test("Compatible Base Normalizes")
    func compatibleBaseNormalizes() {
        let url = QwenService.composeCompatibleChatURL(
            base: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        )
        #expect(url.absoluteString == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions")
    }

    @Test("Native Origin Base Normalizes")
    func nativeOriginBaseNormalizes() {
        let url = QwenService.composeCompatibleChatURL(base: "https://dashscope.aliyuncs.com")
        #expect(url.absoluteString == "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
    }

    @Test("Native Path Base Stripped")
    func nativePathBaseStripped() {
        let url = QwenService.composeCompatibleChatURL(
            base: "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/text-generation/generation"
        )
        #expect(url.absoluteString == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions")
        #expect(!url.path.contains("/services/aigc/text-generation/generation"))
    }

    @Test("Custom Proxy Base URL")
    func customProxyBaseURL() {
        let url = QwenService.composeCompatibleChatURL(base: "https://example-proxy.com/v1")
        #expect(url.absoluteString == "https://example-proxy.com/v1/chat/completions")
        #expect(!url.absoluteString.contains("/compatible-mode"))
        #expect(!url.path.contains("/services/aigc/text-generation/generation"))
    }

    @Test("Full Chat Completions Path Preserved")
    func fullChatCompletionsPathPreserved() {
        let url = QwenService.composeCompatibleChatURL(base: "https://my.relay.io/v1/chat/completions")
        #expect(url.absoluteString == "https://my.relay.io/v1/chat/completions")
    }

    @Test("Compat Stream Request Shape")
    func compatStreamRequestShape() throws {
        let service = QwenService()
        let request = try service.chatRequestForTesting(
            modelID: "qwen3-max",
            messages: [makeUserMessage("hi")],
            apiKey: "sk-test",
            baseURL: nil,
            stream: true
        )
        #expect(request.value(forHTTPHeaderField: "X-DashScope-SSE") == nil)
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["stream"] as? Bool == true)
        #expect(json["messages"] != nil)
        #expect(json["input"] == nil)
    }

    @Test("Compat Non Stream Request Shape")
    func compatNonStreamRequestShape() throws {
        let service = QwenService()
        let request = try service.chatRequestForTesting(
            modelID: "qwen3-max",
            messages: [makeUserMessage("hi")],
            apiKey: "sk-test",
            baseURL: nil,
            stream: false
        )
        #expect(request.value(forHTTPHeaderField: "X-DashScope-SSE") == nil)
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["stream"] == nil)
        #expect(json["messages"] != nil)
        #expect(json["input"] == nil)
    }

    private func makeUserMessage(_ text: String) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: .user,
            text: text,
            providerKind: .qwen,
            providerName: "Qwen",
            modelName: "qwen3-max",
            state: .delivered
        )
    }
}
