import Foundation
import MarkdownUI
import SwiftUI
import UIKit

private struct NetworkDisabledMarkdownImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        EmptyView()
    }
}

private struct NetworkDisabledMarkdownInlineImageProvider: InlineImageProvider {
    private struct DisabledError: Error {}

    func image(with url: URL, label: String) async throws -> Image {
        throw DisabledError()
    }
}

nonisolated struct MarkdownTypography: Equatable, Sendable {
    var baseFontSize: CGFloat = 17
    var lineHeightMultiple: CGFloat = 1.2
    var paragraphSpacing: CGFloat = 12
    var emphasizedHeadings: Bool = false

    static let chat = MarkdownTypography()
    static let notes = MarkdownTypography(paragraphSpacing: 14, emphasizedHeadings: true)

    var heading1Size: CGFloat { baseFontSize + (emphasizedHeadings ? 9 : 6) }
    var heading2Size: CGFloat { baseFontSize + (emphasizedHeadings ? 4 : 2) }
    var heading3Size: CGFloat { baseFontSize + (emphasizedHeadings ? 1 : 0) }
    var cacheKey: String { "\(baseFontSize)-\(lineHeightMultiple)-\(paragraphSpacing)-\(emphasizedHeadings)" }
}

struct MarkdownMessageView: View {
    let text: String
    var isStreaming: Bool = false
    var showsStreamingCursor: Bool = true
    var foregroundColor: Color = OriveoTheme.Palette.textPrimary
    var renderHint: MarkdownRenderHint? = nil
    var typography: MarkdownTypography = .chat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        renderedContent
            .markdownImageProvider(NetworkDisabledMarkdownImageProvider())
            .markdownInlineImageProvider(NetworkDisabledMarkdownInlineImageProvider())
            .environment(\.openURL, OpenURLAction { url in
                ExternalURLPolicy.allows(url) ? .systemAction(url) : .discarded
            })
    }

    @ViewBuilder
    private var renderedContent: some View {
        if isStreaming {
            StreamingMarkdownView(
                text: text,
                isStreaming: true,
                showsCursor: showsStreamingCursor,
                foregroundColor: foregroundColor,
                reduceMotion: reduceMotion,
                typography: typography
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            StaticMarkdownContent(
                text: text,
                foregroundColor: foregroundColor,
                theme: Self.theme(for: typography),
                renderHint: renderHint,
                typography: typography
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    nonisolated static func needsMarkdownRendering(_ text: String) -> Bool {
        staticRenderingMode(for: text) != .plainText
    }

    nonisolated static func needsBlockMarkdownLayout(_ text: String) -> Bool {
        staticRenderingMode(for: text) == .blockMarkdown
    }

    nonisolated static func staticRenderingMode(for text: String) -> MarkdownStaticRenderingMode {
        MarkdownRenderingClassifier.staticRenderingMode(for: text)
    }

    nonisolated static func resolvedRenderingMode(
        for text: String,
        renderHint: MarkdownRenderHint?
    ) -> MarkdownStaticRenderingMode {
        MarkdownRenderingClassifier.resolvedRenderingMode(for: text, renderHint: renderHint)
    }

    nonisolated static func shouldNotifyHeightChange(from previousHeight: CGFloat, to newHeight: CGFloat) -> Bool {
        MarkdownRenderingClassifier.shouldNotifyHeightChange(from: previousHeight, to: newHeight)
    }

    nonisolated static func streamingLayoutSplit(
        for text: String,
        keepsCurrentTail: Bool
    ) -> (committed: String, tail: String) {
        MarkdownStreamingTextSplitter.split(text, keepsCurrentTail: keepsCurrentTail)
    }

    /// Table border: dark mode uses the palette border (white at 10%); zebra rows: dark mode uses the palette bgInset; light mode is unchanged (same as UIKitTableCard).
    static let tableBorder = Color.dynamic(light: 0xD1D5DB, dark: 0xFFFFFF, darkAlpha: 0.10)
    static let tableAltRowBg = Color.dynamic(light: 0xF3F4F6, dark: \.bgInset, lightAlpha: 0.5)

    static let cachedTheme: MarkdownUI.Theme = makeTheme(.chat)
    static let notesTheme: MarkdownUI.Theme = makeTheme(.notes)

    static func theme(for typography: MarkdownTypography) -> MarkdownUI.Theme {
        typography == .notes ? notesTheme : cachedTheme
    }

    static func makeTheme(_ typography: MarkdownTypography) -> MarkdownUI.Theme {
        let textColor = OriveoTheme.Palette.textPrimary
        let inlineFg = Color(uiColor: MarkdownAttributedStringRenderer.codeFg)
        let inlineBg = Color(uiColor: MarkdownAttributedStringRenderer.codeBg)
        let para = typography.paragraphSpacing

        return MarkdownUI.Theme()
            .text {
                ForegroundColor(textColor)
                FontSize(typography.baseFontSize)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(14)
                ForegroundColor(inlineFg)
                BackgroundColor(inlineBg)
            }
            .link {
                ForegroundColor(OriveoTheme.Palette.primary)
            }
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: 0, bottom: para)
            }
            .codeBlock { configuration in
                CodeBlockCard(language: configuration.language, content: configuration.content)
                    .markdownMargin(top: para, bottom: para)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownMargin(top: typography.emphasizedHeadings ? para + 8 : para,
                                    bottom: Self.markdownUIHeadingBottomMargin(level: 1, typography: typography))
                    .markdownTextStyle {
                        FontWeight(typography.emphasizedHeadings ? .heavy : .bold)
                        FontSize(typography.heading1Size)
                        ForegroundColor(textColor)
                    }
            }
            .heading2 { configuration in
                if typography.emphasizedHeadings {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(OriveoTheme.Palette.primary)
                            .frame(width: 4)
                        configuration.label
                            .markdownTextStyle {
                                FontWeight(.bold)
                                FontSize(typography.heading2Size)
                                ForegroundColor(textColor)
                            }
                    }
                    .markdownMargin(top: para + 10, bottom: Self.markdownUIHeadingBottomMargin(level: 2, typography: typography))
                } else {
                    configuration.label
                        .markdownMargin(top: para, bottom: Self.markdownUIHeadingBottomMargin(level: 2, typography: typography))
                        .markdownTextStyle {
                            FontWeight(.semibold)
                            FontSize(typography.heading2Size)
                            ForegroundColor(textColor)
                        }
                }
            }
            .heading3 { configuration in
                configuration.label
                    .markdownMargin(top: typography.emphasizedHeadings ? para : 4, bottom: Self.markdownUIHeadingBottomMargin(level: 3, typography: typography))
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(typography.heading3Size)
                        ForegroundColor(typography.emphasizedHeadings ? OriveoTheme.Palette.primary : textColor)
                    }
            }
            .blockquote { configuration in
                HStack(spacing: OriveoTheme.Spacing.sm) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(OriveoTheme.Palette.primary.opacity(0.5))
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle {
                            ForegroundColor(OriveoTheme.Palette.textSecondary)
                        }
                }
                .padding(.vertical, OriveoTheme.Spacing.xs)
                .markdownMargin(top: 4, bottom: 4)
            }
            .table { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(
                        .init(.allBorders, color: Self.tableBorder, strokeStyle: .init(lineWidth: 0.5))
                    )
                    .markdownTableBackgroundStyle(
                        .alternatingRows(
                            Color.dynamic(light: 0xFFFFFF, dark: \.surfaceRaised).opacity(0),
                            Self.tableAltRowBg
                        )
                    )
                    .markdownMargin(top: 8, bottom: 8)
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        if configuration.row == 0 { FontWeight(.semibold) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
            }
    }

    private var oriveoTheme: MarkdownUI.Theme { Self.cachedTheme }
}

