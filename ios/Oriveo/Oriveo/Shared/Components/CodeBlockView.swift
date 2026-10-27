import MarkdownUI
import SwiftUI

enum StreamingCodeTextUpdate: Equatable {
    case noChange
    case append(String)
    case replace(String)
}

struct StreamingCodePreview: Equatable {
    let text: String
    let lineCount: Int
    let isTruncated: Bool
}

func makeStreamingCodeTextUpdate(previous: String, next: String) -> StreamingCodeTextUpdate {
    guard previous != next else { return .noChange }
    guard !previous.isEmpty, next.hasPrefix(previous) else {
        return .replace(next)
    }
    return .append(String(next.dropFirst(previous.count)))
}

func makeStreamingCodePreview(
    from rawContent: String,
    lineLimit: Int = 18,
    characterLimit: Int = 1400
) -> StreamingCodePreview {
    let normalized = rawContent.replacingOccurrences(of: "\t", with: "    ")
    guard !normalized.isEmpty else {
        return StreamingCodePreview(text: " ", lineCount: 1, isTruncated: false)
    }

    let lines = normalized.components(separatedBy: .newlines)
    let lineCount = max(lines.count, 1)
    let exceedsLineLimit = lineCount > lineLimit
    let exceedsCharacterLimit = normalized.count > characterLimit
    let isTruncated = exceedsLineLimit || exceedsCharacterLimit

    guard isTruncated else {
        return StreamingCodePreview(text: normalized, lineCount: lineCount, isTruncated: false)
    }

    let lineLimited = exceedsLineLimit
        ? lines.suffix(lineLimit).joined(separator: "\n")
        : normalized
    let previewText = lineLimited.count > characterLimit
        ? String(lineLimited.suffix(characterLimit))
        : lineLimited

    return StreamingCodePreview(text: previewText, lineCount: lineCount, isTruncated: true)
}

/// Code block colors: the 12 syntax roles equal `shared/theme-contracts/code-highlight.v1.json` (Oriveo Code) value for value.
/// Syntax colors are one fixed set per appearance and do not follow the dark palette; only the code block backgrounds (codeBg / codeHeaderBg) follow the current dark palette.
enum MarkdownCodeBlockPalette {
    private static func dynamicUIColor(light: UInt, dark: UInt, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> UIColor {
        UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            let alpha = trait.userInterfaceStyle == .dark ? darkAlpha : lightAlpha
            return UIColor(
                red: CGFloat((hex & 0xFF0000) >> 16) / 255,
                green: CGFloat((hex & 0x00FF00) >> 8) / 255,
                blue: CGFloat(hex & 0x0000FF) / 255,
                alpha: alpha
            )
        }
    }

    // MARK: Code block background and border
    /// Code area background: #F4F4F5 in light mode, the current palette codeBg in dark mode.
    static let backgroundUIColor = UIColor.oriveoDynamic(light: 0xF4F4F5, dark: \.codeBg)
    /// Language capsule background: same as the header bar in light mode, the current palette codeBg in dark mode.
    static let surfaceUIColor = UIColor.oriveoDynamic(light: 0xE4E4E7, dark: \.codeBg)
    /// Header bar background: #E4E4E7 in light mode, the current palette codeHeaderBg in dark mode.
    static let headerBackgroundUIColor = UIColor.oriveoDynamic(light: 0xE4E4E7, dark: \.codeHeaderBg)
    static let borderUIColor = UIColor.oriveoBrand(light: \.ink, lightAlpha: 0.22, dark: \.primary, darkAlpha: 0.20)
    /// Body text = the contract `text` role.
    static let foregroundUIColor = dynamicUIColor(light: 0x18181B, dark: 0xE4E4E7)
    /// Language capsule / line count / header button text: the contract `headerText` in light mode, unchanged in dark mode.
    static let secondaryUIColor = dynamicUIColor(light: 0x52525B, dark: 0xC7D2E0)

