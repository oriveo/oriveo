import Foundation
import Testing

@testable import OriveoProviderKit

// The property under test is injectivity: two different tool ids must never encode to the same
// function name, because a collision would dispatch a model's answer to the wrong tool.

@Suite("Tool function name codec")
struct ToolFunctionNameCodecTests {
    @Test("a dotted tool id round-trips")
    func dotRoundTrip() {
        #expect(ToolFunctionNameCodec.encode("fs.read") == "fs__read")
        #expect(ToolFunctionNameCodec.decode("fs__read") == "fs.read")
    }

    @Test("fs.read and fs_read never collide")
    func dotAndUnderscoreNeverCollide() {
        let dotted = ToolFunctionNameCodec.encode("fs.read")
        let underscored = ToolFunctionNameCodec.encode("fs_read")

        #expect(dotted == "fs__read")
        #expect(underscored == "fs_5fread")
        #expect(dotted != underscored)
        #expect(ToolFunctionNameCodec.decode(dotted) == "fs.read")
        #expect(ToolFunctionNameCodec.decode(underscored) == "fs_read")
    }

    @Test(
        "any toolID encodes to [A-Za-z0-9_] and round-trips",
        arguments: [
            "fs.read",
            "fs_read",
            "shell.run",
            "skill.custom-tool",
            "a.b.c.d",
            "_leading",
            "trailing_",
            "with space",
            "read-file.execute",
            "",
        ]
    )
    func bijectionHolds(_ toolID: String) {
        let encoded = ToolFunctionNameCodec.encode(toolID)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")

        #expect(encoded.unicodeScalars.allSatisfy { allowed.contains($0) })
        #expect(ToolFunctionNameCodec.decode(encoded) == toolID)
    }

    @Test("an unrecognised escape decodes to itself instead of being dropped")
    func invalidEscapePassesThrough() {
        #expect(ToolFunctionNameCodec.decode("get_weather") == "get_weather")
        #expect(ToolFunctionNameCodec.decode("trailing_") == "trailing_")
        #expect(ToolFunctionNameCodec.decode("_zz") == "_zz")
    }

    @Test("a caller that sends names verbatim gets the same names back from the accumulator")
    func accumulatorCanKeepWireNames() throws {
        // `_de`, `_ad` and `_fe` happen to be valid escape sequences and `__` is the short form of
        // `.`, so decoding would rewrite every one of these names.
        let names = ["mcp_notes_delete_page", "mcp_canva_add_comment", "mcp_web_fetch", "mcp_a__b"]
        for name in names {
            let delta = try JSONDecoder().decode(
                [OpenAICompatibleChunk.Choice.ToolCallDelta].self,
                from: Data(#"[{"index":0,"id":"call_1","type":"function","function":{"name":"\#(name)","arguments":"{}"}}]"#.utf8)
            )
            var raw = OpenAICompatibleToolCallAccumulator(decodesFunctionNames: false)
            raw.accumulate(delta)
            #expect(raw.flush().map(\.name) == [name])

            var decoded = OpenAICompatibleToolCallAccumulator()
            decoded.accumulate(delta)
            #expect(decoded.flush().map(\.name) == [ToolFunctionNameCodec.decode(name)], "the default still decodes")
            #expect(ToolFunctionNameCodec.decode(name) != name, "decoding really does change these names")
        }
    }

    @Test("Callers that send names verbatim: with decoding off, the stream assembler proposes the name the upstream sent")
    func assemblerCanKeepWireNames() throws {
        // Decoding turns the `_fe` of `web_fetch` into a byte that is not valid UTF-8: the name becomes `web\u{FFFD}tch`, which finds no executor and cannot be sent back.
        let lines = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"web_fetch","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]",
        ]
        func proposedNames(decodes: Bool) throws -> [String] {
            var assembler = OpenAICompatibleStreamAssembler(profile: .moonshot, decodesFunctionNames: decodes)
            var events: [ProviderStreamEvent] = []
            for line in lines { events += try assembler.ingest(line) }
            events += try assembler.finish()
            return events.compactMap { event -> String? in
                if case let .toolCall(call) = event { return call.name }
                return nil
            }
        }
        #expect(try proposedNames(decodes: false) == ["web_fetch"])
        #expect(try proposedNames(decodes: true) != ["web_fetch"], "decoding stays the default: it is for callers whose request side encoded the names")
    }
}