private nonisolated enum MarkdownRegexSupport {
    static let tableSeparatorRegex = try! NSRegularExpression(
        pattern: #"(?m)^\|[\s:]*-+[\s:]*\|"#
    )
    static let horizontalRuleRegex = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*([-*_])\1{2,}[ \t]*$"#
    )
    static let htmlBoldRegex = try! NSRegularExpression(pattern: #"<(b|strong)>(.*?)</\1>"#)
    static let htmlItalicRegex = try! NSRegularExpression(pattern: #"<(i|em)>(.*?)</\1>"#)
    static let htmlStrikeRegex = try! NSRegularExpression(pattern: #"<(s|del)>(.*?)</\1>"#)
    static let htmlCodeRegex = try! NSRegularExpression(pattern: #"<code>(.*?)</code>"#)
    static let isolatedLineBreakRegex = try! NSRegularExpression(
        pattern: #"(?<!\n)(?<!  )\n(?!\n|#{1,6} |> |\|)"#
    )
    static let thematicBreakRemovalRegex = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*[-*_]{3,}[ \t]*$"#
    )
    static let orderedListRegex = try! NSRegularExpression(
        pattern: #"(?m)^([ \t]*)(\d+)\. "#
    )
    static let unorderedListRegex = try! NSRegularExpression(
        pattern: #"(?m)^([ \t]*)[-*] "#
    )

    static func containsMatch(_ regex: NSRegularExpression, in text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func replacingMatches(
        in text: String,
        regex: NSRegularExpression,
        with template: String
    ) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    static func convertInlineHTMLToMarkdown(_ text: String) -> String {
        var result = text
        result = replacingMatches(in: result, regex: htmlBoldRegex, with: "**$2**")
        result = replacingMatches(in: result, regex: htmlItalicRegex, with: "*$2*")
        result = replacingMatches(in: result, regex: htmlStrikeRegex, with: "~~$2~~")
        result = replacingMatches(in: result, regex: htmlCodeRegex, with: "`$1`")
        return result
    }

    static func preprocessForMarkdownUI(_ text: String) -> String {
        var result = convertInlineHTMLToMarkdown(text)
        result = replacingMatches(in: result, regex: isolatedLineBreakRegex, with: "\n\n")
        return result
    }
}

nonisolated enum StaticMarkdownMathSupport {
    struct Segment {
        let latex: String
        let isInline: Bool
    }

    private static let tokenOpen: Character = "\u{E002}"
    private static let tokenClose: Character = "\u{E003}"
    private static let tokenRegex = try! NSRegularExpression(pattern: "\u{E002}(\\d+)\u{E003}")
    private static let inlineMathRegex = try! NSRegularExpression(
        pattern: #"(?<!\$)\$([^\$\n]+?)\$(?!\$)"#
    )

    static func containsMathDelimiters(_ text: String) -> Bool {
        if text.contains("$$") || text.contains("\\[") || text.contains("\\(") { return true }
        guard text.contains("$") else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return inlineMathRegex.firstMatch(in: text, range: range) != nil
    }

    static func extract(_ text: String) -> (text: String, segments: [Segment]) {
        let normalized = LatexNormalizer.normalize(text)
        var segments: [Segment] = []
        let tokenized = LatexNormalizer.transformingOutsideCode(normalized) { masked in
            var result = extractBlockMath(masked, into: &segments)
            result = extractInlineMath(result, into: &segments)
            return result
        }
        return (tokenized, segments)
    }

    static func restoreTokens(_ text: String, segments: [Segment]) -> String {
        guard !segments.isEmpty else { return text }
        let ns = text as NSString
        let matches = tokenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            guard let idx = Int(ns.substring(with: match.range(at: 1))), idx >= 0, idx < segments.count else { continue }
            let seg = segments[idx]
            result.replaceCharacters(in: match.range(at: 0), with: seg.isInline ? "$\(seg.latex)$" : "$$\(seg.latex)$$")
        }
        return result as String
    }

    static func applyAttachments(
        to str: NSMutableAttributedString,
        segments: [Segment],
        baseFontSize: CGFloat,
        textColor: UIColor
    ) -> Bool {
        guard !segments.isEmpty else { return false }
        let ns = str.string as NSString
        let matches = tokenRegex.matches(in: str.string, range: NSRange(location: 0, length: ns.length))
        var unresolved = false
        for match in matches.reversed() {
            guard let idx = Int(ns.substring(with: match.range(at: 1))), idx >= 0, idx < segments.count else { continue }
            let seg = segments[idx]
            let location = match.range(at: 0).location
            let baseFont = (str.attribute(.font, at: location, effectiveRange: nil) as? UIFont)
                ?? OriveoTheme.Typography.chatBodyUIFont(size: baseFontSize)
            let image = LatexImageCache.requestImage(
                latex: seg.latex,
                fontSize: seg.isInline ? baseFont.pointSize * 1.1 : 20,
                textColor: textColor,
                inline: seg.isInline
            )
            guard let image else {
                unresolved = true
                let fallback = seg.isInline ? "$\(seg.latex)$" : "$$\(seg.latex)$$"
                let attrs = str.attributes(at: location, effectiveRange: nil)
                str.replaceCharacters(in: match.range(at: 0), with: NSAttributedString(string: fallback, attributes: attrs))
                continue
            }
            let attachment = LatexAttachment(image: image, font: baseFont, isInline: seg.isInline, latex: seg.latex)
            let replacement = NSMutableAttributedString(attachment: attachment)
            let fullRange = NSRange(location: 0, length: replacement.length)
            if seg.isInline {
                if let para = str.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle {
                    replacement.addAttribute(.paragraphStyle, value: para, range: fullRange)
                }
            } else {
                let para = NSMutableParagraphStyle()
                para.alignment = .center
                para.paragraphSpacingBefore = 8
                para.paragraphSpacing = 8
                replacement.addAttribute(.paragraphStyle, value: para, range: fullRange)
                replacement.addAttribute(.font, value: baseFont, range: fullRange)
            }
            str.replaceCharacters(in: match.range(at: 0), with: replacement)
        }
        return unresolved
    }

    private static func token(for latex: String, isInline: Bool, into segments: inout [Segment]) -> String {
        let idx = segments.count
        segments.append(Segment(latex: latex, isInline: isInline))
        return "\(tokenOpen)\(idx)\(tokenClose)"
    }

    private static func extractBlockMath(_ text: String, into segments: inout [Segment]) -> String {
        guard text.contains("$$") else { return text }
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count >= 5 {
                let latex = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                if !latex.isEmpty {
                    out.append(token(for: latex, isInline: false, into: &segments))
                    i += 1
                    continue
                }
            }
            if trimmed.hasPrefix("$$"), !(trimmed.hasSuffix("$$") && trimmed.count >= 5) {
                var body: [String] = []
                let first = String(trimmed.dropFirst(2))
                if !first.isEmpty { body.append(first) }
                var j = i + 1
                var closed = false
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if let close = t.range(of: "$$") {
                        let pre = String(t[..<close.lowerBound])
                        if !pre.isEmpty { body.append(pre) }
                        closed = true
                        j += 1
                        break
                    }
                    body.append(lines[j])
                    j += 1
                }
                let latex = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if closed, !latex.isEmpty {
                    out.append(token(for: latex, isInline: false, into: &segments))
                    i = j
                    continue
                }
            }
            out.append(lines[i])
            i += 1
        }
        return out.joined(separator: "\n")
    }

    private static func extractInlineMath(_ text: String, into segments: inout [Segment]) -> String {
        guard text.contains("$") else { return text }
        let ns = text as NSString
        let matches = inlineMathRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            let latex = ns.substring(with: match.range(at: 1))
            guard !latex.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            result.replaceCharacters(in: match.range(at: 0), with: token(for: latex, isInline: true, into: &segments))
        }
        return result as String
    }
}

