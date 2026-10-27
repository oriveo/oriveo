import Foundation
import Testing
import UIKit
@testable import Oriveo

/// The "Oriveo Code" syntax highlighting is aligned value for value with `shared/theme-contracts/code-highlight.v1.json`, shared by every client.
/// Expected values are always read from the JSON rather than copied into the tests; the recognition rules run the JSON's classifyCases.
@MainActor
@Suite("Code highlight contract")
struct CodeHighlightContractTests {
    /// JSON role name → this client's color. `text` is the code body color.
    static let roleColors: [String: UIColor] = [
        "text": MarkdownCodeBlockPalette.foregroundUIColor,
        "keyword": MarkdownCodeBlockPalette.keywordUIColor,
        "string": MarkdownCodeBlockPalette.stringUIColor,
        "number": MarkdownCodeBlockPalette.numberUIColor,
        "function": MarkdownCodeBlockPalette.functionUIColor,
        "type": MarkdownCodeBlockPalette.typeUIColor,
        "property": MarkdownCodeBlockPalette.propertyUIColor,
        "comment": MarkdownCodeBlockPalette.commentUIColor,
        "punctuation": MarkdownCodeBlockPalette.punctuationUIColor,
        "diffAdd": MarkdownCodeBlockPalette.diffAddUIColor,
        "diffDelete": MarkdownCodeBlockPalette.diffDeleteUIColor,
        "diffHunk": MarkdownCodeBlockPalette.diffHunkUIColor,
    ]

