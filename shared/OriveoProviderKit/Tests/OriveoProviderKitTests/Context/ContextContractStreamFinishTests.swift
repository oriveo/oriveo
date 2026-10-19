import Foundation
import OriveoProviderKit
import Testing

// The clean criteria of StreamFinishTracker for openai_chat and the other OpenAI-compatible families.

@Suite("ContextContractStreamFinish")
struct ContextContractStreamFinishTests {
    private static func track(_ family: StopFamily, _ lines: [String]) -> StreamFinish {
        var tracker = StreamFinishTracker(family: family)
        for line in lines { tracker.observeSSELine(line) }
        return tracker.finish()
    }

    private static let content = #"data: {"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}"#
    private static let length = #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#

    @Test("openai_chat: [DONE] or a non-empty finish_reason is clean, neither is eof_without_marker")
    func openAIChat() {
        #expect(Self.track(.openaiChat, [Self.content, Self.length, "data: [DONE]"])
            == StreamFinish(family: .openaiChat, ended: .clean, finishRaw: "length"))
        #expect(Self.track(.openaiChat, [Self.content, Self.length])
            == StreamFinish(family: .openaiChat, ended: .clean, finishRaw: "length"))
        #expect(Self.track(.openaiChat, [Self.content, "data:[DONE]"])
            == StreamFinish(family: .openaiChat, ended: .clean, finishRaw: nil))
        #expect(Self.track(.openaiChat, [Self.content, ": keep-alive", "event: x"])
            == StreamFinish(family: .openaiChat, ended: .eofWithoutMarker, finishRaw: nil))
    }

    @Test("other OpenAI-compatible families: only [DONE] counts, and a seen finish_reason is still carried when the stream is cut off")
    func free() {
        #expect(Self.track(.free, [Self.content, Self.length])
            == StreamFinish(family: .free, ended: .eofWithoutMarker, finishRaw: "length"))
        #expect(Self.track(.free, [Self.content, Self.length, "data: [DONE]"])
            == StreamFinish(family: .free, ended: .clean, finishRaw: "length"))
    }

    @Test("StreamFinish is encoded as the fixture text")
    func codable() throws {
        let data = try JSONEncoder().encode(StreamFinish(family: .openaiChat, ended: .eofWithoutMarker, finishRaw: "stop"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["family": "openai_chat", "ended": "eof_without_marker", "finishRaw": "stop"])
    }
}