nonisolated enum MarkdownStreamingTextSplitter {
    static func split(
        _ text: String,
        keepsCurrentTail: Bool
    ) -> (committed: String, tail: String) {
        guard keepsCurrentTail, !text.isEmpty else { return (text, "") }

        guard let splitIndex = findLastSafeSplit(in: text) else {
            return ("", text)
        }
        return (String(text[..<splitIndex]), String(text[splitIndex...]))
    }

    private static func findLastSafeSplit(in text: String) -> String.Index? {
        guard let lastDoubleNewline = text.range(of: "\n\n", options: .backwards) else {
            return nil
        }

        let candidateIndex = lastDoubleNewline.upperBound
        let prefix = text[..<candidateIndex]

        var fenceCount = 0
        var search = prefix[...]
        while let range = search.range(of: "```") {
            fenceCount += 1
            search = search[range.upperBound...]
        }

        if fenceCount.isMultiple(of: 2) {
            return candidateIndex
        }

        var lastUnpairedFence: String.Index? = nil
        fenceCount = 0
        search = text[...]
        while let range = search.range(of: "```") {
            fenceCount += 1
            if !fenceCount.isMultiple(of: 2) {
                lastUnpairedFence = range.lowerBound
            }
            search = search[range.upperBound...]
        }

        guard let fenceStart = lastUnpairedFence else { return nil }

        let beforeFence = text[..<fenceStart]
        guard let split = beforeFence.range(of: "\n\n", options: .backwards) else {
            return fenceStart
        }
        return split.upperBound
    }
}

private struct StaticMarkdownContent: View {
    let text: String
    let foregroundColor: Color
    let theme: MarkdownUI.Theme
    let renderHint: MarkdownRenderHint?
    var typography: MarkdownTypography = .chat

    var body: some View {
        if text.isEmpty {
            Color.clear.frame(width: 0, height: 0)
        } else {
            switch MarkdownMessageView.resolvedRenderingMode(for: text, renderHint: renderHint) {
            case .plainText:
                SelectableTextLabel(
                    text: text,
                    fontSize: typography.baseFontSize,
                    textColor: UIColor(foregroundColor)
                )
            case .blockMarkdown:
                if Self.containsTable(text) || Self.containsHorizontalRule(text) {
                    if StaticMarkdownMathSupport.containsMathDelimiters(text) {
                        MathAwareBlockBody(text: text, theme: theme, typography: typography)
                    } else {
                        Self.markdownUIBody(text, theme: theme)
                    }
                } else {
                    CachedMarkdownView(text: text, typography: typography)
                }
            case .segmentedCodeMarkdown:
                SegmentedMarkdownBody(text: text, theme: theme, typography: typography)
                    .equatable()
            case .inlineMarkdown:
                CachedMarkdownView(text: text, typography: typography)
            }
        }
    }

    /// `asIs`: still handed to `StaticMarkdownContent` unchanged (empty text, unclosed fences and other cases that are never split).
    nonisolated enum LeafRoute { case asIs, plainText, markdownUI, mathAware, cached }

    /// Which leaf view `body` picks for a piece of text without code fences (same conditions as the branches in `body`).
    nonisolated static func leafRoute(_ text: String) -> LeafRoute {
        guard !text.isEmpty else { return .asIs }
        switch MarkdownMessageView.resolvedRenderingMode(for: text, renderHint: nil) {
        case .plainText: return .plainText
        case .blockMarkdown:
            guard containsTable(text) || containsHorizontalRule(text) else { return .cached }
            return StaticMarkdownMathSupport.containsMathDelimiters(text) ? .mathAware : .markdownUI
        case .inlineMarkdown: return .cached
        case .segmentedCodeMarkdown: return .asIs
        }
    }

    static func markdownUIBody(_ text: String, theme: MarkdownUI.Theme) -> some View {
        Markdown(MarkdownRegexSupport.preprocessForMarkdownUI(text))
            .markdownTheme(theme)
    }

    nonisolated private static func containsTable(_ text: String) -> Bool {
        MarkdownRegexSupport.containsMatch(MarkdownRegexSupport.tableSeparatorRegex, in: text)
    }

    nonisolated private static func containsHorizontalRule(_ text: String) -> Bool {
        MarkdownRegexSupport.containsMatch(MarkdownRegexSupport.horizontalRuleRegex, in: text)
    }
}

private struct MathAwareBlockBody: View {
    let text: String
    let theme: MarkdownUI.Theme
    let typography: MarkdownTypography

    var body: some View {
        VStack(alignment: .leading, spacing: MarkdownMessageView.codeFenceSegmentSpacing) {
            ForEach(Array(Self.groups(for: text).enumerated()), id: \.offset) { _, group in
                if group.isTableLike {
                    Markdown(MarkdownRegexSupport.preprocessForMarkdownUI(group.text))
                        .markdownTheme(theme)
                } else {
                    CachedMarkdownView(text: group.text, typography: typography)
                }
            }
        }
    }

    nonisolated struct Group {
        let text: String
        let isTableLike: Bool
    }

    nonisolated static func groups(for text: String) -> [Group] {
        let blocks = splitBlocks(LatexNormalizer.normalize(text))
        var groups: [Group] = []
        for block in blocks {
            let tableLike = MarkdownRegexSupport.containsMatch(MarkdownRegexSupport.tableSeparatorRegex, in: block)
                || MarkdownRegexSupport.containsMatch(MarkdownRegexSupport.horizontalRuleRegex, in: block)
            if let last = groups.last, last.isTableLike == tableLike {
                groups[groups.count - 1] = Group(text: last.text + "\n\n" + block, isTableLike: tableLike)
            } else {
                groups.append(Group(text: block, isTableLike: tableLike))
            }
        }
        return groups
    }

    nonisolated private static func splitBlocks(_ text: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        var fenceMarker: String? = nil
        var inMath = false

        func flush() {
            let raw = current.joined(separator: "\n")
            if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(raw)
            }
            current = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fenceMarker {
                current.append(line)
                if trimmed.hasPrefix(marker) { fenceMarker = nil }
                continue
            }
            if inMath {
                current.append(line)
                if trimmed.contains("$$") { inMath = false }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                current.append(line)
                fenceMarker = String(trimmed.prefix(3))
                continue
            }
            if trimmed.hasPrefix("$$"), !(trimmed.hasSuffix("$$") && trimmed.count >= 5) {
                current.append(line)
                inMath = true
                continue
            }
            if trimmed.isEmpty { flush(); continue }
            current.append(line)
        }
        flush()
        return blocks
    }
}

/// A segment of `SegmentedMarkdownBody` split on code fences: each segment is its own view (prose goes through `StaticMarkdownContent`, code is a `CodeBlockCard`).
nonisolated enum MarkdownCodeFenceSegment: Equatable, Sendable {
    case markdown(String)
    case code(language: String?, content: String)
}

