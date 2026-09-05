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

    static let background = Color.dynamic(light: 0x0B1220, dark: 0x050814)
    static let surface = Color.dynamic(light: 0x111A2E, dark: 0x0B1020)
    static let border = Color.dynamic(light: 0x8C5FF8, dark: 0xC4B5FD, lightAlpha: 0.22, darkAlpha: 0.20)
    static let foreground = Color.dynamic(light: 0xE7EEF8, dark: 0xEAF1FB)
    static let secondary = Color.dynamic(light: 0xC7D2E0, dark: 0xC7D2E0)
    static let markdownLink = Color.dynamic(light: 0xA5B4FC, dark: 0xC4B5FD)
    static let markdownInlineBackground = Color.dynamic(light: 0x1B2740, dark: 0x111A2E)
    static let markdownTableBorder = Color.dynamic(light: 0x334155, dark: 0x475569)

    static let keyword = Color.dynamic(light: 0xD8B4FE, dark: 0xD8B4FE)
    static let string = Color.dynamic(light: 0xA7F3D0, dark: 0xA7F3D0)
    static let comment = Color.dynamic(light: 0x94A3B8, dark: 0x94A3B8)
    static let number = Color.dynamic(light: 0xFDE68A, dark: 0xFDE68A)
    static let type = Color.dynamic(light: 0x7DD3FC, dark: 0x7DD3FC)
    static let variable = Color.dynamic(light: 0x5EEAD4, dark: 0x5EEAD4)

    static let backgroundUIColor = dynamicUIColor(light: 0x0B1220, dark: 0x050814)
    static let surfaceUIColor = dynamicUIColor(light: 0x111A2E, dark: 0x0B1020)
    static let borderUIColor = dynamicUIColor(light: 0x8C5FF8, dark: 0xC4B5FD, lightAlpha: 0.22, darkAlpha: 0.20)
    static let foregroundUIColor = dynamicUIColor(light: 0xE7EEF8, dark: 0xEAF1FB)
    static let secondaryUIColor = dynamicUIColor(light: 0xC7D2E0, dark: 0xC7D2E0)
    static let keywordUIColor = dynamicUIColor(light: 0xD8B4FE, dark: 0xD8B4FE)
    static let stringUIColor = dynamicUIColor(light: 0xA7F3D0, dark: 0xA7F3D0)
    static let commentUIColor = dynamicUIColor(light: 0x94A3B8, dark: 0x94A3B8)
    static let numberUIColor = dynamicUIColor(light: 0xFDE68A, dark: 0xFDE68A)
    static let typeUIColor = dynamicUIColor(light: 0x7DD3FC, dark: 0x7DD3FC)
    static let variableUIColor = dynamicUIColor(light: 0x5EEAD4, dark: 0x5EEAD4)
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
                        .foregroundStyle(codeForeground)
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
                    .foregroundStyle(codeForeground)
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
                        .foregroundStyle(codeForeground)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, OriveoTheme.Spacing.md)
            .padding(.vertical, 12)
            .background(codeSurface)

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
        let number: NSRegularExpression
        let type: NSRegularExpression
        let word: NSRegularExpression
        let cStyleComment: NSRegularExpression
        let hashComment: NSRegularExpression
        let htmlComment: NSRegularExpression

        let keywordColor = MarkdownCodeBlockPalette.keywordUIColor
        let stringColor = MarkdownCodeBlockPalette.stringUIColor
        let commentColor = MarkdownCodeBlockPalette.commentUIColor
        let numberColor = MarkdownCodeBlockPalette.numberUIColor
        let typeColor = MarkdownCodeBlockPalette.typeUIColor
        let variableColor = MarkdownCodeBlockPalette.variableUIColor

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
            number = try! NSRegularExpression(pattern: #"\b(?:0x[\da-fA-F]+|\d+\.?\d*(?:[eE][+-]?\d+)?)\b"#)
            type = try! NSRegularExpression(pattern: #"\b[A-Z][a-zA-Z0-9_]*\b"#)
            word = try! NSRegularExpression(pattern: #"\b[a-zA-Z_]\w*\b"#)
            cStyleComment = try! NSRegularExpression(pattern: #"//[^\n]*|/\*[\s\S]*?\*/"#, options: .dotMatchesLineSeparators)
            hashComment = try! NSRegularExpression(pattern: #"(?m)(?:^|(?<=\s))#[^\n]*$"#)
            htmlComment = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#, options: .dotMatchesLineSeparators)
        }
    }

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
        case .hash: return nil
        case .html: return ("<!--", "-->")
        case .cStyle: return ("/*", "*/")
        }
    }

    private enum CommentStyle { case hash, html, cStyle }

    private static func commentStyle(for language: String?) -> CommentStyle {
        switch language?.lowercased() ?? "" {
        case "python", "py", "ruby", "rb", "yaml", "yml", "bash", "sh", "shell", "zsh",
             "toml", "dockerfile", "makefile", "r", "perl", "pl":
            return .hash
        case "html", "xml", "svg":
            return .html
        default:
            return .cStyle
        }
    }

    private static func compute(
        _ code: String,
        language: String?,
        baseAttrs: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let p = Patterns.shared
        let attributed = NSMutableAttributedString(string: code, attributes: baseAttrs)
        let fullRange = NSRange(location: 0, length: attributed.length)
        var protectedRanges: [NSRange] = []

        for match in p.string.matches(in: code, range: fullRange) {
            attributed.addAttribute(.foregroundColor, value: p.stringColor, range: match.range)
            protectedRanges.append(match.range)
        }

        let commentRegexes: [NSRegularExpression]
        switch commentStyle(for: language) {
        case .hash: commentRegexes = [p.hashComment]
        case .html: commentRegexes = [p.htmlComment]
        case .cStyle: commentRegexes = [p.cStyleComment]
        }
        for regex in commentRegexes {
            for match in regex.matches(in: code, range: fullRange)
            where !isProtected(match.range, by: protectedRanges) {
                attributed.addAttribute(.foregroundColor, value: p.commentColor, range: match.range)
                protectedRanges.append(match.range)
            }
        }

        for match in p.variable.matches(in: code, range: fullRange)
        where !isProtected(match.range, by: protectedRanges) {
            attributed.addAttribute(.foregroundColor, value: p.variableColor, range: match.range)
            protectedRanges.append(match.range)
        }

        for match in p.number.matches(in: code, range: fullRange)
        where !isProtected(match.range, by: protectedRanges) {
            attributed.addAttribute(.foregroundColor, value: p.numberColor, range: match.range)
        }

        for match in p.word.matches(in: code, range: fullRange)
        where !isProtected(match.range, by: protectedRanges) {
            let word = (code as NSString).substring(with: match.range)
            if p.keywords.contains(word) {
                attributed.addAttribute(.foregroundColor, value: p.keywordColor, range: match.range)
                protectedRanges.append(match.range)
            } else if !isTypeLike(word) {
                attributed.addAttribute(.foregroundColor, value: p.variableColor, range: match.range)
            }
        }

        for match in p.type.matches(in: code, range: fullRange)
        where !isProtected(match.range, by: protectedRanges) {
            let word = (code as NSString).substring(with: match.range)
            if !p.keywords.contains(word) {
                attributed.addAttribute(.foregroundColor, value: p.typeColor, range: match.range)
            }
        }

        return attributed
    }

    private static func isProtected(_ range: NSRange, by protectedRanges: [NSRange]) -> Bool {
        protectedRanges.contains { NSLocationInRange(range.location, $0) }
    }

    private static func isTypeLike(_ word: String) -> Bool {
        guard let first = word.unicodeScalars.first else { return false }
        return CharacterSet.uppercaseLetters.contains(first)
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

    func makeUIView(context: Context) -> UITextView {
        let tv = ChatPassiveTextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.required, for: .vertical)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
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
        tv.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
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
                        .foregroundStyle(codeForeground)
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
            .background(codeSurface)

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
