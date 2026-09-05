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
}