    static let background = Color(uiColor: backgroundUIColor)
    static let surface = Color(uiColor: surfaceUIColor)
    static let headerBackground = Color(uiColor: headerBackgroundUIColor)
    static let border = Color(uiColor: borderUIColor)
    static let foreground = Color(uiColor: foregroundUIColor)
    static let secondary = Color(uiColor: secondaryUIColor)
    static let markdownLink = Color.brand(defaultLight: 0x7C3AED, light: \.textSafe, dark: \.accent)
    /// Inline code background in the code block Markdown preview: in dark mode it matches chat inline code (MarkdownAttributedStringRenderer.codeBg, white at 7%); black at 6% in light mode.
    static let markdownInlineBackground = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.07)
    /// Table border in the code block Markdown preview: dark mode uses the palette border (white at 10%); #D4D4D8 in light mode.
    static let markdownTableBorder = Color.dynamic(light: 0xD4D4D8, dark: 0xFFFFFF, darkAlpha: 0.10)

    // MARK: Syntax roles (`text` is the foreground)
    static let keywordUIColor = dynamicUIColor(light: 0x7C3AED, dark: 0xCBA6F7)
    static let stringUIColor = dynamicUIColor(light: 0x13773A, dark: 0xA6E3A1)
    static let numberUIColor = dynamicUIColor(light: 0xB5400C, dark: 0xFAB387)
    static let functionUIColor = dynamicUIColor(light: 0x1D4ED8, dark: 0x89B4FA)
    static let typeUIColor = dynamicUIColor(light: 0x8F5B00, dark: 0xF9E2AF)
    static let propertyUIColor = dynamicUIColor(light: 0x0E7490, dark: 0x89DCEB)
    static let commentUIColor = dynamicUIColor(light: 0x6B6B76, dark: 0x9399B2)
    static let punctuationUIColor = dynamicUIColor(light: 0x52525B, dark: 0xA6ADC8)
    static let diffAddUIColor = dynamicUIColor(light: 0x13773A, dark: 0xA6E3A1)
    static let diffDeleteUIColor = dynamicUIColor(light: 0xB91C1C, dark: 0xF38BA8)
    static let diffHunkUIColor = dynamicUIColor(light: 0x0E7490, dark: 0x89DCEB)
    /// Full-line background of diff added / removed lines: the contract diffAddLine / diffDeleteLine colors at an alpha, laid over the code area background.
    static let diffAddLineUIColor = dynamicUIColor(light: 0x10B981, dark: 0x6EE7A1, lightAlpha: 0.10, darkAlpha: 0.12)
    static let diffDeleteLineUIColor = dynamicUIColor(light: 0xEF4444, dark: 0xF8978F, lightAlpha: 0.10, darkAlpha: 0.12)

    static let keyword = Color(uiColor: keywordUIColor)
    static let string = Color(uiColor: stringUIColor)
    static let comment = Color(uiColor: commentUIColor)
    static let number = Color(uiColor: numberUIColor)
    static let type = Color(uiColor: typeUIColor)
}

struct CodeBlockCard: View {
    let language: String?
    let content: String

    @State private var copied = false
    @State private var showsExpanded = false

    private let codeBackground = MarkdownCodeBlockPalette.background
    private let codeSurface = MarkdownCodeBlockPalette.surface
    private let codeBorder = MarkdownCodeBlockPalette.border
    private let codeForeground = MarkdownCodeBlockPalette.foreground
    private let codeSecondary = MarkdownCodeBlockPalette.secondary
    private let lineHeight: CGFloat = 20
    private let previewLineLimit = 18

    private var isMarkdownLanguage: Bool {
        guard let lang = language?.lowercased() else { return false }
        return lang == "markdown" || lang == "md"
    }

    private var codeText: String {
        content.replacingOccurrences(of: "\t", with: "    ")
    }

    private var lineCount: Int {
        max(codeText.components(separatedBy: .newlines).count, 1)
    }

    private var isTruncated: Bool {
        lineCount > previewLineLimit || codeText.count > 1400
    }

    private var previewHeight: CGFloat {
        CGFloat(previewLineLimit) * lineHeight + 32
    }

