import Testing
import UIKit
import SwiftUI
@testable import Oriveo

@Suite("Code Block View Tests")
struct CodeBlockViewTests {
    @Test("Long Streaming Preview Keeps Trailing Lines")
    func longStreamingPreviewKeepsTrailingLines() {
        let text = (1...25).map { "line \($0)" }.joined(separator: "\n")
        let preview = makeStreamingCodePreview(from: text, lineLimit: 3, characterLimit: 10_000)

        #expect(preview.isTruncated == true)
        #expect(preview.lineCount == 25)
        #expect(preview.text == "line 23\nline 24\nline 25")
    }

    @Test("Long Single Line Preview Caps Characters")
    func longSingleLinePreviewCapsCharacters() {
        let text = String(repeating: "a", count: 32)
        let preview = makeStreamingCodePreview(from: text, lineLimit: 18, characterLimit: 8)

        #expect(preview.isTruncated == true)
        #expect(preview.text == "aaaaaaaa")
    }

    @Test("Unchanged Text Produces No Change")
    func unchangedTextProducesNoChange() {
        #expect(makeStreamingCodeTextUpdate(previous: "abc", next: "abc") == .noChange)
    }

    @Test("Appended Text Produces Append")
    func appendedTextProducesAppend() {
        #expect(makeStreamingCodeTextUpdate(previous: "abc", next: "abcdef") == .append("def"))
    }

    @Test("Non Prefix Change Produces Replace")
    func nonPrefixChangeProducesReplace() {
        #expect(makeStreamingCodeTextUpdate(previous: "abc", next: "abX") == .replace("abX"))
    }

    @Test("Empty Previous Produces Replace")
    func emptyPreviousProducesReplace() {
        #expect(makeStreamingCodeTextUpdate(previous: "", next: "hello") == .replace("hello"))
    }

    @Test("Code Block Palette Uses Editor Surface")
    func codeBlockPaletteUsesEditorSurface() {
        #expect(Self.resolvedHex(MarkdownCodeBlockPalette.backgroundUIColor, .light) == 0x0B1220)
        #expect(Self.resolvedHex(MarkdownCodeBlockPalette.backgroundUIColor, .dark) == 0x050814)
        #expect(Self.resolvedHex(MarkdownCodeBlockPalette.surfaceUIColor, .light) == 0x111A2E)
        #expect(Self.resolvedHex(MarkdownCodeBlockPalette.surfaceUIColor, .dark) == 0x0B1020)
    }

    @Test("Syntax Palette Uses Balanced Editor Accents")
    func syntaxPaletteUsesBalancedEditorAccents() {
        #expect(Self.resolvedHex(MarkdownCodeBlockPalette.keywordUIColor, .light) == 0xD8B4FE)
        #expect(Self.resolvedHex(MarkdownCodeBlockPalette.stringUIColor, .light) == 0xA7F3D0)
        #expect(Self.resolvedHex(MarkdownCodeBlockPalette.numberUIColor, .light) == 0xFDE68A)
        #expect(Self.resolvedHex(MarkdownCodeBlockPalette.typeUIColor, .light) == 0x7DD3FC)
        #expect(Self.resolvedHex(MarkdownCodeBlockPalette.variableUIColor, .light) == 0x5EEAD4)
        #expect(Self.resolvedHex(MarkdownCodeBlockPalette.commentUIColor, .light) == 0x94A3B8)
    }

    @Test("Php Variables Use Variable Syntax Color")
    func phpVariablesUseVariableSyntaxColor() {
        let code = "$arr[$i] = $temp"
        let highlighted = SyntaxHighlighter.highlight(code, language: "php", baseColor: .white)
        let nsCode = code as NSString

        for variable in ["$arr", "$i", "$temp"] {
            let range = nsCode.range(of: variable)
            let color = highlighted.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
            #expect(Self.resolvedHex(color ?? .clear, .light) == 0x5EEAD4)
        }
    }

    @Test("Common Language Identifiers Use Variable Syntax Color")
    func commonLanguageIdentifiersUseVariableSyntaxColor() {
        let code = "func updateUser(_ userName: String) { let score = userName.count }"
        let highlighted = SyntaxHighlighter.highlight(code, language: "swift", baseColor: .white)
        let nsCode = code as NSString

        for identifier in ["updateUser", "userName", "score", "count"] {
            let range = nsCode.range(of: identifier)
            let color = highlighted.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
            #expect(Self.resolvedHex(color ?? .clear, .light) == 0x5EEAD4)
        }

        let keywordRange = nsCode.range(of: "func")
        let keywordColor = highlighted.attribute(.foregroundColor, at: keywordRange.location, effectiveRange: nil) as? UIColor
        #expect(Self.resolvedHex(keywordColor ?? .clear, .light) == 0xD8B4FE)

        let typeRange = nsCode.range(of: "String")
        let typeColor = highlighted.attribute(.foregroundColor, at: typeRange.location, effectiveRange: nil) as? UIColor
        #expect(Self.resolvedHex(typeColor ?? .clear, .light) == 0x7DD3FC)
    }

    private static func resolvedHex(_ color: UIColor, _ style: UIUserInterfaceStyle) -> UInt {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (UInt((red * 255).rounded()) << 16)
            | (UInt((green * 255).rounded()) << 8)
            | UInt((blue * 255).rounded())
    }
}
