import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// The shared SSE framing fixture (`shared/test-fixtures/provider-stream/sse-framing.v1.json`) run against
/// the iOS chat parser and the MCP parser. The fixture is read only, and every assertion is made on what
/// production code handed out.
///
/// The decoder is fed one byte at a time, so the chunkings in the fixture make no difference to it (each
/// cut feeds the same bytes), and every case runs once.
@Suite("SSE framing fixture")
struct SSEFramingFixtureTests {
    @Test("fixture is the version this test knows and has all 22 cases")
    func fixtureLoads() throws {
        let fixture = try loadFixture()
        #expect(fixture.schema == "oriveo.fixture.sse-framing/v1")
        #expect(fixture.cases.count == 22)
    }

    @Test("decoder yields the fixture frames and comment count")
    func decoderFrames() throws {
        for item in try loadFixture().cases {
            var decoder = SSEFrameDecoder()
            var frames: [SSEFrame] = []
            for byte in item.bytes {
                if case let .frame(frame)? = decoder.consume(byte) { frames.append(frame) }
            }
            for case let .frame(frame) in decoder.finish() { frames.append(frame) }
            let actual = frames.map { Frame(event: $0.event, data: $0.data, id: $0.id, retry: $0.retry) }
            #expect(actual == item.expect.frames, "\(item.id)")
            #expect(decoder.comments == item.expect.comments, "\(item.id) comments")
        }
    }

    @Test("line loops receive every non-empty frame as event and data lines")
    func canonicalLines() throws {
        for item in try loadFixture().cases {
            let lines = SSECanonicalLines.lines(in: item.bytes)
                .filter { $0.hasPrefix("event: ") || $0.hasPrefix("data: ") }
            let expected = item.expect.frames.filter { !$0.data.isEmpty }.flatMap { frame -> [String] in
                // A multi-line event whose joined data is not valid JSON is delivered line by line; none of
                // the multi-line data in the fixture is JSON.
                let dataLines = frame.data.contains("\n")
                    ? frame.data.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                    : [frame.data]
                return (frame.event.map { ["event: \($0)"] } ?? []) + dataLines.map { "data: \($0)" }
            }
            #expect(lines == expected, "\(item.id)")
        }
    }

    @Test("openai chat cases assemble the fixture text through the production stream assembler")
    func openAIChatAssembly() throws {
        let cases = try loadFixture().cases.filter { $0.openaiChat != nil }
        #expect(cases.count == 7)
        for item in cases {
            var assembler = OpenAICompatibleStreamAssembler(profile: .deepSeek)
            var text = ""
            for line in SSECanonicalLines.lines(in: item.bytes) {
                for event in try assembler.ingest(line) {
                    if case let .textDelta(delta) = event { text += delta }
                }
            }
            #expect(text == item.openaiChat?.text, "\(item.id)")
            #expect(assembler.isDone == item.openaiChat?.done, "\(item.id) done")
        }
    }

    @Test("multi-line data that is one JSON document reaches the line loops as one payload")
    func multiLineJSONIsOnePayload() {
        let body = "data: {\"choices\":[\ndata: {\"delta\":{\"content\":\"A\"}}\ndata: ]}\n\n"
        #expect(SSECanonicalLines.lines(in: Array(body.utf8)) == [
            "data: {\"choices\":[\n{\"delta\":{\"content\":\"A\"}}\n]}",
        ])
    }

    @Test("json documents separated by a single newline are still delivered one per data line")
    func singleNewlineSeparatedJSON() {
        let body = "data: {\"a\":1}\ndata: {\"b\":2}\ndata: [DONE]\n"
        #expect(SSECanonicalLines.lines(in: Array(body.utf8)) == [
            "data: {\"a\":1}", "data: {\"b\":2}", "data: [DONE]",
        ])
    }

    @Test("event and data pairs without blank lines keep each data line's own event name")
    func pairedEventDataWithoutBlankLines() {
        let body = "event: content_block_delta\ndata: {\"i\":1}\nevent: content_block_delta\ndata: {\"i\":2}\nevent: error\ndata: {\"i\":3}\n"
        #expect(SSECanonicalLines.lines(in: Array(body.utf8)) == [
            "event: content_block_delta", "data: {\"i\":1}",
            "event: content_block_delta", "data: {\"i\":2}",
            "event: error", "data: {\"i\":3}",
        ])
    }

    @Test("lines that are not sse fields pass through unchanged and blank lines are not delivered")
    func nonSSELinesPassThrough() {
        let body = ": keep-alive\n{\"error\":{\"message\":\"boom\"}}\nid: 3\n\nplain\n"
        #expect(SSECanonicalLines.lines(in: Array(body.utf8)) == [
            ": keep-alive", "{\"error\":{\"message\":\"boom\"}}", "id: 3", "plain",
        ])
    }

    @Test("MCP parser yields the fixture frames whose data is JSON")
    func mcpParser() throws {
        for item in try loadFixture().cases {
            let expected = item.expect.frames.compactMap { try? JSONValue(parsing: $0.data) }
            #expect(McpSSE.messages(in: Data(item.bytes)) == expected, "\(item.id)")
        }
    }

    // MARK: - Fixture

    private struct Fixture: Decodable {
        let schema: String
        let cases: [Case]
    }

    private struct Case: Decodable {
        let id: String
        let bytesBase64: String
        let expect: Expect
        let openaiChat: OpenAIChat?

        var bytes: [UInt8] { Array(Data(base64Encoded: bytesBase64) ?? Data()) }

        enum CodingKeys: String, CodingKey {
            case id, expect
            case bytesBase64 = "bytes_base64"
            case openaiChat = "openai_chat"
        }
    }

    private struct Expect: Decodable {
        let frames: [Frame]
        let comments: Int
    }

    private struct Frame: Decodable, Equatable {
        let event: String?
        let data: String
        let id: String?
        let retry: Int?
    }

    private struct OpenAIChat: Decodable {
        let text: String
        let done: Bool
    }

    private func loadFixture() throws -> Fixture {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor
                .appendingPathComponent("shared")
                .appendingPathComponent("test-fixtures")
                .appendingPathComponent("provider-stream")
                .appendingPathComponent("sse-framing.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: candidate))
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