    private var previewText: String {
        guard isTruncated else { return codeText }
        return codeText
            .components(separatedBy: .newlines)
            .prefix(previewLineLimit)
            .joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                HStack(spacing: 8) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(codeSecondary)

                    Text((language?.isEmpty == false ? language! : L10n.tr("Code")).uppercased())
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(codeSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(codeSurface)
                )

                Spacer()

                if isTruncated {
                    Text(String(format: L10n.tr("%lld lines"), Int64(lineCount)))
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(codeSecondary)
                }

                Button {
                    UIPasteboard.general.string = content
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                        Text(copied ? L10n.tr("Copied") : L10n.tr("Copy"))
                            .font(OriveoTheme.Typography.footnote)
                    }
                    .foregroundStyle(codeSecondary)
                    .contentShape(.hoverEffect, Capsule(style: .continuous))
                    .hoverEffect(.highlight)
                }
                .buttonStyle(.plain)

                if isTruncated {
                    Button {
                        showsExpanded = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11, weight: .semibold))
                            Text(L10n.tr("Expand"))
                                .font(OriveoTheme.Typography.footnote)
                        }
                        .foregroundStyle(codeSecondary)
                        .contentShape(.hoverEffect, Capsule(style: .continuous))
                        .hoverEffect(.highlight)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, OriveoTheme.Spacing.md)
            .padding(.vertical, 12)
            .background(MarkdownCodeBlockPalette.headerBackground)

            if isMarkdownLanguage {
                ScrollView(.vertical, showsIndicators: false) {
                    Markdown(Self.preprocessMarkdown(content))
                        .markdownTheme(Self.darkMarkdownTheme)
                        .padding(OriveoTheme.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: isTruncated ? previewHeight : nil)
                .background(codeBackground)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    CodeTextDisplay(
                        text: previewText,
                        textColor: codeForeground,
                        language: language,
                        renderMode: .highlighted
                    )
                    .padding(OriveoTheme.Spacing.md)
                }
                .frame(maxHeight: isTruncated ? previewHeight : nil)
                .background(codeBackground)
                .overlay(alignment: .bottom) {
                    if isTruncated {
                        LinearGradient(
                            colors: [
                                Color.clear,
                                codeBackground.opacity(0.92)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 44)
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: OriveoTheme.Palette.shadowStrong.opacity(0.18), radius: 14, y: 8)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(codeBorder, lineWidth: 1)
        )
        .sheet(isPresented: $showsExpanded) {
            CodeBlockViewerSheet(language: language, content: codeText)
        }
    }


    private static func preprocessMarkdown(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: #"<(b|strong)>(.*?)</\1>"#, with: "**$2**", options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"<(i|em)>(.*?)</\1>"#, with: "*$2*", options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"<(s|del)>(.*?)</\1>"#, with: "~~$2~~", options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"<code>(.*?)</code>"#, with: "`$1`", options: .regularExpression
        )
        return result
    }

    private static let darkMarkdownTheme: MarkdownUI.Theme = {
        let fg = MarkdownCodeBlockPalette.foreground
        let secondary = MarkdownCodeBlockPalette.secondary
        let inlineBg = MarkdownCodeBlockPalette.markdownInlineBackground

        return MarkdownUI.Theme()
            .text {
                ForegroundColor(fg)
                FontSize(14)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(13)
                ForegroundColor(fg)
                BackgroundColor(inlineBg)
            }
            .link {
                ForegroundColor(MarkdownCodeBlockPalette.markdownLink)
            }
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: 0, bottom: 6)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownMargin(top: 8, bottom: 4)
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(18)
                        ForegroundColor(fg)
                    }
            }
            .heading2 { configuration in
                configuration.label
                    .markdownMargin(top: 6, bottom: 3)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(16)
                        ForegroundColor(fg)
                    }
            }
            .heading3 { configuration in
                configuration.label
                    .markdownMargin(top: 4, bottom: 2)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(14)
                        ForegroundColor(fg)
                    }
            }
            .blockquote { configuration in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(secondary)
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle {
                            ForegroundColor(secondary)
                        }
                }
                .padding(.vertical, 4)
            }
            .table { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(
                        .init(.allBorders, color: MarkdownCodeBlockPalette.markdownTableBorder, strokeStyle: .init(lineWidth: 0.5))
                    )
                    .markdownTableBackgroundStyle(
                        .alternatingRows(Color.clear, OriveoTheme.Palette.codeInlineBg)
                    )
                    .markdownMargin(top: 4, bottom: 4)
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
    }()
}