    @Test("roles_equal_json: the 12 roles equal the JSON value for value in light / dark, and the full-line background colors and alpha match")
    func rolesEqualJSON() throws {
        let contract = try Self.loadContract()
        let roles = try #require(contract["roles"] as? [String])
        #expect(Set(roles) == Set(Self.roleColors.keys))
        #expect(roles.count == 12)

        for style in [UIUserInterfaceStyle.light, .dark] {
            let key = style == .dark ? "dark" : "light"
            let values = try #require(contract[key] as? [String: Any])
            let traits = Self.traits(style)
            for role in roles {
                let hex = try Self.hex(try #require(values[role] as? String))
                let color = try #require(Self.roleColors[role])
                #expect(Self.rgba(color, traits).hex == hex, "\(key).\(role)")
                #expect(Self.rgba(color, traits).alpha == 1, "\(key).\(role)")
            }
            for (field, color) in [
                ("diffAddLine", MarkdownCodeBlockPalette.diffAddLineUIColor),
                ("diffDeleteLine", MarkdownCodeBlockPalette.diffDeleteLineUIColor),
            ] {
                let line = try #require(values[field] as? [String: Any])
                let expectedHex = try Self.hex(try #require(line["from"] as? String))
                let expectedAlpha = try #require(line["alpha"] as? Double)
                let actual = Self.rgba(color, traits)
                #expect(actual.hex == expectedHex, "\(key).\(field)")
                #expect(abs(actual.alpha - expectedAlpha) < 0.001, "\(key).\(field) alpha")
            }
        }

        // Light code block background / header bar / header text
        let light = try #require(contract["light"] as? [String: Any])
        let lightTraits = Self.traits(.light)
        #expect(Self.rgba(MarkdownCodeBlockPalette.backgroundUIColor, lightTraits).hex
            == (try Self.hex(try #require(light["codeBg"] as? String))))
        #expect(Self.rgba(MarkdownCodeBlockPalette.headerBackgroundUIColor, lightTraits).hex
            == (try Self.hex(try #require(light["codeHeaderBg"] as? String))))
        #expect(Self.rgba(MarkdownCodeBlockPalette.secondaryUIColor, lightTraits).hex
            == (try Self.hex(try #require(light["headerText"] as? String))))
    }

    @Test("dark_roles_ignore_palette: dark syntax colors are unchanged across the 7 palettes, and the code block background follows the palette")
    func darkRolesIgnorePalette() throws {
        let dark = try #require(try Self.loadContract()["dark"] as? [String: Any])
        for id in OriveoDarkPaletteID.allCases {
            let traits = Self.traits(.dark, id)
            for (role, color) in Self.roleColors {
                let hex = try Self.hex(try #require(dark[role] as? String))
                #expect(Self.rgba(color, traits).hex == hex, "\(id.rawValue).\(role)")
            }
            #expect(Self.rgba(MarkdownCodeBlockPalette.backgroundUIColor, traits).hex == id.palette.codeBg)
            #expect(Self.rgba(MarkdownCodeBlockPalette.headerBackgroundUIColor, traits).hex == id.palette.codeHeaderBg)
        }
    }

    @Test("classify_cases: for every [text, role] pair, the whole first occurrence takes that role's color")
    func classifyCasesPass() throws {
        let cases = try #require(try Self.loadContract()["classifyCases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        let light = Self.traits(.light)
        for item in cases {
            let name = try #require(item["name"] as? String)
            let language = try #require(item["language"] as? String)
            let code = try #require(item["code"] as? String)
            let expect = try #require(item["expect"] as? [[String]])
            let highlighted = SyntaxHighlighter.highlightUncached(
                code, language: language, baseColor: MarkdownCodeBlockPalette.foregroundUIColor
            )
            let ns = code as NSString
            for pair in expect {
                let text = pair[0]
                let role = pair[1]
                let expected = Self.rgba(try #require(Self.roleColors[role]), light).hex
                let range = ns.range(of: text)
                #expect(range.location != NSNotFound, "\(name): \(text) is not in the code")
                guard range.location != NSNotFound else { continue }
                for index in range.location ..< NSMaxRange(range) {
                    let color = highlighted.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor
                    let actual = color.map { Self.rgba($0, light).hex }
                    #expect(actual == expected, "\(name): character \(index - range.location) of \(text) should be \(role)")
                }
            }
        }
    }

    @Test("comments_not_italic: comment fonts are not italic (italicComments=false)")
    func commentsNotItalic() throws {
        #expect(try Self.loadContract()["italicComments"] as? Bool == false)
        for (language, code, comment) in [
            ("swift", "let a = 1 // comment", "// comment"),
            ("python", "x = 1  # note", "# note"),
            ("swift", "/* block */", "/* block */"),
        ] {
            let highlighted = SyntaxHighlighter.highlightUncached(
                code, language: language, baseColor: MarkdownCodeBlockPalette.foregroundUIColor
            )
            let range = (code as NSString).range(of: comment)
            let color = highlighted.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
            #expect(color == MarkdownCodeBlockPalette.commentUIColor)
            let font = try #require(highlighted.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont)
            #expect(!font.fontDescriptor.symbolicTraits.contains(.traitItalic))
        }
    }

    @Test("diff_line_background: the full-line background of added / removed lines spans the text view's full width (static card)")
    func diffLineBackgroundFillsWidth() throws {
        let code = "@@ -1 +1 @@\n-let a = 1\n+let a = 2\n let b = 3"
        let card = UIKitCodeBlockCard(language: "diff", content: code, parentViewController: nil)
        card.frame = CGRect(x: 0, y: 0, width: 360, height: 400)
        card.setNeedsLayout()
        card.layoutIfNeeded()
        let textView = card._testCodeTextView
        textView.layoutIfNeeded()

        let decorator = try #require(textView.codeLineBackgrounds)
        let stripes = decorator._testStripeFrames
        #expect(stripes.count == 2, "only the - / + lines get a background")
        for stripe in stripes {
            #expect(stripe.minX == 0)
            #expect(abs(stripe.width - textView.bounds.width) < 0.5, "the full-line background must span the text view's full width")
            #expect(stripe.height > 0)
        }
        if stripes.count == 2 {
            #expect(stripes[0].maxY <= stripes[1].minY + 0.5, "the two bands touch vertically without overlapping")
        }

        let attributed = try #require(card._testCodeAttributedText)
        let deleteLoc = (code as NSString).range(of: "-let").location
        let addLoc = (code as NSString).range(of: "+let").location
        #expect(attributed.attribute(SyntaxHighlighter.lineBackgroundKey, at: deleteLoc, effectiveRange: nil) as? UIColor
            == MarkdownCodeBlockPalette.diffDeleteLineUIColor)
        #expect(attributed.attribute(SyntaxHighlighter.lineBackgroundKey, at: addLoc, effectiveRange: nil) as? UIColor
            == MarkdownCodeBlockPalette.diffAddLineUIColor)
    }

    @Test("diff_streaming_parity: line-by-line streaming highlight of a diff equals the final full pass (including the full-line background attribute)")
    func diffStreamingMatchesFinal() {
        let code = "--- a/x.swift\n+++ b/x.swift\n@@ -1,2 +1,2 @@\n-let a = 1 /* x\n+let a = 2\n let b = 3"
        let renderer = AssistantStreamingCodeRenderer()
        renderer.update(language: "diff", code: code)
        let harvested = renderer.harvestAttributedCodeForHandoff(fullContent: code)
        let final = SyntaxHighlighter.highlightUncached(
            code, language: "diff", baseColor: MarkdownCodeBlockPalette.foregroundUIColor
        )
        #expect(harvested?.isEqual(to: final) == true)
    }

    // MARK: - helpers

    private static func traits(_ style: UIUserInterfaceStyle, _ palette: OriveoDarkPaletteID = .defaultID) -> UITraitCollection {
        UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits.oriveoDarkPalette = .preset(palette)
        }
    }

    private static func rgba(_ color: UIColor, _ traits: UITraitCollection) -> (hex: UInt, alpha: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        let hex = (UInt((r * 255).rounded()) << 16) | (UInt((g * 255).rounded()) << 8) | UInt((b * 255).rounded())
        return (hex, Double(a))
    }

    private static func hex(_ string: String) throws -> UInt {
        let digits = string.hasPrefix("#") ? String(string.dropFirst()) : string
        return try #require(UInt(digits, radix: 16), "invalid color value \(string)")
    }

    static func loadContract() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor
                .appendingPathComponent("shared")
                .appendingPathComponent("theme-contracts")
                .appendingPathComponent("code-highlight.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                return try #require(object as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