/// One unit of lazy rendering for long bodies (used by the note detail). A whole-body render is already a stack of
/// independent leaf views; this splits out that same sequence of leaf views together with the spacing between them,
/// so the host's lazy stack can place them one by one:
/// - segmented mode: the segments of `SegmentedMarkdownBody`, spaced by `codeFenceSegmentSpacing`;
/// - MarkdownUI bodies (whole or per segment): split into groups at top-level block boundaries, with the gap between groups restored by the same formula as `BlockSequence` (see `markdownUIBlockGroups`);
/// - tables with math: the groups of `MathAwareBlockBody`, spaced like its VStack;
/// - long `CachedMarkdownView` / plain-text bodies: cut into chunks of about `textChunkUTF16` between ordinary paragraphs.
/// `NoteLazyMarkdownBodyTests` guards that the result is pixel-identical to the whole-body render.
nonisolated struct MarkdownLazyUnit: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        /// Same entry point as `StaticMarkdownContent` (it picks the route from its own content).
        case staticMarkdown(String)
        /// Goes straight to MarkdownUI (the same call as the table / rule branch of `StaticMarkdownContent`).
        case markdownUI(String)
        /// Goes straight to `CachedMarkdownView` (a chunk cut from a long body; it is not re-routed by its own content).
        case cachedMarkdown(String)
        /// Goes straight to `SelectableTextLabel` (a chunk cut from a long plain text).
        case plainText(String)
        case code(language: String?, content: String)

        var text: String {
            switch self {
            case let .staticMarkdown(text), let .markdownUI(text), let .cachedMarkdown(text), let .plainText(text): text
            case let .code(_, content): content
            }
        }
    }

    let content: Content
    /// Distance from the previous unit (0 for the first).
    let spacingBefore: CGFloat
}

nonisolated extension MarkdownMessageView {
    /// Segment spacing of `SegmentedMarkdownBody` / `MathAwareBlockBody` (= `OriveoTheme.Spacing.md`; a literal so units can be cut off the main thread;
    /// `NoteLazyMarkdownBodyTests` guards that the two are equal).
    static let codeFenceSegmentSpacing: CGFloat = 12

    /// Target length of a chunk cut from a long body (about a screen and a half).
    static let textChunkUTF16 = 3_000
    /// CachedMarkdownView / plain-text bodies are chunked only above this: each is one UITextView holding the whole text, selectable across paragraphs,
    /// and rendering up to 10k characters in one piece is not expensive, so it stays as is.
    static let textChunkingThresholdUTF16 = 10_000
    /// A single block that cannot be cut at a paragraph boundary and exceeds this skips lazy rendering (same value as the bounded-viewport threshold).
    static let maximumLazyUnitUTF16 = 10_000

    /// Bottom margins of the heading levels in the MarkdownUI theme (h4-h6 are not set).
    static func markdownUIHeadingBottomMargin(level: Int, typography: MarkdownTypography) -> CGFloat? {
        switch level {
        case 1: return typography.emphasizedHeadings ? 8 : 4
        case 2: return typography.emphasizedHeadings ? 6 : 4
        case 3: return 2
        default: return nil
        }
    }

    /// The sequence of leaf views a whole-body render actually stacks; a single element when the body is one view (or should not be split).
    static func lazyUnits(for text: String, typography: MarkdownTypography) -> [MarkdownLazyUnit] {
        var units: [MarkdownLazyUnit] = []
        func append(_ content: MarkdownLazyUnit.Content, spacing: CGFloat) {
            units.append(MarkdownLazyUnit(content: content, spacingBefore: units.isEmpty ? 0 : spacing))
        }
        func appendStatic(_ piece: String, spacing: CGFloat) {
            switch StaticMarkdownContent.leafRoute(piece) {
            case .markdownUI:
                for (index, group) in markdownUIBlockGroups(piece, typography: typography).enumerated() {
                    append(.markdownUI(group.text), spacing: index == 0 ? spacing : group.spacingBefore)
                }
            case .mathAware:
                for (index, group) in MathAwareBlockBody.groups(for: piece).enumerated() {
                    let groupSpacing = index == 0 ? spacing : codeFenceSegmentSpacing
                    if group.isTableLike {
                        append(.markdownUI(group.text), spacing: groupSpacing)
                    } else {
                        appendCached(group.text, spacing: groupSpacing)
                    }
                }
            case .cached:
                appendCached(piece, spacing: spacing, keepsStaticEntry: true)
            case .plainText:
                guard piece.utf16.count > textChunkingThresholdUTF16 else {
                    append(.staticMarkdown(piece), spacing: spacing)
                    return
                }
                for (index, chunk) in plainTextChunks(piece).enumerated() {
                    append(.plainText(chunk), spacing: index == 0 ? spacing : 0)
                }
            case .asIs:
                append(.staticMarkdown(piece), spacing: spacing)
            }
        }
        /// `keepsStaticEntry`: when no cutting is needed, still go through `StaticMarkdownContent` (same entry as the whole-body render); MathAware groups already go straight to CachedMarkdownView.
        func appendCached(_ text: String, spacing: CGFloat, keepsStaticEntry: Bool = false) {
            guard text.utf16.count > textChunkingThresholdUTF16 else {
                append(keepsStaticEntry ? .staticMarkdown(text) : .cachedMarkdown(text), spacing: spacing)
                return
            }
            for (index, chunk) in cachedMarkdownChunks(text, typography: typography).enumerated() {
                append(.cachedMarkdown(chunk.text), spacing: index == 0 ? spacing : chunk.spacingBefore)
            }
        }

        if staticRenderingMode(for: text) == .segmentedCodeMarkdown {
            for segment in SegmentedMarkdownBody.parseSegments(text) {
                switch segment {
                case let .markdown(piece):
                    appendStatic(piece, spacing: codeFenceSegmentSpacing)
                case let .code(language, content):
                    append(.code(language: language, content: content), spacing: codeFenceSegmentSpacing)
                }
            }
        } else {
            appendStatic(text, spacing: 0)
        }
        return units
    }

    /// Collect at least this many top-level blocks per group before looking for a cut (same granularity as Android's 8 blocks per segment).
    static let markdownUIGroupBlockCount = 8

    /// Cuts groups at top-level block boundaries, only where the next block is a paragraph or a table:
    /// - A group must not start with a heading: the h2 brand bar is a flexible shape inside an HStack, so as the first block of a
    ///   BlockSequence it is 2pt different in height from a non-first block (measured pixel by pixel in the simulator), which would
    ///   make a heading-led group differ from the whole-body render; paragraphs and tables are rigid.
    /// - Gap between groups = max(previous block's bottom margin, next block's top margin), the same formula as `BlockSequence.topPaddingLength`;
    ///   the previous block is classified by its last line (preprocessing splits single newlines into paragraphs, so the last line is the real last block).
    /// Text with reference-style link definitions or footnote definitions is not cut (a definition and its reference could land in different groups).
    private static func markdownUIBlockGroups(
        _ text: String,
        typography: MarkdownTypography
    ) -> [(text: String, spacingBefore: CGFloat)] {
        guard !text.contains("]:") || referenceDefinitionRegex.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)
        ) == nil else { return [(text, 0)] }

        // Top-level blocks: separated by blank lines (blank lines inside a ~~~ fence do not count).
        var blocks: [[Substring]] = []
        var current: [Substring] = []
        var inTildeFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("~~~") { inTildeFence.toggle() }
            if !inTildeFence, line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                if !current.isEmpty { blocks.append(current); current = [] }
                continue
            }
            current.append(line)
        }
        if !current.isEmpty { blocks.append(current) }
        guard blocks.count > markdownUIGroupBlockCount else { return [(text, 0)] }

        var groups: [(text: String, spacingBefore: CGFloat)] = []
        var groupStart = 0
        var groupSpacing: CGFloat = 0
        for index in 1..<blocks.count where index - groupStart >= markdownUIGroupBlockCount {
            guard let nextTop = markdownUIRigidBlockTopMargin(firstLine: blocks[index][0]),
                  let previousLast = blocks[index - 1].last,
                  let previousBottom = markdownUIBottomMargin(lastLine: previousLast, typography: typography)
            else { continue }
            groups.append((blocks[groupStart..<index].map { $0.joined(separator: "\n") }.joined(separator: "\n\n"), groupSpacing))
            groupStart = index
            groupSpacing = max(previousBottom ?? 0, nextTop)
        }
        groups.append((blocks[groupStart...].map { $0.joined(separator: "\n") }.joined(separator: "\n\n"), groupSpacing))
        return groups
    }

    private static let referenceDefinitionRegex = try! NSRegularExpression(pattern: #"(?m)^ {0,3}\[[^\]]+\]:"#)

    /// Top margin of a rigid block that may start a group: 8 for a table, 0 for a plain paragraph; anything else (heading / list / quote / indented / HTML / image / fence) returns nil and is not cut.
    private static func markdownUIRigidBlockTopMargin(firstLine: Substring) -> CGFloat? {
        guard let first = firstLine.first else { return nil }
        if first == "|" { return 8 }
        if "#>-*+<[!~` \t=_".contains(first) { return nil }
        if first.isNumber {
            let digits = firstLine.prefix(while: \.isNumber)
            let after = firstLine.dropFirst(digits.count).first
            if after == "." || after == ")" { return nil }
        }
        return 0
    }

    /// Bottom margin of the previous block (classified by its last line). Outer nil = cannot tell, do not cut; inner nil = the block has no margin.
    private static func markdownUIBottomMargin(lastLine: Substring, typography: MarkdownTypography) -> CGFloat?? {
        guard let first = lastLine.first else { return nil }
        if first == "|" { return .some(8) }
        if let level = atxHeadingLevel(lastLine) {
            return .some(markdownUIHeadingBottomMargin(level: level, typography: typography))
        }
        // Setext underline, HTML, fence closing: do not cut.
        if lastLine.allSatisfy({ $0 == "=" || $0 == "-" || $0 == " " }) || first == "<" || lastLine.hasPrefix("~~~") {
            return nil
        }
        // Paragraph / list / quote / indented code: its own or its child paragraph's bottom margin is the paragraph spacing.
        return .some(typography.paragraphSpacing)
    }

    /// ATX heading level at the start of a line (not indented); `#` must be followed by a space / tab or end of line (CommonMark).
    private static func atxHeadingLevel(_ line: Substring) -> Int? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", level < 7 {
            level += 1
            index = line.index(after: index)
        }
        guard (1...6).contains(level) else { return nil }
        guard index == line.endIndex || line[index] == " " || line[index] == "\t" else { return nil }
        return level
    }
}