struct CodeBlockViewerSheet: View {
    let language: String?
    let content: String

    @Environment(\.dismiss) private var dismiss

    private let codeBackground = MarkdownCodeBlockPalette.background
    private let codeForeground = MarkdownCodeBlockPalette.foreground
    private let codeSecondary = MarkdownCodeBlockPalette.secondary

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal], showsIndicators: true) {
                CodeTextDisplay(
                    text: content,
                    textColor: codeForeground,
                    language: language,
                    renderMode: .highlighted
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(OriveoTheme.Spacing.xl)
            }
            .background(codeBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text((language?.isEmpty == false ? language! : L10n.tr("Code")).uppercased())
                        .font(OriveoTheme.Typography.title3)
                        .foregroundStyle(codeSecondary)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.tr("Done")) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
}


nonisolated enum SyntaxHighlighter {
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 200
        return cache
    }()

    private final class Patterns: @unchecked Sendable {
        static let shared = Patterns()

        let string: NSRegularExpression
        let variable: NSRegularExpression
        let attribute: NSRegularExpression
        let number: NSRegularExpression
        let word: NSRegularExpression
        let punctuation: NSRegularExpression
        let jsonKeyColon: NSRegularExpression
        let cStyleComment: NSRegularExpression
        let hashComment: NSRegularExpression
        let htmlComment: NSRegularExpression

        let keywordColor = MarkdownCodeBlockPalette.keywordUIColor
        let stringColor = MarkdownCodeBlockPalette.stringUIColor
        let commentColor = MarkdownCodeBlockPalette.commentUIColor
        let numberColor = MarkdownCodeBlockPalette.numberUIColor
        let typeColor = MarkdownCodeBlockPalette.typeUIColor
        let functionColor = MarkdownCodeBlockPalette.functionUIColor
        let propertyColor = MarkdownCodeBlockPalette.propertyUIColor
        let punctuationColor = MarkdownCodeBlockPalette.punctuationUIColor
        let diffAddColor = MarkdownCodeBlockPalette.diffAddUIColor
        let diffDeleteColor = MarkdownCodeBlockPalette.diffDeleteUIColor
        let diffHunkColor = MarkdownCodeBlockPalette.diffHunkUIColor
        let diffAddLineColor = MarkdownCodeBlockPalette.diffAddLineUIColor
        let diffDeleteLineColor = MarkdownCodeBlockPalette.diffDeleteLineUIColor

        let keywords: Set<String> = [
            "if", "else", "elif", "for", "while", "do", "switch", "case", "break", "continue",
            "return", "try", "catch", "throw", "throws", "finally", "except", "raise",
            "func", "function", "def", "class", "struct", "enum", "protocol", "interface",
            "import", "from", "package", "module", "export", "default",
            "let", "var", "const", "static", "final", "override", "abstract", "virtual",
            "private", "public", "internal", "protected", "open", "fileprivate",
            "async", "await", "yield", "guard", "where", "in", "as", "is",
            "true", "false", "nil", "null", "None", "undefined", "self", "Self", "this", "super",
            "new", "delete", "typeof", "instanceof",
            "void", "int", "string", "bool", "float", "double", "char", "byte",
            "type", "typealias", "extension", "impl", "trait", "fn", "pub", "mod", "use", "crate",
            "with", "pass", "lambda", "nonlocal", "global", "assert",
            "extends", "implements", "readonly", "namespace", "declare",
        ]

        private init() {
            string = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"#)
            variable = try! NSRegularExpression(pattern: #"\$[A-Za-z_][A-Za-z0-9_]*"#)
            attribute = try! NSRegularExpression(pattern: #"@[A-Za-z_][A-Za-z0-9_]*"#)
            number = try! NSRegularExpression(pattern: #"\b(?:0x[\da-fA-F]+|\d+\.?\d*(?:[eE][+-]?\d+)?)\b"#)
            word = try! NSRegularExpression(pattern: #"\b[a-zA-Z_]\w*\b"#)
            punctuation = try! NSRegularExpression(pattern: #"[{}\[\]()<>,;:.=+\-*/%!&|^~?]"#)
            jsonKeyColon = try! NSRegularExpression(pattern: #"\G[ \t]*:"#)
            cStyleComment = try! NSRegularExpression(pattern: #"//[^\n]*|/\*[\s\S]*?\*/"#, options: .dotMatchesLineSeparators)
            hashComment = try! NSRegularExpression(pattern: #"(?m)(?:^|(?<=\s))#[^\n]*$"#)
            htmlComment = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#, options: .dotMatchesLineSeparators)
        }
    }

    /// Full-line background color of diff added / removed lines (the value is a UIColor). `CodeLineBackgroundDecorator` draws it behind the text across the text view's full width.
    static let lineBackgroundKey = NSAttributedString.Key("oriveo.codeLineBackground")

    static func highlight(_ code: String, language: String?, baseColor: UIColor) -> NSAttributedString {
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: baseColor
        ]
        guard !code.isEmpty else { return NSAttributedString(string: code, attributes: baseAttrs) }

        let key = NSString(string: "\(language ?? ""):\(code)")
        if let cached = cache.object(forKey: key) { return cached }
        let attributed = compute(code, language: language, baseAttrs: baseAttrs)
        cache.setObject(attributed, forKey: key)
        return attributed
    }

    static func cachedHighlight(_ code: String, language: String?) -> NSAttributedString? {
        guard !code.isEmpty else { return nil }
        return cache.object(forKey: NSString(string: "\(language ?? ""):\(code)"))
    }

    static func highlightUncached(_ code: String, language: String?, baseColor: UIColor) -> NSAttributedString {
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: baseColor
        ]
        guard !code.isEmpty else { return NSAttributedString(string: code, attributes: baseAttrs) }
        return compute(code, language: language, baseAttrs: baseAttrs)
    }

    static func blockCommentDelimiters(for language: String?) -> (open: String, close: String)? {
        switch commentStyle(for: language) {
        case .none, .hash: return nil
        case .html: return ("<!--", "-->")
        case .cStyle: return ("/*", "*/")
        }
    }

    private enum CommentStyle { case none, hash, html, cStyle }

    private static func commentStyle(for language: String?) -> CommentStyle {
        switch language?.lowercased() ?? "" {
        case "diff", "patch":
            return .none
        case "python", "py", "ruby", "rb", "yaml", "yml", "bash", "sh", "shell", "zsh",
             "toml", "dockerfile", "makefile", "r", "perl", "pl":
            return .hash
        case "html", "xml", "svg":
            return .html
        default:
            return .cStyle
        }
    }

    private static func isJSONLanguage(_ language: String?) -> Bool {
        switch language?.lowercased() ?? "" {
        case "json", "jsonc", "json5": return true
        default: return false
        }
    }

    private static func compute(
        _ code: String,
        language: String?,
        baseAttrs: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let p = Patterns.shared
        let attributed = NSMutableAttributedString(string: code, attributes: baseAttrs)
        let style = commentStyle(for: language)
        if style == .none {
            applyDiffLines(code, to: attributed, patterns: p)
            return attributed
        }

        let ns = code as NSString
        let fullRange = NSRange(location: 0, length: attributed.length)
        // Already-colored ranges: later rules only check whether a match starts inside one (same rule as before); IndexSet lookups are O(log n)
        var protected = IndexSet()
        func isFree(_ range: NSRange) -> Bool { !protected.contains(range.location) }
        func paint(_ range: NSRange, _ color: UIColor) {
            attributed.addAttribute(.foregroundColor, value: color, range: range)
            protected.insert(integersIn: range.location ..< NSMaxRange(range))
        }

        // 1. Strings; in the JSON family a string before a colon is an object key = property
        let isJSON = isJSONLanguage(language)
        for match in p.string.matches(in: code, range: fullRange) {
            let end = NSMaxRange(match.range)
            let isKey = isJSON && p.jsonKeyColon.firstMatch(
                in: code, options: .anchored, range: NSRange(location: end, length: ns.length - end)
            ) != nil
            paint(match.range, isKey ? p.propertyColor : p.stringColor)
        }

        // 2. Comments (style depends on the language; the language table lives only in commentStyle(for:))
        let commentRegex: NSRegularExpression
        switch style {
        case .hash: commentRegex = p.hashComment
        case .html: commentRegex = p.htmlComment
        case .cStyle, .none: commentRegex = p.cStyleComment
        }
        for match in commentRegex.matches(in: code, range: fullRange) where isFree(match.range) {
            paint(match.range, p.commentColor)
        }

        // 3. `$var` and `@attr` / decorators = property
        for regex in [p.variable, p.attribute] {
            for match in regex.matches(in: code, range: fullRange) where isFree(match.range) {
                paint(match.range, p.propertyColor)
            }
        }

        // 4. Numbers
        for match in p.number.matches(in: code, range: fullRange) where isFree(match.range) {
            paint(match.range, p.numberColor)
        }

        // 5. Identifiers: keyword > capitalized type > function followed by `(` > member after `.` > body color (left uncolored)
        for match in p.word.matches(in: code, range: fullRange) where isFree(match.range) {
            let word = ns.substring(with: match.range)
            let end = NSMaxRange(match.range)
            if p.keywords.contains(word) {
                paint(match.range, p.keywordColor)
            } else if isTypeLike(word) {
                paint(match.range, p.typeColor)
            } else if end < ns.length, ns.character(at: end) == 0x28 /* ( */ {
                paint(match.range, p.functionColor)
            } else if match.range.location > 0, ns.character(at: match.range.location - 1) == 0x2E /* . */ {
                paint(match.range, p.propertyColor)
            }
        }

        // 6. Brackets, separators, operators
        for match in p.punctuation.matches(in: code, range: fullRange) where isFree(match.range) {
            attributed.addAttribute(.foregroundColor, value: p.punctuationColor, range: match.range)
        }

        return attributed
    }

    /// diff / patch lines get their role from the line prefix: `+++` / `---` / `@@` → diffHunk, `+` → diffAdd, `-` → diffDelete, anything else the body color.
    /// Added / removed lines also carry `lineBackgroundKey` for the full-line background. Only the line's own prefix is looked at, so streaming line by line and the final full pass agree.
    private static func applyDiffLines(_ code: String, to attributed: NSMutableAttributedString, patterns p: Patterns) {
        let ns = code as NSString
        var lineStart = 0
        while lineStart <= ns.length {
            let searchRange = NSRange(location: lineStart, length: ns.length - lineStart)
            let newline = ns.range(of: "\n", range: searchRange)
            let lineEnd = newline.location == NSNotFound ? ns.length : newline.location
            let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)
            if lineRange.length > 0 {
                let line = ns.substring(with: lineRange)
                if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
                    attributed.addAttribute(.foregroundColor, value: p.diffHunkColor, range: lineRange)
                } else if line.hasPrefix("+") {
                    attributed.addAttribute(.foregroundColor, value: p.diffAddColor, range: lineRange)
                    attributed.addAttribute(lineBackgroundKey, value: p.diffAddLineColor, range: lineRange)
                } else if line.hasPrefix("-") {
                    attributed.addAttribute(.foregroundColor, value: p.diffDeleteColor, range: lineRange)
                    attributed.addAttribute(lineBackgroundKey, value: p.diffDeleteLineColor, range: lineRange)
                }
            }
            guard newline.location != NSNotFound else { break }
            lineStart = newline.location + newline.length
        }
    }

    private static func isTypeLike(_ word: String) -> Bool {
        guard let first = word.unicodeScalars.first else { return false }
        return CharacterSet.uppercaseLetters.contains(first)
    }
}


// MARK: - Full-line background of code lines (diff added / removed lines)

/// Draws the lines marked by `SyntaxHighlighter.lineBackgroundKey` as bands spanning the text view's full width, behind the text.
/// Shared by the static card, the streaming card and the SwiftUI code view: the host `ChatPassiveTextView.codeLineBackgrounds` holds it,
/// and in the text view's layoutSubviews it takes line rects from TextKit 2 layout fragments (falling back to the layoutManager on a TextKit 1 stack).
/// Nothing is recomputed when the content / width did not change (layoutSubviews is hot while scrolling, so only one comparison is done).
@MainActor
final class CodeLineBackgroundDecorator {
    private let canvas = UIView()
    private var stripes: [UIView] = []
    private var needsUpdate = true
    private var lastWidth: CGFloat = -1
    private var lastLength = -1

    init() {
        canvas.isUserInteractionEnabled = false
        canvas.backgroundColor = .clear
    }

    /// Call after the content or attributes change (streaming line-by-line coloring, a full rewrite).
    func invalidate(in textView: UITextView) {
        needsUpdate = true
        textView.setNeedsLayout()
    }

    func layout(in textView: UITextView) {
        if canvas.superview !== textView {
            textView.insertSubview(canvas, at: 0)
            needsUpdate = true
        } else if textView.subviews.first !== canvas {
            textView.sendSubviewToBack(canvas)
        }
        let width = max(textView.bounds.width, textView.contentSize.width)
        let length = textView.textStorage.length
        guard needsUpdate || abs(width - lastWidth) > 0.5 || length != lastLength else { return }
        needsUpdate = false
        lastWidth = width
        lastLength = length

        let bands = Self.lineBands(in: textView)
        let height = max(textView.contentSize.height, textView.bounds.height)
        canvas.frame = CGRect(x: 0, y: 0, width: width, height: height)
        canvas.isHidden = bands.isEmpty
        while stripes.count < bands.count {
            let stripe = UIView()
            stripe.isUserInteractionEnabled = false
            canvas.addSubview(stripe)
            stripes.append(stripe)
        }
        for (index, stripe) in stripes.enumerated() {
            guard index < bands.count else {
                stripe.isHidden = true
                continue
            }
            let band = bands[index]
            stripe.isHidden = false
            stripe.backgroundColor = band.color
            stripe.frame = CGRect(x: 0, y: band.minY, width: width, height: band.maxY - band.minY)
        }
    }

    #if DEBUG
    /// Test seam: the bands currently laid out (in text view coordinates).
    var _testStripeFrames: [CGRect] {
        stripes.filter { !$0.isHidden && !canvas.isHidden }.map { canvas.convert($0.frame, to: canvas.superview) }
    }
    #endif

    private static func lineBands(in textView: UITextView) -> [(minY: CGFloat, maxY: CGFloat, color: UIColor)] {
        let storage = textView.textStorage
        guard storage.length > 0 else { return [] }
        var bands: [(minY: CGFloat, maxY: CGFloat, color: UIColor)] = []
        let topInset = textView.textContainerInset.top
        storage.enumerateAttribute(
            SyntaxHighlighter.lineBackgroundKey,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let color = value as? UIColor, range.length > 0,
                  let extent = verticalExtent(of: range, in: textView) else { return }
            bands.append((extent.minY + topInset, extent.maxY + topInset, color))
        }
        return bands
    }

    /// The vertical extent of the paragraphs containing the character range (in text container coordinates).
    private static func verticalExtent(of range: NSRange, in textView: UITextView) -> (minY: CGFloat, maxY: CGFloat)? {
        if let layoutManager = textView.textLayoutManager {
            guard let content = layoutManager.textContentManager,
                  let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length) else { return nil }
            var minY = CGFloat.greatestFiniteMagnitude
            var maxY = -CGFloat.greatestFiniteMagnitude
            layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
                guard fragment.rangeInElement.location.compare(end) == .orderedAscending else { return false }
                let frame = fragment.layoutFragmentFrame
                minY = min(minY, frame.minY)
                maxY = max(maxY, frame.maxY)
                return true
            }
            return minY < maxY ? (minY, maxY) : nil
        }
        // TextKit 1 stack (only views that explicitly use makeTextKit1 get here; touching layoutManager on a TextKit 2 view downgrades it)
        let layoutManager = textView.layoutManager
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
        return rect.isEmpty ? nil : (rect.minY, rect.maxY)
    }
}


private struct CodeTextDisplay: UIViewRepresentable {
    enum RenderMode: Equatable {
        case highlighted
        case streamingPlain
    }

    let text: String
    let textColor: Color
    var language: String?
    var renderMode: RenderMode = .highlighted

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
        tv.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.codeLineBackgrounds = CodeLineBackgroundDecorator()
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.required, for: .vertical)
        return tv
    }

    func updateUIView(_ tv: ChatPassiveTextView, context: Context) {
        let resolvedTextColor = UIColor(textColor)
        tv.textColor = resolvedTextColor
        tv.isSelectable = renderMode == .highlighted

        switch renderMode {
        case .highlighted:
            guard context.coordinator.lastText != text ||
                    context.coordinator.lastLanguage != language ||
                    context.coordinator.lastRenderMode != .highlighted else { return }
            tv.attributedText = SyntaxHighlighter.highlight(text, language: language, baseColor: resolvedTextColor)
        case .streamingPlain:
            let baseAttributes = Self.baseAttributes(textColor: resolvedTextColor)
            switch makeStreamingCodeTextUpdate(previous: context.coordinator.lastText, next: text) {
            case .noChange:
                return
            case let .append(delta)
                where context.coordinator.lastRenderMode == .streamingPlain && !delta.isEmpty:
                tv.textStorage.beginEditing()
                tv.textStorage.append(NSAttributedString(string: delta, attributes: baseAttributes))
                tv.textStorage.endEditing()
            case .append:
                tv.attributedText = NSAttributedString(string: text, attributes: baseAttributes)
            case let .replace(fullText):
                tv.attributedText = NSAttributedString(string: fullText, attributes: baseAttributes)
            }
        }

        context.coordinator.lastText = text
        context.coordinator.lastLanguage = language
        context.coordinator.lastRenderMode = renderMode
        tv.codeLineBackgrounds?.invalidate(in: tv)
        tv.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ChatPassiveTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? CGFloat.greatestFiniteMagnitude
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    private static func baseAttributes(textColor: UIColor) -> [NSAttributedString.Key: Any] {
        [
            .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: textColor
        ]
    }

    final class Coordinator {
        var lastText = ""
        var lastLanguage: String?
        var lastRenderMode: RenderMode?
    }
}


