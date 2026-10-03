import Foundation
import Testing
@testable import Oriveo

// MARK: - SSE parser
//
// Production feeds the incremental parser (`McpSSEParser`) byte by byte; `McpSSE.messages(in:)` is a thin wrapper
// around the same parser. Both entry points are exercised here.

private func texts(_ messages: [JSONValue]) -> [String] {
    messages.map { $0["v"]?.stringValue ?? $0.orderedJSONString }
}

private func parse(_ text: String) -> [JSONValue] {
    McpSSE.messages(in: Data(text.utf8))
}

@Suite("MCP SSE parser")
struct McpSSETests {

    @Test("all three line endings (LF / CRLF / lone CR) parse identically", arguments: ["\n", "\r\n", "\r"])
    func lineEndings(newline: String) {
        let stream = [
            "event: message", #"data: {"v":"one"}"#, "",
            ": comment", #"data: {"v":"two"}"#, "",
        ].joined(separator: newline) + newline
        #expect(texts(parse(stream)) == ["one", "two"])
    }

    @Test("a leading BOM is dropped and does not affect the first line")
    func byteOrderMark() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(#"data: {"v":"one"}"#.utf8))
        data.append(Data("\n\n".utf8))
        #expect(texts(McpSSE.messages(in: data)) == ["one"])
    }

    @Test("multiple data lines of one event are joined with newlines")
    func multilineData() {
        let stream = "data: {\"v\":\ndata: \"joined\"}\n\n"
        #expect(texts(parse(stream)) == ["joined"])

        let pretty = "data: {\ndata:   \"v\": \"pretty\",\ndata:   \"n\": [1,\ndata:   2]\ndata: }\n\n"
        let message = parse(pretty).first
        #expect(message?["v"]?.stringValue == "pretty")
        #expect(message?["n"]?.arrayValue?.count == 2)
    }

    @Test("the last event is accepted even without a trailing blank line")
    func missingTrailingBlankLine() {
        #expect(texts(parse("data: {\"v\":\"one\"}\n\ndata: {\"v\":\"two\"}\n")) == ["one", "two"])
        #expect(texts(parse("data: {\"v\":\"one\"}\n\ndata: {\"v\":\"two\"}")) == ["one", "two"])
        // A multi-line event that was never terminated.
        #expect(texts(parse("data: {\"v\":\ndata: \"tail\"}")) == ["tail"])
    }

    @Test("a single-line event is emitted once: early at the end of its data line, not again on the blank line")
    func singleLineEventEmitsOnce() {
        var parser = McpSSEParser()
        var emitted: [(at: String, value: JSONValue)] = []
        let stream = "data: {\"v\":\"one\"}\n\n"
        var consumed = ""
        for byte in stream.utf8 {
            consumed.unicodeScalars.append(Unicode.Scalar(byte))
            if let value = parser.consume(byte) { emitted.append((consumed, value)) }
        }
        #expect(parser.finish() == nil)
        #expect(emitted.count == 1)
        // Emitted at the first newline, without waiting for the blank line that closes the event (some servers stop sending bytes after the last data line).
        #expect(emitted.first?.at == "data: {\"v\":\"one\"}\n")
    }

    @Test("invalid UTF-8 is not dropped wholesale: bad bytes become U+FFFD and the other events parse normally")
    func invalidUTF8IsRepairedNotDropped() {
        var data = Data(#"data: {"v":"a"#.utf8)
        data.append(contentsOf: [0xFF, 0xFE])
        data.append(Data("b\"}\n\n".utf8))
        data.append(Data("data: {\"v\":\"two\"}\n\n".utf8))
        #expect(texts(McpSSE.messages(in: data)) == ["a\u{FFFD}\u{FFFD}b", "two"])
    }

    @Test("one malformed frame does not stall the whole stream")
    func malformedFrameIsSkipped() {
        let stream = "data: {not json}\n\ndata: {\"v\":\"ok\"}\n\n"
        #expect(texts(parse(stream)) == ["ok"])
    }

    @Test("field parsing: strips a single leading space, lines without a colon, non-data fields, comments")
    func fieldParsing() {
        #expect(texts(parse("data:{\"v\":\"tight\"}\n\n")) == ["tight"])
        #expect(texts(parse("data:    {\"v\":\"spaces\"}\n\n")) == ["spaces"])
        #expect(parse("event: message\nid: 7\nretry: 1000\n: note\n\n").isEmpty)
        // A `data` line without a colon has an empty value and is joined with the next line.
        #expect(texts(parse("data\ndata: {\"v\":\"after-empty\"}\n\n")) == ["after-empty"])
        // The field name must be exactly `data`.
        #expect(parse("database: {\"v\":\"no\"}\n\n").isEmpty)
        #expect(parse("Data: {\"v\":\"no\"}\n\n").isEmpty)
    }

    @Test("an empty stream and a comment-only stream produce no messages")
    func emptyStreams() {
        #expect(parse("").isEmpty)
        #expect(parse("\n\n\n").isEmpty)
        #expect(parse(": ping\n\n: ping\n\n").isEmpty)
    }

    @Test("fixture replay: both tools-call.sse.txt generations parse to a notification plus the final response",
          arguments: ["protocol/stateless/tools-call.sse.txt", "protocol/session/tools-call.sse.txt"])
    func fixtureStreams(name: String) throws {
        let messages = McpSSE.messages(in: try McpClientFixture.sse(name))
        #expect(messages.count == 2)
        #expect(messages.first?["method"]?.stringValue == "notifications/message")
        #expect(messages.last?["id"]?.intValue == 3)
        #expect(messages.last?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("72°F") == true)
    }

    @Test("fixtures rewritten with CRLF / CR parse to the same result", arguments: ["\r\n", "\r"])
    func fixtureWithOtherNewlines(newline: String) throws {
        let original = try McpClientFixture.sse("protocol/stateless/tools-call.sse.txt")
        let text = try #require(String(data: original, encoding: .utf8))
        let converted = Data(text.replacingOccurrences(of: "\n", with: newline).utf8)
        #expect(McpSSE.messages(in: converted) == McpSSE.messages(in: original))
    }
}