nonisolated extension MarkdownMessageView {
    /// Top-level blocks separated by blank lines (blank lines inside ``` / ~~~ fences and $$ display math do not count), returned with the separator before each block so it can be rejoined verbatim.
    private static func blankLineBlocks(_ text: String) -> [(separator: String, lines: [Substring])] {
        var blocks: [(separator: String, lines: [Substring])] = []
        var current: [Substring] = []
        var pendingSeparator = ""
        var blankRun = 0
        var fence: Substring?
        var inMath = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if fence == nil, !inMath, trimmed.isEmpty {
                blankRun += 1
                continue
            }
            if blankRun > 0, !current.isEmpty {
                blocks.append((pendingSeparator, current))
                current = []
                pendingSeparator = String(repeating: "\n", count: blankRun + 1)
            }
            blankRun = 0
            current.append(line)
            if let marker = fence {
                if trimmed.hasPrefix(marker) { fence = nil }
            } else if inMath {
                if trimmed.contains("$$") { inMath = false }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = Substring(trimmed.prefix(3))
            } else if trimmed.hasPrefix("$$"), !(trimmed.hasSuffix("$$") && trimmed.count >= 5) {
                inMath = true
            }
        }
        if !current.isEmpty { blocks.append((pendingSeparator, current)) }
        return blocks
    }

    /// Paragraph class of a line in the CachedMarkdownView render: only two paragraph styles exist, heading (16 / 12 before, 4 after) and the rest (after = paragraph spacing).
    /// Tables / fences / math / indented / HTML / setext underlines return nil: no cut next to them.
    private enum CachedLineKind {
        case heading(level: Int)
        case body
    }

    private static func cachedLineKind(_ line: Substring) -> CachedLineKind? {
        guard let first = line.first else { return nil }
        if "|<`~$ \t\\".contains(first) { return nil }
        if line.allSatisfy({ $0 == "=" || $0 == "-" || $0 == " " }) { return nil }
        if let level = atxHeadingLevel(line) { return .heading(level: level) }
        return .body
    }

    /// Same heading rule as `renderMarkdownTrackingMath`: only a font larger than the body counts as a heading; at least the h1 size gets 16 before, otherwise 12.
    private static func cachedHeadingSize(level: Int, typography: MarkdownTypography) -> CGFloat {
        switch level {
        case 1: return typography.heading1Size
        case 2: return typography.heading2Size
        default: return typography.heading3Size
        }
    }

    /// Distance between two blocks = the previous block's last paragraph's spacing after + the next block's first paragraph's spacing before. For a block on its own,
    /// the last paragraph's trailing and the first paragraph's leading spacing do not count toward height (measured: paragraph to paragraph 14, paragraph to heading 26, heading to paragraph 4).
    private static func cachedChunkGap(previous: CachedLineKind, next: CachedLineKind, typography: MarkdownTypography) -> CGFloat {
        func isHeading(_ kind: CachedLineKind) -> CGFloat? {
            guard case let .heading(level) = kind else { return nil }
            let size = cachedHeadingSize(level: level, typography: typography)
            return size > typography.baseFontSize ? size : nil
        }
        let after: CGFloat = isHeading(previous) != nil ? 4 : typography.paragraphSpacing
        let before: CGFloat = isHeading(next).map { $0 >= typography.heading1Size ? 16 : 12 } ?? 0
        return after + before
    }

    /// Cuts a CachedMarkdownView body into chunks of about `textChunkUTF16`, at blank lines where the paragraph style on both sides is known.
    static func cachedMarkdownChunks(_ text: String, typography: MarkdownTypography) -> [(text: String, spacingBefore: CGFloat)] {
        let blocks = blankLineBlocks(text)
        var chunks: [(text: String, spacingBefore: CGFloat)] = []
        var current = ""
        var currentSpacing: CGFloat = 0
        for (index, block) in blocks.enumerated() {
            let body = block.lines.joined(separator: "\n")
            if index > 0, current.utf16.count >= textChunkUTF16,
               let previousLast = blocks[index - 1].lines.last, let previous = cachedLineKind(previousLast),
               let first = block.lines.first, let next = cachedLineKind(first) {
                chunks.append((current, currentSpacing))
                current = body
                currentSpacing = cachedChunkGap(previous: previous, next: next, typography: typography)
            } else {
                current += (current.isEmpty ? "" : block.separator) + body
            }
        }
        if !current.isEmpty { chunks.append((current, currentSpacing)) }
        return chunks
    }

    /// Cuts plain text into chunks of about `textChunkUTF16` at blank lines: the previous chunk keeps (separator newlines - 1) trailing newlines,
    /// which UITextView lays out as the same number of blank lines, matching the height of those blank lines in the whole text.
    static func plainTextChunks(_ text: String) -> [String] {
        let blocks = blankLineBlocks(text)
        var chunks: [String] = []
        var current = ""
        for (index, block) in blocks.enumerated() {
            let body = block.lines.joined(separator: "\n")
            if index > 0, current.utf16.count >= textChunkUTF16 {
                chunks.append(current + String(repeating: "\n", count: max(block.separator.count - 1, 0)))
                current = body
            } else {
                current += (current.isEmpty ? "" : block.separator) + body
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

/// Leaf view of a lazy unit: the same call and environment as the corresponding leaf view in a whole-body render.
struct MarkdownLazyUnitView: View {
    let unit: MarkdownLazyUnit
    var typography: MarkdownTypography = .chat

    var body: some View {
        leaf
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, unit.spacingBefore)
            .markdownImageProvider(NetworkDisabledMarkdownImageProvider())
            .markdownInlineImageProvider(NetworkDisabledMarkdownInlineImageProvider())
            .environment(\.openURL, OpenURLAction { url in
                ExternalURLPolicy.allows(url) ? .systemAction(url) : .discarded
            })
    }

    @ViewBuilder
    private var leaf: some View {
        switch unit.content {
        case let .staticMarkdown(text):
            StaticMarkdownContent(
                text: text,
                foregroundColor: OriveoTheme.Palette.textPrimary,
                theme: MarkdownMessageView.theme(for: typography),
                renderHint: nil,
                typography: typography
            )
        case let .markdownUI(text):
            StaticMarkdownContent.markdownUIBody(text, theme: MarkdownMessageView.theme(for: typography))
        case let .cachedMarkdown(text):
            CachedMarkdownView(text: text, typography: typography)
        case let .plainText(text):
            SelectableTextLabel(
                text: text,
                fontSize: typography.baseFontSize,
                textColor: UIColor(OriveoTheme.Palette.textPrimary)
            )
        case let .code(language, content):
            CodeBlockCard(language: language, content: content)
        }
    }
}

private struct SegmentedMarkdownBody: View, Equatable {
    let text: String
    let theme: MarkdownUI.Theme
    var typography: MarkdownTypography = .chat

    private static let segmentCache: NSCache<NSString, SegmentCacheEntry> = {
        let cache = NSCache<NSString, SegmentCacheEntry>()
        cache.countLimit = 200
        return cache
    }()

    static func == (lhs: SegmentedMarkdownBody, rhs: SegmentedMarkdownBody) -> Bool {
        lhs.text == rhs.text && lhs.typography == rhs.typography
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MarkdownMessageView.codeFenceSegmentSpacing) {
            ForEach(Array(Self.cachedSegments(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case let .markdown(markdownText):
                    StaticMarkdownContent(
                        text: markdownText,
                        foregroundColor: OriveoTheme.Palette.textPrimary,
                        theme: theme,
                        renderHint: nil,
                        typography: typography
                    )
                case let .code(language, content):
                    CodeBlockCard(language: language, content: content)
                }
            }
        }
    }

    typealias Segment = MarkdownCodeFenceSegment

    private class SegmentCacheEntry {
        let segments: [Segment]
        init(_ segments: [Segment]) { self.segments = segments }
    }

    private static func cachedSegments(_ text: String) -> [Segment] {
        let key = NSString(string: text)
        if let entry = segmentCache.object(forKey: key) {
            return entry.segments
        }
        let segments = parseSegments(text)
        segmentCache.setObject(SegmentCacheEntry(segments), forKey: key)
        return segments
    }

    nonisolated fileprivate static func parseSegments(_ text: String) -> [Segment] {
        guard text.contains("```") else { return [.markdown(text)] }

        var segments: [Segment] = []
        var cursor = text[...]

        while let fenceStart = cursor.range(of: "```") {
            let markdownPrefix = String(cursor[..<fenceStart.lowerBound])
            if !markdownPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.markdown(markdownPrefix))
            }

            let afterFence = cursor[fenceStart.upperBound...]
            guard let languageLineBreak = afterFence.firstIndex(of: "\n") else {
                let remaining = String(cursor)
                if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.markdown(remaining))
                }
                return segments
            }

            let language = String(afterFence[..<languageLineBreak]).trimmingCharacters(in: .whitespacesAndNewlines)
            let codeStart = afterFence.index(after: languageLineBreak)
            let codeSlice = afterFence[codeStart...]

            guard let fenceEnd = codeSlice.range(of: "```") else {
                let remaining = String(cursor)
                if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.markdown(remaining))
                }
                return segments
            }

            let codeContent = String(codeSlice[..<fenceEnd.lowerBound]).trimmingCharacters(in: .newlines)
            segments.append(.code(language: language.isEmpty ? nil : language, content: codeContent))
            cursor = codeSlice[fenceEnd.upperBound...]
        }

        let trailingMarkdown = String(cursor)
        if !trailingMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(.markdown(trailingMarkdown))
        }

        return segments.isEmpty ? [.markdown(text)] : segments
    }
}