struct StreamingCodeBlockCard: View {
    let language: String?
    let content: String
    let reduceMotion: Bool

    private let codeBackground = MarkdownCodeBlockPalette.background
    private let codeSurface = MarkdownCodeBlockPalette.surface
    private let codeBorder = MarkdownCodeBlockPalette.border
    private let codeForeground = MarkdownCodeBlockPalette.foreground
    private let codeSecondary = MarkdownCodeBlockPalette.secondary
    private let lineHeight: CGFloat = 20
    private let previewLineLimit = 18

    private var preview: StreamingCodePreview {
        makeStreamingCodePreview(from: content, lineLimit: previewLineLimit)
    }

    private var previewHeight: CGFloat {
        CGFloat(previewLineLimit) * lineHeight + 32
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                HStack(spacing: 8) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(codeSecondary)

                    Text((language?.isEmpty == false ? language! : L10n.tr("Code")).uppercased())
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(codeSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(codeSurface)
                )

                if preview.isTruncated {
                    Text(String(format: L10n.tr("%lld lines"), Int64(preview.lineCount)))
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(codeSecondary)
                }

                Spacer()
            }
            .padding(.horizontal, OriveoTheme.Spacing.md)
            .padding(.vertical, 12)
            .background(MarkdownCodeBlockPalette.headerBackground)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 0) {
                    CodeTextDisplay(
                        text: preview.text,
                        textColor: codeForeground,
                        language: language,
                        renderMode: .streamingPlain
                    )

                    StreamingCursorInline(reduceMotion: reduceMotion)
                        .padding(.leading, 2)
                }
                .padding(OriveoTheme.Spacing.md)
            }
            .frame(height: preview.isTruncated ? previewHeight : nil, alignment: .topLeading)
            .background(codeBackground)
            .overlay(alignment: .top) {
                if preview.isTruncated {
                    LinearGradient(
                        colors: [
                            codeBackground.opacity(0.92),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 28)
                    .allowsHitTesting(false)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: OriveoTheme.Palette.shadowStrong.opacity(0.18), radius: 14, y: 8)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(codeBorder, lineWidth: 1)
        )
    }
}
