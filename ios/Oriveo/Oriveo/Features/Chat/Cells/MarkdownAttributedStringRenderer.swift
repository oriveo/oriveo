import SwiftUI
import UIKit

nonisolated enum MarkdownAttributedStringRenderer {
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 500
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    private static func cacheCost(for attr: NSAttributedString) -> Int {
        attr.length * 32
    }

    private static func cacheKey(for text: String) -> NSString {
        let style: String
        if Thread.isMainThread {
            switch UITraitCollection.current.userInterfaceStyle {
            case .dark: style = "d"
            case .light, .unspecified: style = "l"
            @unknown default: style = "l"
            }
        } else {
            style = "u"
        }
        return NSString(string: "\(style)|\(text)")
    }

    static func cachedRender(for text: String) -> NSAttributedString? {
        cache.object(forKey: cacheKey(for: text))
    }

    static func render(_ text: String) -> NSAttributedString {
        let key = cacheKey(for: text)
        if let cached = cache.object(forKey: key) { return cached }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let (rendered, unresolved) = renderLinesTrackingUnresolvedLatex(trimmed)
        if !unresolved {
            cache.setObject(rendered, forKey: key, cost: cacheCost(for: rendered))
        }
        return rendered
    }

    private static let unresolvedLatexFlag = "MarkdownAttributedStringRenderer.unresolvedLatex"

    static func markUnresolvedLatexForCurrentRender() {
        Thread.current.threadDictionary[unresolvedLatexFlag] = true
    }

    private static func renderLinesTrackingUnresolvedLatex(_ text: String) -> (NSAttributedString, Bool) {
        let dict = Thread.current.threadDictionary
        let saved = dict[unresolvedLatexFlag]
        dict[unresolvedLatexFlag] = false
        let rendered = renderLines(text)
        let unresolved = dict[unresolvedLatexFlag] as? Bool == true
        if let saved {
            dict[unresolvedLatexFlag] = saved
        } else {
            dict.removeObject(forKey: unresolvedLatexFlag)
        }
        return (rendered, unresolved)
    }

    @discardableResult
    static func prewarm(_ text: String, isDark: Bool) -> Bool {
        let key = NSString(string: "\(isDark ? "d" : "l")|\(text)")
        guard cache.object(forKey: key) == nil else { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var rendered: NSAttributedString?
        var unresolvedLatex = false
        UITraitCollection(userInterfaceStyle: isDark ? .dark : .light).performAsCurrent {
            let (result, unresolved) = renderLinesTrackingUnresolvedLatex(trimmed)
            rendered = result
            unresolvedLatex = unresolved
        }
        if let rendered, !unresolvedLatex {
            cache.setObject(rendered, forKey: key, cost: cacheCost(for: rendered))
            return true
        }
        return false
    }

    static func renderPreservingBoundaries(_ text: String) -> NSAttributedString {
        renderLines(text)
    }

    static func invalidateCache(for text: String) {
        for style in ["d", "l", "u"] {
            cache.removeObject(forKey: NSString(string: "\(style)|\(text)"))
        }
    }

    static func renderAsync(_ text: String, completion: @escaping (NSAttributedString) -> Void) {
        if let cached = cachedRender(for: text) {
            completion(cached)
            return
        }
        let currentText = text
        DispatchQueue.global(qos: .userInitiated).async {
            let rendered = render(currentText)
            DispatchQueue.main.async {
                completion(rendered)
            }
        }
    }

    static func plainTextFallback(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: OriveoTheme.Typography.chatBodyUIFont(),
                .foregroundColor: UIColor(OriveoTheme.Palette.textPrimary),
                .paragraphStyle: baseParagraphStyle,
            ]
        )
    }


    private static func preprocess(_ text: String) -> String {
        var result = preprocessInline(text)
        if result.contains("-") || result.contains("*") {
            result = replacingMatches(in: result, regex: unorderedListRegex, with: "$1• ")
        }
        return result
    }

    private static func preprocessInline(_ text: String) -> String {
        var result = LatexNormalizer.normalize(text)
        if result.contains("<") {
            result = replacingMatches(in: result, regex: htmlBoldRegex, with: "**$2**")
            result = replacingMatches(in: result, regex: htmlItalicRegex, with: "*$2*")
            result = replacingMatches(in: result, regex: htmlStrikeRegex, with: "~~$2~~")
            result = replacingMatches(in: result, regex: htmlCodeRegex, with: "`$1`")
        }
        return result
    }


    private static let textColor = UIColor(OriveoTheme.Palette.textPrimary)
    private static let secondaryColor = UIColor(OriveoTheme.Palette.textSecondary)
    private static let linkColor = UIColor(OriveoTheme.Palette.primary)
    private static let codeFg = UIColor(Color.dynamic(light: 0x0F172A, dark: 0xE2E8F0))
    private static let codeBg = UIColor(Color.dynamic(light: 0xE2E8F0, dark: 0x1E293B))

    private static let tableBorderColor = UIColor(Color.dynamic(light: 0xCBD5E1, dark: 0x475569))
    private static let tableHeaderBg = UIColor(Color.dynamic(light: 0xF1F5F9, dark: 0x1E293B))

    private static let baseParagraphStyle: NSParagraphStyle = {
        OriveoTheme.Typography.chatParagraphStyle()
    }()

    private static let plainAttrs: [NSAttributedString.Key: Any] = [
        .font: OriveoTheme.Typography.chatBodyUIFont(),
        .foregroundColor: UIColor(OriveoTheme.Palette.textPrimary),
        .paragraphStyle: baseParagraphStyle,
    ]

    private static let headingRegex = try! NSRegularExpression(pattern: #"^(#{1,6})\s+(.+)$"#)
    private static let codeRegex = try! NSRegularExpression(pattern: "`([^`]+)`")
    private static let boldRegex = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
    private static let italicRegex = try! NSRegularExpression(pattern: "(?<!\\*)\\*([^*]+?)\\*(?!\\*)")
    private static let strikeRegex = try! NSRegularExpression(pattern: "~~(.+?)~~")
    private static let linkRegex = try! NSRegularExpression(pattern: "\\[(.+?)\\]\\((.+?)\\)")
    private static let htmlBoldRegex = try! NSRegularExpression(pattern: #"<(b|strong)>(.*?)</\1>"#)
    private static let htmlItalicRegex = try! NSRegularExpression(pattern: #"<(i|em)>(.*?)</\1>"#)
    private static let htmlStrikeRegex = try! NSRegularExpression(pattern: #"<(s|del)>(.*?)</\1>"#)
    private static let htmlCodeRegex = try! NSRegularExpression(pattern: #"<code>(.*?)</code>"#)
    private static let unorderedListRegex = try! NSRegularExpression(pattern: #"(?m)^([ \t]*)[-*] "#)
    private static let inlineMathRegex = try! NSRegularExpression(
        pattern: #"(?<!\$)\$([^\$\n]+?)\$(?!\$)"#
    )

    private static let tableSeparatorRegex = try! NSRegularExpression(
        pattern: #"^\|[ \t]*:?-{1,}:?[ \t]*(\|[ \t]*:?-{1,}:?[ \t]*)*\|?[ \t]*$"#
    )

    private static func renderLines(_ text: String) -> NSAttributedString {
        let text = preprocess(text)
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")

        let tableRegions = detectTableRegions(lines)
        let tableRegionsByStart = Dictionary(uniqueKeysWithValues: tableRegions.map { ($0.start, $0) })

        let mathRegions = detectBlockMathRegions(lines)
        let mathRegionsByStart = Dictionary(uniqueKeysWithValues: mathRegions.map { ($0.start, $0) })

        var skipUntil = -1

        for (i, line) in lines.enumerated() {
            if i < skipUntil { continue }

            if let region = mathRegionsByStart[i] {
                if result.length > 0 {
                    result.append(NSAttributedString(string: "\n", attributes: plainAttrs))
                }
                if region.isComplete {
                    result.append(renderBlockMath(region.latex))
                } else {
                    result.append(renderBlockMathPlaceholder(estimatedLatex: region.latex))
                }
                skipUntil = region.end
                continue
            }

            if let region = tableRegionsByStart[i] {
                if result.length > 0 {
                    result.append(NSAttributedString(string: "\n", attributes: plainAttrs))
                }
                let tableLines = Array(lines[region.start..<region.end])
                result.append(renderTable(tableLines, alignments: region.alignments))
                skipUntil = region.end
                continue
            }

            if i > 0 {
                result.append(NSAttributedString(string: "\n", attributes: plainAttrs))
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            result.append(renderProcessedLine(line))
        }

        return result
    }


    enum CanonicalLineKind: Equatable {
        case heading(level: Int)
        case quote
        case plain
    }

    static func canonicalLineKind(_ linePrefix: String) -> CanonicalLineKind {
        let ns = linePrefix as NSString
        var i = 0
        while i < ns.length, i < 6, ns.character(at: i) == 0x23 { i += 1 }  // '#'
        if i >= 1, i < ns.length {
            let c = ns.character(at: i)
            if c == 0x20 || c == 0x09 { return .heading(level: i) }
        }
        if linePrefix.hasPrefix("> ") { return .quote }
        return .plain
    }

    static func renderCanonicalLine(_ line: String) -> NSAttributedString {
        let processed = preprocess(line)
        if processed.trimmingCharacters(in: .whitespaces).isEmpty { return NSAttributedString() }
        return renderProcessedLine(processed)
    }

    static func renderCommittedSpan(
        kind: CanonicalLineKind,
        span: String,
        isLineStart: Bool
    ) -> NSAttributedString {
        guard !span.isEmpty else { return NSAttributedString() }
        switch kind {
        case .heading(let level):
            let content = isLineStart ? strippingHeadingMarker(span) : span
            return renderHeadingContent(content, level: level)
        case .quote:
            let content = (isLineStart && span.hasPrefix("> ")) ? String(span.dropFirst(2)) : span
            return renderQuoteContent(content)
        case .plain:
            let processed = isLineStart ? preprocess(span) : preprocessInline(span)
            return renderPlainContent(processed)
        }
    }

    static func canonicalLineSeparator() -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: plainAttrs)
    }

    private static func strippingHeadingMarker(_ span: String) -> String {
        let ns = span as NSString
        var i = 0
        while i < ns.length, i < 6, ns.character(at: i) == 0x23 { i += 1 }
        while i < ns.length, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i += 1 }
        return ns.substring(from: i)
    }

    private static func renderProcessedLine(_ line: String) -> NSAttributedString {
        if isHorizontalRule(line) {
            return renderHorizontalRule()
        }

        let nsLine = line as NSString
        let lineRange = NSRange(location: 0, length: nsLine.length)
        if let match = headingRegex.firstMatch(in: line, range: lineRange),
           match.range(at: 2).location != NSNotFound {
            let level = nsLine.substring(with: match.range(at: 1)).count
            let content = nsLine.substring(with: match.range(at: 2))
            return renderHeadingContent(content, level: level)
        }

        if line.hasPrefix("> ") {
            return renderQuoteContent(String(line.dropFirst(2)))
        }

        return renderPlainContent(line)
    }

    private static func renderHeadingContent(_ content: String, level: Int) -> NSAttributedString {
        guard !content.isEmpty else { return NSAttributedString() }
        let fontSize: CGFloat = level == 1 ? 23 : level == 2 ? 19 : 17
        let weight: UIFont.Weight = level <= 2 ? .bold : .semibold
        let headingAttrs: [NSAttributedString.Key: Any] = [
            .font: OriveoTheme.Typography.chatBodyUIFont(size: fontSize, weight: weight),
            .foregroundColor: textColor,
            .paragraphStyle: baseParagraphStyle,
        ]
        let lineStr = NSMutableAttributedString(string: content, attributes: headingAttrs)
        applyInlineStyles(lineStr)
        let baseStyle = OriveoTheme.Typography.chatParagraphStyle(
            lineHeightMultiple: 1.08,
            paragraphSpacing: 4,
            fontSize: fontSize
        )
        let para = (baseStyle.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        para.paragraphSpacingBefore = level == 1 ? 16 : level == 2 ? 12 : 8
        if let direction = ParagraphWritingDirection.firstStrongDirection(in: content) {
            para.baseWritingDirection = direction
        }
        lineStr.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: lineStr.length))
        return lineStr
    }

    private static func renderQuoteContent(_ content: String) -> NSAttributedString {
        guard !content.isEmpty else { return NSAttributedString() }
        let quoteAttrs: [NSAttributedString.Key: Any] = [
            .font: OriveoTheme.Typography.chatBodyUIFont(),
            .foregroundColor: secondaryColor,
            .paragraphStyle: baseParagraphStyle,
        ]
        let lineStr = NSMutableAttributedString(string: content, attributes: quoteAttrs)
        applyInlineStyles(lineStr)
        ParagraphWritingDirection.applyParagraphDirections(to: lineStr)
        return lineStr
    }

    private static func renderPlainContent(_ line: String) -> NSAttributedString {
        guard !line.isEmpty else { return NSAttributedString() }
        let lineStr = NSMutableAttributedString(string: line, attributes: plainAttrs)
        applyInlineStyles(lineStr)
        ParagraphWritingDirection.applyParagraphDirections(to: lineStr)
        return lineStr
    }


    private struct BlockMathRegion {
        let start: Int
        let end: Int
        let latex: String
        let isComplete: Bool
    }

    private static func detectBlockMathRegions(_ lines: [String]) -> [BlockMathRegion] {
        var regions: [BlockMathRegion] = []
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count >= 4,
               let dollarRange = trimmed.range(of: "$$"),
               let endRange = trimmed.range(of: "$$", options: .backwards),
               dollarRange.upperBound < endRange.lowerBound {
                let latex = String(trimmed[dollarRange.upperBound..<endRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                if !latex.isEmpty {
                    regions.append(BlockMathRegion(start: i, end: i + 1, latex: latex, isComplete: true))
                }
                i += 1
                continue
            }
            if trimmed.hasPrefix("$$") {
                let firstContent = String(trimmed.dropFirst(2))
                var bodyLines: [String] = []
                if !firstContent.isEmpty {
                    bodyLines.append(firstContent)
                }
                var j = i + 1
                var found = false
                while j < lines.count {
                    let line = lines[j]
                    let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                    if let closeRange = trimmedLine.range(of: "$$") {
                        let pre = String(trimmedLine[trimmedLine.startIndex..<closeRange.lowerBound])
                        if !pre.isEmpty {
                            bodyLines.append(pre)
                        }
                        found = true
                        j += 1
                        break
                    }
                    bodyLines.append(line)
                    j += 1
                }
                let latex = bodyLines
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if found {
                    if !latex.isEmpty {
                        regions.append(BlockMathRegion(start: i, end: j, latex: latex, isComplete: true))
                        i = j
                        continue
                    }
                } else {
                    regions.append(BlockMathRegion(
                        start: i,
                        end: lines.count,
                        latex: latex,
                        isComplete: false
                    ))
                    return regions
                }
            }
            i += 1
        }
        return regions
    }

    private static func renderBlockMath(_ latex: String) -> NSAttributedString {
        let font = OriveoTheme.Typography.chatBodyUIFont(size: 18)
        let image = LatexImageCache.requestImage(
            latex: latex,
            fontSize: 20,
            textColor: textColor,
            inline: false
        )
        guard let image else {
            markUnresolvedLatexForCurrentRender()
            return renderBlockMathPlaceholder(estimatedLatex: latex)
        }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacingBefore = 8
        para.paragraphSpacing = 8
        let attachment = LatexAttachment(image: image, font: font, isInline: false, latex: latex)
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(
            .paragraphStyle,
            value: para,
            range: NSRange(location: 0, length: result.length)
        )
        result.addAttribute(
            .font,
            value: font,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    private static func renderBlockMathPlaceholder(estimatedLatex: String) -> NSAttributedString {
        let lineCount = max(1, estimatedLatex.components(separatedBy: "\n").count)
        let placeholderHeight: CGFloat = min(120, 28 * CGFloat(lineCount) + 12)

        let attachment = BlockMathPlaceholderAttachment(height: placeholderHeight, latex: estimatedLatex)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacingBefore = 8
        para.paragraphSpacing = 8

        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: result.length))
        result.addAttribute(
            .font,
            value: OriveoTheme.Typography.chatBodyUIFont(size: 18),
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    @discardableResult
    static func upgradeBlockMathPlaceholders(in storage: NSTextStorage, latex: String) -> Bool {
        guard storage.length > 0 else { return false }
        guard let image = LatexImageCache.cachedImage(
            latex: latex,
            fontSize: 20,
            textColor: textColor,
            inline: false
        ) else { return false }
        let font = OriveoTheme.Typography.chatBodyUIFont(size: 18)
        var upgraded = false
        storage.beginEditing()
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let placeholder = value as? BlockMathPlaceholderAttachment,
                  placeholder.latex == latex else { return }
            let attachment = LatexAttachment(image: image, font: font, isInline: false, latex: latex)
            storage.addAttribute(.attachment, value: attachment, range: range)
            upgraded = true
        }
        storage.endEditing()
        return upgraded
    }


    private static func applyInlineMath(_ str: NSMutableAttributedString) {
        let range = NSRange(location: 0, length: str.length)
        let matches = inlineMathRegex.matches(in: str.string, range: range)
        guard !matches.isEmpty else { return }
        let baseFont: UIFont = {
            if str.length > 0,
               let f = str.attribute(.font, at: 0, effectiveRange: nil) as? UIFont {
                return f
            }
            return OriveoTheme.Typography.chatBodyUIFont()
        }()
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let latex = (str.string as NSString).substring(with: match.range(at: 1))
            guard !latex.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let mathFontSize = baseFont.pointSize * 1.1
            guard let image = LatexImageCache.requestImage(
                latex: latex,
                fontSize: mathFontSize,
                textColor: textColor,
                inline: true
            ) else {
                markUnresolvedLatexForCurrentRender()
                continue
            }
            let attachment = LatexAttachment(image: image, font: baseFont, isInline: true, latex: latex)
            let replacement = NSMutableAttributedString(attachment: attachment)
            if let para = str.attribute(
                .paragraphStyle,
                at: match.range(at: 0).location,
                effectiveRange: nil
            ) as? NSParagraphStyle {
                replacement.addAttribute(
                    .paragraphStyle,
                    value: para,
                    range: NSRange(location: 0, length: replacement.length)
                )
            }
            str.replaceCharacters(in: match.range(at: 0), with: replacement)
        }
    }

    static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, let marker = trimmed.first else { return false }
        guard marker == "-" || marker == "*" || marker == "_" else { return false }
        return trimmed.allSatisfy { $0 == marker }
    }

    private static func renderHorizontalRule() -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 4
        paragraphStyle.alignment = .natural

        let tintColor = UIColor(OriveoTheme.Palette.textTertiary).withAlphaComponent(0.36)
        let attachment = HorizontalRuleAttachment(color: tintColor)
        let divider = NSMutableAttributedString(attachment: attachment)
        divider.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: divider.length)
        )

        return divider
    }


    private enum ColumnAlignment {
        case left, center, right
    }

    private struct TableRegion {
        let start: Int
        let end: Int
        let alignments: [ColumnAlignment]
    }

    private static func detectTableRegions(_ lines: [String]) -> [TableRegion] {
        var regions: [TableRegion] = []
        var i = 0
        while i < lines.count - 1 {
            let separatorIndex = i + 1
            guard separatorIndex < lines.count else { break }

            let headerLine = lines[i].trimmingCharacters(in: .whitespaces)
            let separatorLine = lines[separatorIndex].trimmingCharacters(in: .whitespaces)

            if headerLine.contains("|"),
               isTableSeparator(separatorLine) {
                let headerCols = parseTableRow(headerLine)
                let sepCols = parseTableRow(separatorLine)
                if headerCols.count == sepCols.count, headerCols.count >= 1 {
                    let alignments = sepCols.map { parseAlignment($0) }
                    var end = separatorIndex + 1
                    while end < lines.count {
                        let dataLine = lines[end].trimmingCharacters(in: .whitespaces)
                        if dataLine.isEmpty || !dataLine.contains("|") { break }
                        let dataCols = parseTableRow(dataLine)
                        if dataCols.count != headerCols.count { break }
                        end += 1
                    }
                    regions.append(TableRegion(start: i, end: end, alignments: alignments))
                    i = end
                    continue
                }
            }
            i += 1
        }
        return regions
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let range = NSRange(location: 0, length: (line as NSString).length)
        return tableSeparatorRegex.firstMatch(in: line, range: range) != nil
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var trimmed = line
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func parseAlignment(_ separator: String) -> ColumnAlignment {
        let s = separator.trimmingCharacters(in: .whitespaces)
        let left = s.hasPrefix(":")
        let right = s.hasSuffix(":")
        if left && right { return .center }
        if right { return .right }
        return .left
    }

    private static func renderTable(_ lines: [String], alignments: [ColumnAlignment]) -> NSAttributedString {
        let headerCells = parseTableRow(lines[0])
        let colCount = headerCells.count
        var dataRows: [[String]] = []
        for rowIdx in 2..<lines.count {
            var cells = parseTableRow(lines[rowIdx])
            while cells.count < colCount { cells.append("") }
            if cells.count > colCount { cells = Array(cells.prefix(colCount)) }
            dataRows.append(cells)
        }

        let bodyFont = UIFont.systemFont(ofSize: 15)
        let boldFont = UIFont.systemFont(ofSize: 15, weight: .semibold)
        let headerFont = UIFont.systemFont(ofSize: 13, weight: .medium)
        let borderColor = tableBorderColor

        let result = NSMutableAttributedString()

        let isCompact = colCount <= 3 && headerCells.allSatisfy { UIKitTableCard.stripMarkdown($0).count <= 8 }
            && dataRows.allSatisfy { $0.allSatisfy { UIKitTableCard.stripMarkdown($0).count <= 15 } }

        if isCompact {
            let headerPara = NSMutableParagraphStyle()
            headerPara.paragraphSpacingBefore = 4
            headerPara.paragraphSpacing = 2

            let headerLine = NSMutableAttributedString()
            for (j, cell) in headerCells.enumerated() {
                if j > 0 {
                    headerLine.append(NSAttributedString(string: "  •  ", attributes: [
                        .font: bodyFont, .foregroundColor: borderColor,
                    ]))
                }
                headerLine.append(NSAttributedString(string: UIKitTableCard.stripMarkdown(cell), attributes: [
                    .font: boldFont, .foregroundColor: textColor, .backgroundColor: tableHeaderBg,
                ]))
            }
            headerLine.addAttribute(.paragraphStyle, value: headerPara, range: NSRange(location: 0, length: headerLine.length))
            result.append(headerLine)

            let rowPara = NSMutableParagraphStyle()
            rowPara.paragraphSpacing = 1

            for row in dataRows {
                let rowLine = NSMutableAttributedString(string: "\n")
                for (j, cell) in row.enumerated() where j < colCount {
                    if j > 0 {
                        rowLine.append(NSAttributedString(string: "  •  ", attributes: [
                            .font: bodyFont, .foregroundColor: borderColor,
                        ]))
                    }
                    rowLine.append(NSAttributedString(string: UIKitTableCard.stripMarkdown(cell), attributes: [
                        .font: bodyFont, .foregroundColor: textColor,
                    ]))
                }
                rowLine.addAttribute(.paragraphStyle, value: rowPara, range: NSRange(location: 0, length: rowLine.length))
                result.append(rowLine)
            }
        } else {
            let dividerPara = NSMutableParagraphStyle()
            dividerPara.paragraphSpacing = 0
            dividerPara.lineSpacing = 0

            for (i, row) in dataRows.enumerated() {
                if i > 0 {
                    let divider = NSMutableAttributedString(string: "\n─ ─ ─\n", attributes: [
                        .font: headerFont, .foregroundColor: borderColor,
                    ])
                    divider.addAttribute(.paragraphStyle, value: dividerPara, range: NSRange(location: 0, length: divider.length))
                    result.append(divider)
                } else {
                    let topPara = NSMutableParagraphStyle()
                    topPara.paragraphSpacingBefore = 4
                    result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: topPara]))
                }

                let kvPara = NSMutableParagraphStyle()
                kvPara.paragraphSpacing = 1
                kvPara.headIndent = 0

                for (j, cell) in row.enumerated() where j < colCount {
                    let header = UIKitTableCard.stripMarkdown(headerCells[j])
                    let value = UIKitTableCard.stripMarkdown(cell)
                    if j > 0 { result.append(NSAttributedString(string: "\n")) }

                    let kvLine = NSMutableAttributedString()
                    kvLine.append(NSAttributedString(string: header, attributes: [
                        .font: headerFont, .foregroundColor: borderColor,
                    ]))
                    kvLine.append(NSAttributedString(string: "  ", attributes: [.font: headerFont]))
                    kvLine.append(NSAttributedString(string: value, attributes: [
                        .font: bodyFont, .foregroundColor: textColor,
                    ]))
                    kvLine.addAttribute(.paragraphStyle, value: kvPara, range: NSRange(location: 0, length: kvLine.length))
                    result.append(kvLine)
                }
            }

            let endPara = NSMutableParagraphStyle()
            endPara.paragraphSpacing = 4
            result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: endPara]))
        }

        return result
    }


    static func renderTableCellContent(
        _ text: String,
        font: UIFont,
        textColor: UIColor,
        isHeader: Bool
    ) -> NSAttributedString {
        let processed = preprocessInline(text)
        let hasMath = processed.contains("$")
            || processed.contains("\\(")
            || processed.contains("\\[")
        var display = UIKitTableCard.stripMarkdown(processed)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        if isHeader, !hasMath {
            display = display.uppercased()
            attrs[.kern] = 0.3 as NSNumber
        }
        let str = NSMutableAttributedString(string: display, attributes: attrs)
        applyInlineMath(str)
        return str
    }

    static func measureTableCellContent(_ attr: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        let rect = attr.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }


    private static func applyInlineStyles(_ str: NSMutableAttributedString) {

        replaceMarkers(in: str, regex: codeRegex) { _ in [
            .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: codeFg,
            .backgroundColor: codeBg,
            .paragraphStyle: baseParagraphStyle,
        ]}

        applyInlineMath(str)

        applyLinks(str)

        replaceMarkers(in: str, regex: boldRegex) { _ in [
            .font: OriveoTheme.Typography.chatBodyUIFont(weight: .bold),
            .foregroundColor: textColor,
            .paragraphStyle: baseParagraphStyle,
        ]}

        replaceMarkers(in: str, regex: italicRegex) { _ in [
            .font: OriveoTheme.Typography.chatItalicUIFont(),
            .foregroundColor: textColor,
            .paragraphStyle: baseParagraphStyle,
        ]}

        replaceMarkers(in: str, regex: strikeRegex) { _ in [
            .font: OriveoTheme.Typography.chatBodyUIFont(),
            .foregroundColor: textColor,
            .paragraphStyle: baseParagraphStyle,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        ]}
    }

    private static func replaceMarkers(
        in attrStr: NSMutableAttributedString,
        regex: NSRegularExpression,
        attrs: (String) -> [NSAttributedString.Key: Any]
    ) {
        let range = NSRange(location: 0, length: attrStr.length)
        for match in regex.matches(in: attrStr.string, range: range).reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let content = (attrStr.string as NSString).substring(with: match.range(at: 1))
            let replacement = NSAttributedString(string: content, attributes: attrs(content))
            attrStr.replaceCharacters(in: match.range(at: 0), with: replacement)
        }
    }

    private static func applyLinks(_ str: NSMutableAttributedString) {
        let range = NSRange(location: 0, length: str.length)
        for match in linkRegex.matches(in: str.string, range: range).reversed() {
            guard match.numberOfRanges >= 3 else { continue }
            let text = (str.string as NSString).substring(with: match.range(at: 1))
            let urlString = (str.string as NSString).substring(with: match.range(at: 2))
            var linkAttrs: [NSAttributedString.Key: Any] = [
                .font: OriveoTheme.Typography.chatBodyUIFont(),
                .foregroundColor: linkColor,
                .paragraphStyle: baseParagraphStyle,
            ]
            if let url = ExternalURLPolicy.httpsURL(from: urlString) {
                linkAttrs[.link] = url
            }
            let replacement = NSAttributedString(string: text, attributes: linkAttrs)
            str.replaceCharacters(in: match.range(at: 0), with: replacement)
        }
    }

    private static func replacingMatches(
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
}