struct CachedMarkdownView: UIViewRepresentable {
    let text: String
    var typography: MarkdownTypography = .chat

    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 150
        return cache
    }()

    private static func cacheKey(_ text: String, _ typography: MarkdownTypography, _ isDark: Bool) -> NSString {
        NSString(string: typography.cacheKey + (isDark ? "|d|" : "|l|") + text)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = ChatPassiveTextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.linkTextAttributes = [
            .foregroundColor: UIColor(OriveoTheme.Palette.primary)
        ]
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.required, for: .vertical)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let coordinator = context.coordinator
        let isDark = tv.traitCollection.userInterfaceStyle == .dark
        guard coordinator.lastText != text || coordinator.lastIsDark != isDark else { return }

        coordinator.lastText = text
        coordinator.lastIsDark = isDark

        if let cached = Self.cachedValue(for: text, typography: typography, isDark: isDark) {
            coordinator.renderGeneration &+= 1
            coordinator.hasUnresolvedLatex = false
            Self.apply(cached, to: tv)
            return
        }

        Self.apply(Self.plainTextFallback(text, typography: typography), to: tv)
        Self.scheduleRender(text: text, typography: typography, isDark: isDark, coordinator: coordinator, textView: tv)
    }

    private static func scheduleRender(
        text: String,
        typography: MarkdownTypography,
        isDark: Bool,
        coordinator: Coordinator,
        textView: UITextView
    ) {
        coordinator.renderGeneration &+= 1
        let generation = coordinator.renderGeneration

        if StaticMarkdownMathSupport.containsMathDelimiters(text) {
            coordinator.hasUnresolvedLatex = true
            coordinator.rerender = { [weak coordinator, weak textView] in
                guard let coordinator, let textView else { return }
                scheduleRender(text: text, typography: typography, isDark: isDark, coordinator: coordinator, textView: textView)
            }
            coordinator.startObservingLatexRenders()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let (rendered, unresolvedMath) = cachedRenderTracking(text, typography: typography, isDark: isDark)
            DispatchQueue.main.async {
                guard coordinator.lastText == text,
                      coordinator.renderGeneration == generation else { return }
                coordinator.hasUnresolvedLatex = unresolvedMath
                apply(rendered, to: textView)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingCompressedSize.width
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    static func cachedRender(_ text: String, typography: MarkdownTypography = .chat, isDark: Bool = false) -> NSAttributedString {
        cachedRenderTracking(text, typography: typography, isDark: isDark).rendered
    }

    static func cachedRenderTracking(
        _ text: String,
        typography: MarkdownTypography = .chat,
        isDark: Bool = false
    ) -> (rendered: NSAttributedString, unresolvedMath: Bool) {
        if let cached = cachedValue(for: text, typography: typography, isDark: isDark) { return (cached, false) }
        let result = renderMarkdownTrackingMath(text, typography: typography, isDark: isDark)
        if !result.unresolvedMath {
            cache.setObject(result.rendered, forKey: cacheKey(text, typography, isDark))
        }
        return result
    }

    private static func cachedValue(for text: String, typography: MarkdownTypography = .chat, isDark: Bool = false) -> NSAttributedString? {
        cache.object(forKey: cacheKey(text, typography, isDark))
    }

    private static func preprocessBlockElements(_ text: String) -> String {
        var result = MarkdownRegexSupport.convertInlineHTMLToMarkdown(text)
        result = MarkdownRegexSupport.replacingMatches(
            in: result,
            regex: MarkdownRegexSupport.thematicBreakRemovalRegex,
            with: ""
        )
        result = MarkdownRegexSupport.replacingMatches(
            in: result,
            regex: MarkdownRegexSupport.orderedListRegex,
            with: "$1$2\\. "
        )
        result = MarkdownRegexSupport.replacingMatches(
            in: result,
            regex: MarkdownRegexSupport.unorderedListRegex,
            with: "$1• "
        )
        return result
    }

    static func renderMarkdown(_ text: String, typography: MarkdownTypography = .chat, isDark: Bool = false) -> NSAttributedString {
        renderMarkdownTrackingMath(text, typography: typography, isDark: isDark).rendered
    }

    static func renderMarkdownTrackingMath(
        _ text: String,
        typography: MarkdownTypography = .chat,
        isDark: Bool = false
    ) -> (rendered: NSAttributedString, unresolvedMath: Bool) {
        var mathSegments: [StaticMarkdownMathSupport.Segment] = []
        var text = text
        if StaticMarkdownMathSupport.containsMathDelimiters(text) {
            (text, mathSegments) = StaticMarkdownMathSupport.extract(text)
        }
        text = preprocessBlockElements(text)
        text = MarkdownRegexSupport.replacingMatches(
            in: text,
            regex: MarkdownRegexSupport.isolatedLineBreakRegex,
            with: "\n\n"
        )
        let textColor = UIColor(OriveoTheme.Palette.textPrimary)
        let secondaryColor = UIColor(OriveoTheme.Palette.textSecondary)
        let inlineFg = MarkdownAttributedStringRenderer.codeFg
        let inlineBg = MarkdownAttributedStringRenderer.codeBg
        let linkColor = UIColor(OriveoTheme.Palette.primary)

        do {
            var attrStr = try AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .full)
            )

            attrStr.foregroundColor = Color(uiColor: textColor)
            attrStr.font = OriveoTheme.Typography.chatBodyUIFont(size: typography.baseFontSize)

            for (intent, range) in attrStr.runs[\.presentationIntent] {
                guard let intent else { continue }
                for component in intent.components {
                    switch component.kind {
                    case .header(let level):
                        switch level {
                        case 1: attrStr[range].font = OriveoTheme.Typography.chatBodyUIFont(size: typography.heading1Size, weight: .bold)
                        case 2: attrStr[range].font = OriveoTheme.Typography.chatBodyUIFont(size: typography.heading2Size, weight: .semibold)
                        default: attrStr[range].font = OriveoTheme.Typography.chatBodyUIFont(size: typography.heading3Size, weight: .semibold)
                        }
                    case .blockQuote:
                        attrStr[range].foregroundColor = Color(uiColor: secondaryColor)
                    default:
                        break
                    }
                }
            }

            for (intent, range) in attrStr.runs[\.inlinePresentationIntent] {
                guard let intent else { continue }
                if intent.contains(.code) {
                    attrStr[range].font = .monospacedSystemFont(ofSize: 14, weight: .regular)
                    // Use the UIKit scope: a SwiftUI-scope Color does not land as .foregroundColor after conversion to NSAttributedString, and the fallback below would repaint it in the body text color
                    attrStr[range].uiKit.foregroundColor = inlineFg
                    attrStr[range].uiKit.backgroundColor = inlineBg
                }
                if intent.contains(.stronglyEmphasized) && !intent.contains(.code) {
                    let size = fontSize(for: attrStr, range: range, typography: typography)
                    attrStr[range].font = OriveoTheme.Typography.chatBodyUIFont(size: size, weight: .bold)
                    attrStr[range].foregroundColor = Color(uiColor: textColor)
                }
                if intent.contains(.emphasized) && !intent.contains(.stronglyEmphasized) && !intent.contains(.code) {
                    let size = fontSize(for: attrStr, range: range, typography: typography)
                    attrStr[range].font = OriveoTheme.Typography.chatItalicUIFont(size: size)
                    attrStr[range].foregroundColor = Color(uiColor: textColor)
                }
            }

            for (link, range) in attrStr.runs[\.link] {
                guard let link else { continue }
                if ExternalURLPolicy.allows(link) {
                    attrStr[range].foregroundColor = Color(uiColor: linkColor)
                    attrStr[range].underlineStyle = .init(rawValue: 0)
                } else {
                    attrStr[range].link = nil
                }
            }

            do {
                var insertionPoints: [(AttributedString.Index, String)] = []
                var isFirstBlock = true
                var prevIsTableCell = false

                for (intent, range) in attrStr.runs[\.presentationIntent] {
                    guard let intent else { continue }

                    let isTableCell = intent.components.contains {
                        if case .tableCell = $0.kind { return true }
                        return false
                    }
                    let columnIndex: Int = intent.components.compactMap { c in
                        if case .tableCell(let col) = c.kind { return col }
                        return nil
                    }.first ?? 0

                    if isFirstBlock {
                        isFirstBlock = false
                    } else if isTableCell && prevIsTableCell && columnIndex > 0 {
                        insertionPoints.append((range.lowerBound, "\t"))
                    } else {
                        insertionPoints.append((range.lowerBound, "\n"))
                    }

                    prevIsTableCell = isTableCell
                }
                for (index, separator) in insertionPoints.reversed() {
                    attrStr.characters.insert(contentsOf: separator, at: index)
                }
            }

            let nsResult = NSMutableAttributedString(attrStr)
            let fullRange = NSRange(location: 0, length: nsResult.length)

            nsResult.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { value, range, _ in
                if let color = value as? UIColor {
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
                        .getRed(&r, green: &g, blue: &b, alpha: &a)
                    let isDark = (r + g + b) / 3 < 0.15
                    if isDark {
                        nsResult.addAttribute(.foregroundColor, value: textColor, range: range)
                    }
                } else {
                    nsResult.addAttribute(.foregroundColor, value: textColor, range: range)
                }
            }

            let basePara = OriveoTheme.Typography.chatParagraphStyle(
                lineHeightMultiple: typography.lineHeightMultiple,
                paragraphSpacing: typography.paragraphSpacing,
                fontSize: typography.baseFontSize,
                displayScale: OriveoTheme.Typography.currentDisplayScale
            ).mutableCopy() as! NSMutableParagraphStyle
            nsResult.addAttribute(.paragraphStyle, value: basePara, range: fullRange)

            nsResult.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
                guard let font = value as? UIFont, font.pointSize > typography.baseFontSize else { return }
                let headingPara = NSMutableParagraphStyle()
                headingPara.paragraphSpacingBefore = font.pointSize >= typography.heading1Size ? 16 : 12
                headingPara.paragraphSpacing = 4
                nsResult.addAttribute(.paragraphStyle, value: headingPara, range: range)
            }

            var unresolvedMath = false
            if !mathSegments.isEmpty {
                let mathColor = textColor.resolvedColor(
                    with: UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
                )
                unresolvedMath = StaticMarkdownMathSupport.applyAttachments(
                    to: nsResult,
                    segments: mathSegments,
                    baseFontSize: typography.baseFontSize,
                    textColor: mathColor
                )
            }

            return (nsResult, unresolvedMath)
        } catch {
            return (NSAttributedString(
                string: StaticMarkdownMathSupport.restoreTokens(text, segments: mathSegments),
                attributes: OriveoTheme.Typography.chatBodyAttributes(color: textColor, size: typography.baseFontSize)
            ), false)
        }
    }

    private static func plainTextFallback(_ text: String, typography: MarkdownTypography = .chat) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: OriveoTheme.Typography.chatBodyAttributes(
                color: UIColor(OriveoTheme.Palette.textPrimary),
                size: typography.baseFontSize
            )
        )
    }

    private static func apply(_ attributedText: NSAttributedString, to textView: UITextView) {
        if textView.attributedText != attributedText {
            textView.attributedText = attributedText
            textView.invalidateIntrinsicContentSize()
        }
    }

    private static func fontSize(for attrStr: AttributedString, range: Range<AttributedString.Index>, typography: MarkdownTypography = .chat) -> CGFloat {
        guard let intent = attrStr[range].presentationIntent else { return typography.baseFontSize }

        for component in intent.components.reversed() {
            switch component.kind {
            case .header(let level):
                switch level {
                case 1: return typography.heading1Size
                case 2: return typography.heading2Size
                default: return typography.heading3Size
                }
            default:
                continue
            }
        }

        return typography.baseFontSize
    }

    final class Coordinator {
        var lastText = ""
        var lastIsDark = false
        var renderGeneration: UInt = 0
        var hasUnresolvedLatex = false
        var rerender: (() -> Void)?
        private var latexObserver: NSObjectProtocol?

        func startObservingLatexRenders() {
            guard latexObserver == nil else { return }
            latexObserver = NotificationCenter.default.addObserver(
                forName: LatexImageCache.didRenderNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.hasUnresolvedLatex else { return }
                self.rerender?()
            }
        }

        nonisolated deinit {
            if let latexObserver {
                NotificationCenter.default.removeObserver(latexObserver)
            }
        }
    }
}


