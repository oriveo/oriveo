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

struct MarkdownTypography: Equatable {
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

    static let cachedTheme: MarkdownUI.Theme = makeTheme(.chat)
    static let notesTheme: MarkdownUI.Theme = makeTheme(.notes)

    static func theme(for typography: MarkdownTypography) -> MarkdownUI.Theme {
        typography == .notes ? notesTheme : cachedTheme
    }

    static func makeTheme(_ typography: MarkdownTypography) -> MarkdownUI.Theme {
        let textColor = OriveoTheme.Palette.textPrimary
        let inlineFg = Color.dynamic(light: 0x0F172A, dark: 0xE2E8F0)
        let inlineBg = Color.dynamic(light: 0xE2E8F0, dark: 0x1E293B)
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
                                    bottom: typography.emphasizedHeadings ? 8 : 4)
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
                    .markdownMargin(top: para + 10, bottom: 6)
                } else {
                    configuration.label
                        .markdownMargin(top: para, bottom: 4)
                        .markdownTextStyle {
                            FontWeight(.semibold)
                            FontSize(typography.heading2Size)
                            ForegroundColor(textColor)
                        }
                }
            }
            .heading3 { configuration in
                configuration.label
                    .markdownMargin(top: typography.emphasizedHeadings ? para : 4, bottom: 2)
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
                        .init(.allBorders, color: Color.dynamic(light: 0xD1D5DB, dark: 0x475569), strokeStyle: .init(lineWidth: 0.5))
                    )
                    .markdownTableBackgroundStyle(
                        .alternatingRows(
                            Color.dynamic(light: 0xFFFFFF, dark: 0x1E293B).opacity(0),
                            Color.dynamic(light: 0xF3F4F6, dark: 0x334155).opacity(0.5)
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
                    textColor: foregroundColor
                )
            case .blockMarkdown:
                if Self.containsTable(text) || Self.containsHorizontalRule(text) {
                    if StaticMarkdownMathSupport.containsMathDelimiters(text) {
                        MathAwareBlockBody(text: text, theme: theme, typography: typography)
                    } else {
                        Markdown(MarkdownRegexSupport.preprocessForMarkdownUI(text))
                            .markdownTheme(theme)
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

    private static func containsTable(_ text: String) -> Bool {
        MarkdownRegexSupport.containsMatch(MarkdownRegexSupport.tableSeparatorRegex, in: text)
    }

    private static func containsHorizontalRule(_ text: String) -> Bool {
        MarkdownRegexSupport.containsMatch(MarkdownRegexSupport.horizontalRuleRegex, in: text)
    }
}

private struct MathAwareBlockBody: View {
    let text: String
    let theme: MarkdownUI.Theme
    let typography: MarkdownTypography

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
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

    struct Group {
        let text: String
        let isTableLike: Bool
    }

    static func groups(for text: String) -> [Group] {
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

    private static func splitBlocks(_ text: String) -> [String] {
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
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
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

    private enum Segment: Equatable {
        case markdown(String)
        case code(language: String?, content: String)
    }

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

    private static func parseSegments(_ text: String) -> [Segment] {
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
        let inlineFg = UIColor(Color.dynamic(light: 0x0F172A, dark: 0xE2E8F0))
        let inlineBg = UIColor(Color.dynamic(light: 0xE2E8F0, dark: 0x1E293B))
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
                    attrStr[range].foregroundColor = Color(uiColor: inlineFg)
                    attrStr[range].backgroundColor = Color(uiColor: inlineBg)
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
                fontSize: typography.baseFontSize
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
