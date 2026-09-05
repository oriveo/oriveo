import Foundation

enum ReasoningPreviewText {

    static let defaultMaxCharacters = 40

    static let defaultScanWindow = 160
    static let defaultSourceByteLimit = 1_024

    static func previewLine(
        of text: String,
        maxCharacters: Int = defaultMaxCharacters,
        scanWindow: Int = defaultScanWindow
    ) -> String {
        guard !text.isEmpty else { return "" }
        let source = boundedSuffix(
            of: text,
            maxUTF8Bytes: max(defaultSourceByteLimit, scanWindow * 4)
        )

        var end = source.endIndex
        while end > source.startIndex {
            let previous = source.index(before: end)
            guard source[previous].isWhitespace else { break }
            end = previous
        }
        guard end > source.startIndex else { return "" }

        var start = end
        var scanned = 0
        var reachedLineStart = false
        while start > source.startIndex {
            let previous = source.index(before: start)
            if source[previous].isNewline {
                reachedLineStart = true
                break
            }
            if scanned >= scanWindow { break }
            start = previous
            scanned += 1
        }
        if start == source.startIndex, source.utf8.count == text.utf8.count {
            reachedLineStart = true
        }

        let stripped = strippingMarkers(source[start..<end], isLineStart: reachedLineStart)

        guard stripped.contains(where: { !isMarkerOnlyCharacter($0) }) else { return "" }

        if stripped.count > maxCharacters {
            return "…" + String(stripped.suffix(maxCharacters))
        }
        return reachedLineStart ? stripped : "…" + stripped
    }

    static func boundedSuffix(of text: String, maxUTF8Bytes: Int = defaultSourceByteLimit) -> String {
        guard maxUTF8Bytes > 0 else { return "" }
        let utf8 = text.utf8
        guard utf8.count > maxUTF8Bytes else { return text }
        var index = utf8.index(utf8.endIndex, offsetBy: -maxUTF8Bytes)
        while index < utf8.endIndex, String.Index(index, within: text) == nil {
            utf8.formIndex(after: &index)
        }
        guard let start = String.Index(index, within: text) else { return "" }
        return String(text[start...])
    }

    static func appendingToBoundedSuffix(
        _ previous: String,
        delta: String,
        maxUTF8Bytes: Int = defaultSourceByteLimit
    ) -> String {
        guard !delta.isEmpty else { return boundedSuffix(of: previous, maxUTF8Bytes: maxUTF8Bytes) }
        let deltaBytes = delta.utf8.count
        guard deltaBytes < maxUTF8Bytes else {
            return boundedSuffix(of: delta, maxUTF8Bytes: maxUTF8Bytes)
        }
        let retained = boundedSuffix(of: previous, maxUTF8Bytes: maxUTF8Bytes - deltaBytes)
        return retained + delta
    }

    private static func isMarkerOnlyCharacter(_ character: Character) -> Bool {
        character.isWhitespace || "*`~#>-+_|=".contains(character)
    }

    static func strippingMarkers(_ segment: Substring, isLineStart: Bool) -> String {
        let chars = Array(segment)
        var index = isLineStart ? blockMarkerPrefixLength(chars) : 0

        var output = ""
        output.reserveCapacity(chars.count)

        while index < chars.count {
            let character = chars[index]

            if character == "*" || character == "`" || character == "~" {
                var run = 1
                while index + run < chars.count, chars[index + run] == character { run += 1 }
                let isEscaped = index > 0 && chars[index - 1] == "\\"
                let isEmphasisMarker = character != "~" || run >= 2
                let attachedLeft = index > 0 && !chars[index - 1].isWhitespace
                let attachedRight = index + run < chars.count && !chars[index + run].isWhitespace
                let isNumericOperator = run == 1
                    && chars[safe: index - 1]?.isNumber == true
                    && chars[safe: index + run]?.isNumber == true
                let isInlineMarker: Bool
                if character == "*", run == 1 {
                    isInlineMarker = (!attachedLeft && attachedRight)
                        || (attachedLeft && attachedRight && !isNumericOperator)
                } else {
                    isInlineMarker = attachedLeft || attachedRight
                }
                if !isEscaped && isEmphasisMarker && isInlineMarker {
                    index += run
                    continue
                }
                output.append(String(repeating: character, count: run))
                index += run
                continue
            }

            if character == "[", let link = linkSpan(chars, openBracket: index) {
                output.append(contentsOf: chars[link.text])
                index = link.end
                continue
            }

            output.append(character)
            index += 1
        }

        return output
    }

    private static func blockMarkerPrefixLength(_ chars: [Character]) -> Int {
        func skippingWhitespace(from start: Int) -> Int {
            var index = start
            while index < chars.count, chars[index].isWhitespace, !chars[index].isNewline { index += 1 }
            return index
        }

        var hashes = 0
        while hashes < chars.count, hashes < 6, chars[hashes] == "#" { hashes += 1 }
        if hashes >= 1, hashes < chars.count, chars[hashes].isWhitespace {
            return skippingWhitespace(from: hashes)
        }

        if chars.first == ">", chars.count > 1, chars[1].isWhitespace {
            return skippingWhitespace(from: 1)
        }

        if let first = chars.first,
           first == "-" || first == "*" || first == "+",
           chars.count > 1, chars[1].isWhitespace {
            return skippingWhitespace(from: 2)
        }

        var digits = 0
        while digits < chars.count, chars[digits].isNumber { digits += 1 }
        if digits > 0, digits + 1 < chars.count, chars[digits] == ".", chars[digits + 1].isWhitespace {
            return skippingWhitespace(from: digits + 2)
        }

        return 0
    }

    private static func linkSpan(
        _ chars: [Character],
        openBracket: Int
    ) -> (text: Range<Int>, end: Int)? {
        var index = openBracket + 1
        while index < chars.count, chars[index] != "]" {
            if chars[index].isNewline { return nil }
            index += 1
        }
        guard index < chars.count else { return nil }
        let textRange = (openBracket + 1)..<index
        guard index + 1 < chars.count, chars[index + 1] == "(" else { return nil }
        var closing = index + 2
        while closing < chars.count, chars[closing] != ")" {
            if chars[closing].isNewline { return nil }
            closing += 1
        }
        guard closing < chars.count else { return nil }
        return (textRange, closing + 1)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