private struct CommittedMarkdownView: View, Equatable {
    let text: String
    let foregroundColor: Color
    let theme: MarkdownUI.Theme
    let typography: MarkdownTypography

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.typography == rhs.typography
    }

    var body: some View {
        StaticMarkdownContent(
            text: text,
            foregroundColor: foregroundColor,
            theme: theme,
            renderHint: nil,
            typography: typography
        )
    }
}

private struct StreamingMarkdownView: View {
    let text: String
    let isStreaming: Bool
    let showsCursor: Bool
    let foregroundColor: Color
    let reduceMotion: Bool
    let typography: MarkdownTypography


    private func computeSplit() -> (committed: String, tail: String) {
        MarkdownStreamingTextSplitter.split(text, keepsCurrentTail: isStreaming)
    }

    var body: some View {
        let split = computeSplit()

        VStack(alignment: .leading, spacing: 0) {
            if !split.committed.isEmpty {
                CommittedMarkdownView(
                    text: split.committed,
                    foregroundColor: foregroundColor,
                    theme: MarkdownMessageView.theme(for: typography),
                    typography: typography
                )
                .equatable()
            }

            StreamingTailContent(
                text: split.tail,
                foregroundColor: foregroundColor,
                reduceMotion: reduceMotion,
                showCursor: isStreaming && showsCursor,
                typography: typography
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


private struct StreamingTailContent: View {
    let text: String
    let foregroundColor: Color
    let reduceMotion: Bool
    var showCursor: Bool = true
    let typography: MarkdownTypography

    var body: some View {
        if text.isEmpty {
            if showCursor {
                StreamingCursorInline(reduceMotion: reduceMotion)
            }
        } else if !text.contains("```") {
            StreamingTextSegmentView(
                text: text,
                foregroundColor: foregroundColor
            )
        } else {
            let segments = Self.parseTailSegments(text)
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case let .text(t):
                        StreamingTextSegmentView(
                            text: t,
                            foregroundColor: foregroundColor
                        )
                    case let .completeCode(language, content):
                        CodeBlockCard(language: language, content: content)
                    case let .streamingCode(language, content):
                        StreamingCodeBlockCard(
                            language: language,
                            content: content,
                            reduceMotion: reduceMotion
                        )
                    }
                }
            }
        }
    }

    private enum TailSegment {
        case text(String)
        case completeCode(language: String?, content: String)
        case streamingCode(language: String?, content: String)
    }

    private static func parseTailSegments(_ text: String) -> [TailSegment] {
        guard text.contains("```") else { return [.text(text)] }

        var segments: [TailSegment] = []
        var cursor = text[...]

        while let fenceStart = cursor.range(of: "```") {
            let before = String(cursor[..<fenceStart.lowerBound])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.text(before))
            }

            let afterFence = cursor[fenceStart.upperBound...]

            guard let langBreak = afterFence.firstIndex(of: "\n") else {
                let partial = String(afterFence).trimmingCharacters(in: .whitespaces)
                segments.append(.streamingCode(
                    language: partial.isEmpty ? nil : partial,
                    content: ""
                ))
                return segments
            }

            let language = String(afterFence[..<langBreak]).trimmingCharacters(in: .whitespaces)
            let codeStart = afterFence.index(after: langBreak)
            let codeSlice = afterFence[codeStart...]

            if let fenceEnd = codeSlice.range(of: "```") {
                let code = String(codeSlice[..<fenceEnd.lowerBound]).trimmingCharacters(in: .newlines)
                segments.append(.completeCode(
                    language: language.isEmpty ? nil : language,
                    content: code
                ))
                cursor = codeSlice[fenceEnd.upperBound...]
            } else {
                let code = String(codeSlice)
                let trimmed = code.hasSuffix("\n")
                    ? String(code.dropLast())
                    : code
                segments.append(.streamingCode(
                    language: language.isEmpty ? nil : language,
                    content: trimmed
                ))
                return segments
            }
        }