final class BlockMathPlaceholderAttachment: NSTextAttachment {
    let latex: String
    private let placeholderHeight: CGFloat
    private let placeholderColor = UIColor(OriveoTheme.Palette.textSecondary).withAlphaComponent(0.42)

    init(height: CGFloat, latex: String) {
        self.latex = latex
        self.placeholderHeight = height
        super.init(data: nil, ofType: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        let width = lineFrag.width > 0 ? lineFrag.width : 300
        return CGRect(x: 0, y: 0, width: width, height: placeholderHeight)
    }

    override func image(
        forBounds imageBounds: CGRect,
        textContainer: NSTextContainer?,
        characterIndex charIndex: Int
    ) -> UIImage? {
        let size = CGSize(
            width: max(imageBounds.width, 1),
            height: max(imageBounds.height, 1)
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = UIScreen.main.scale

        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            placeholderColor.setFill()
            let dotSize: CGFloat = 4
            let gap: CGFloat = 8
            let totalWidth = dotSize * 3 + gap * 2
            let startX = (size.width - totalWidth) / 2
            let y = (size.height - dotSize) / 2
            for i in 0..<3 {
                let x = startX + CGFloat(i) * (dotSize + gap)
                UIBezierPath(ovalIn: CGRect(x: x, y: y, width: dotSize, height: dotSize)).fill()
            }
        }
    }
}

private final class HorizontalRuleAttachment: NSTextAttachment {
    private let color: UIColor
    private let lineHeight: CGFloat = 9

    init(color: UIColor) {
        self.color = color
        super.init(data: nil, ofType: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        let availableWidth = max(lineFrag.width, UIScreen.main.bounds.width - 72)
        return CGRect(x: 0, y: -4, width: availableWidth, height: lineHeight)
    }

    override func image(
        forBounds imageBounds: CGRect,
        textContainer: NSTextContainer?,
        characterIndex charIndex: Int
    ) -> UIImage? {
        let size = CGSize(
            width: max(imageBounds.width, 1),
            height: max(imageBounds.height, 1)
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = UIScreen.main.scale

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setStroke()

            let path = UIBezierPath()
            path.lineWidth = 1 / format.scale
            let y = round(size.height / 2 * format.scale) / format.scale
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            path.stroke()

            context.cgContext.setShouldAntialias(false)
        }
    }
}