        let trailing = String(cursor)
        if !trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(.text(trailing))
        }

        return segments.isEmpty ? [.text(text)] : segments
    }
}

private struct StreamingTextSegmentView: View {
    let text: String
    let foregroundColor: Color

    var body: some View {
        StreamingMarkdownTailTextView(text: text, foregroundColor: foregroundColor)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StreamingMarkdownTailTextView: UIViewRepresentable {
    let text: String
    let foregroundColor: Color

    @MainActor
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ChatPassiveTextView {
        let tv = ChatPassiveTextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.textColor = UIColor(foregroundColor)
        tv.linkTextAttributes = [
            .foregroundColor: UIColor(OriveoTheme.Palette.primary)
        ]
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.required, for: .vertical)
        tv.useStableWidthForIntrinsic = false
        tv.usesLengthOnlyIntrinsicHeightCache = false
        context.coordinator.writer.textViewProvider = { [weak tv] in tv }
        return tv
    }

    func updateUIView(_ tv: ChatPassiveTextView, context: Context) {
        if tv.textColor != UIColor(foregroundColor) {
            tv.textColor = UIColor(foregroundColor)
        }
        guard context.coordinator.lastText != text else { return }
        context.coordinator.lastText = text
        context.coordinator.writer.applyTail(text)
        tv.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ChatPassiveTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let fitting = uiView.measuredContentSize(fittingWidth: width)
        return CGSize(width: width, height: ceil(fitting.height))
    }

    @MainActor
    final class Coordinator {
        let writer = BlockCommitTextWriter()
        var lastText = ""
    }
}

struct StreamingCursorInline: View {
    let reduceMotion: Bool

    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(OriveoTheme.Palette.primary)
            .frame(width: 2.5, height: 20)
            .shadow(color: OriveoTheme.Palette.primary.opacity(0.5), radius: 4, y: 0)
            .opacity(visible ? 1 : 0)
            .animation(
                reduceMotion ? .none : .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                value: visible
            )
            .onAppear { visible = reduceMotion }
    }
}
