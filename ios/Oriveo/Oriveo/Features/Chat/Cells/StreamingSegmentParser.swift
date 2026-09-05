import Foundation

enum StreamingSegmentParser {


    struct Segment: Equatable {
        enum Kind: Equatable {
            case text
            case codeBlock(language: String?)
            case table(lines: [String])
        }

        let kind: Kind
        let content: String
    }

    struct UnclosedFence: Equatable {
        let textBefore: String
        let language: String?
        let code: String
    }

    struct ParsedContent: Equatable {
        let committed: [Segment]
        let tail: String
        let streamingTable: [String]?
        let unclosedFence: UnclosedFence?

        init(
            committed: [Segment],
            tail: String,
            streamingTable: [String]?,
            unclosedFence: UnclosedFence? = nil
        ) {
            self.committed = committed
            self.tail = tail
            self.streamingTable = streamingTable
            self.unclosedFence = unclosedFence
        }
    }

    internal struct ScanState: Equatable {
        var rawCommitted: [Segment]
        var inCodeBlock: Bool
        var codeContent: String
        var codeLang: String?
        var normalContent: String

        static let initial = ScanState(
            rawCommitted: [],
            inCodeBlock: false,
            codeContent: "",
            codeLang: nil,
            normalContent: ""
        )
    }


    static func parse(_ text: String) -> ParsedContent {
        if !text.contains("```") && !text.contains("|") {
            return ParsedContent(committed: [], tail: text, streamingTable: nil)
        }

        var state = ScanState.initial
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        scanLines(lines, into: &state)
        return finalizeScan(state: state)
    }

    internal static func scanLines<C: Collection>(
        _ lines: C,
        into state: inout ScanState
    ) where C.Element: StringProtocol {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if state.inCodeBlock {
                    if !state.normalContent.isEmpty {
                        if state.normalContent.hasSuffix("\n") { state.normalContent.removeLast() }
                        state.rawCommitted.append(Segment(kind: .text, content: state.normalContent))
                        state.normalContent = ""
                    }
                    if state.codeContent.hasSuffix("\n") { state.codeContent.removeLast() }
                    state.rawCommitted.append(
                        Segment(kind: .codeBlock(language: state.codeLang), content: state.codeContent)
                    )
                    state.codeContent = ""
                    state.codeLang = nil
                    state.inCodeBlock = false
                } else {
                    let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    state.codeLang = lang.isEmpty ? nil : lang
                    state.inCodeBlock = true
                }
            } else if state.inCodeBlock {
                state.codeContent += String(line) + "\n"
            } else {
                state.normalContent += String(line) + "\n"
            }
        }
    }

    internal static func finalizeScan(state: ScanState) -> ParsedContent {
        let refined = splitTextSegmentsForTables(state.rawCommitted)

        if state.inCodeBlock {
            let (lifted, remainingNormal) = liftClosedTablesFromTail(state.normalContent)
            var tailParts = remainingNormal
            if !tailParts.isEmpty, !tailParts.hasSuffix("\n") { tailParts += "\n" }
            let langTag = state.codeLang.map { "```\($0)" } ?? "```"
            tailParts += langTag + "\n" + state.codeContent
            if tailParts.hasSuffix("\n") { tailParts.removeLast() }
            var textBefore = remainingNormal
            if textBefore.hasSuffix("\n") { textBefore.removeLast() }
            var code = state.codeContent
            if code.hasSuffix("\n") { code.removeLast() }
            if code.hasSuffix("\n") { code.removeLast() }
            return ParsedContent(
                committed: refined + lifted,
                tail: tailParts,
                streamingTable: nil,
                unclosedFence: UnclosedFence(
                    textBefore: textBefore,
                    language: state.codeLang,
                    code: code
                )
            )
        }

        var tail = state.normalContent
        if tail.hasSuffix("\n") { tail.removeLast() }
        let (refinedTail, streamingTable) = splitTailAtTrailingTable(tail)
        let (liftedFromTail, finalTail) = liftClosedTablesFromTail(refinedTail)
        return ParsedContent(
            committed: refined + liftedFromTail,
            tail: finalTail,
            streamingTable: streamingTable
        )
    }

    /// "text before\n```swift\ncode here" → ("text before", ("swift", "code here"))
    /// "just text" → ("just text", nil)
    static func splitTailAtUnclosedFence(_ tail: String) -> (text: String, unclosed: (language: String?, code: String)?) {
        var fenceCount = 0
        var lastOpenFenceLineStart: String.Index?
        var lastOpenLang: String?

        let lines = tail.split(separator: "\n", omittingEmptySubsequences: false)
        var lineStart = tail.startIndex
        for line in lines {
            let lineEnd = tail.index(lineStart, offsetBy: line.count, limitedBy: tail.endIndex) ?? tail.endIndex
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                fenceCount += 1
                if fenceCount % 2 != 0 {
                    lastOpenFenceLineStart = lineStart
                    let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    lastOpenLang = lang.isEmpty ? nil : lang
                }
            }
            lineStart = tail.index(lineEnd, offsetBy: 1, limitedBy: tail.endIndex) ?? tail.endIndex
        }

        guard fenceCount % 2 != 0, let fenceStart = lastOpenFenceLineStart else {
            return (tail, nil)
        }

        var textPart = String(tail[..<fenceStart])
        if textPart.hasSuffix("\n") { textPart.removeLast() }

        let afterFenceLine = tail[fenceStart...]
        let fenceLineEnd = afterFenceLine.firstIndex(of: "\n") ?? afterFenceLine.endIndex
        let codeStart = afterFenceLine.index(fenceLineEnd, offsetBy: 1, limitedBy: afterFenceLine.endIndex) ?? afterFenceLine.endIndex
        var code = String(tail[codeStart...])
        if code.hasSuffix("\n") { code.removeLast() }

        return (textPart, (lastOpenLang, code))
    }

    static func textContainsGFMTable(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else { return false }
        for i in 0..<(lines.count - 1) {
            let headerLine = lines[i].trimmingCharacters(in: .whitespaces)
            guard headerLine.contains("|") else { continue }
            let sepLine = lines[i + 1].trimmingCharacters(in: .whitespaces)
            let range = NSRange(location: 0, length: (sepLine as NSString).length)
            if tableSepRegex.firstMatch(in: sepLine, range: range) != nil {
                let headerCols = parseTableRow(headerLine)
                let sepCols = parseTableRow(sepLine)
                if headerCols.count == sepCols.count, headerCols.count >= 1 {
                    return true
                }
            }
        }
        return false
    }

    static func isTableSeparatorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        return tableSepRegex.firstMatch(in: trimmed, range: range) != nil
    }

    static func isTableHeaderSeparatorPair(header: String, separator: String) -> Bool {
        let h = header.trimmingCharacters(in: .whitespaces)
        guard h.contains("|"), isTableSeparatorLine(separator) else { return false }
        let headerCols = parseTableRow(h)
        let sepCols = parseTableRow(separator.trimmingCharacters(in: .whitespaces))
        return headerCols.count == sepCols.count && headerCols.count >= 1
    }


    fileprivate static func liftClosedTablesFromTail(_ tail: String) -> (lifted: [Segment], remainingTail: String) {
        guard tail.contains("|") else { return ([], tail) }

        let virtual = Segment(kind: .text, content: tail)
        let split = splitTextSegmentsForTables([virtual])

        if split.count == 1, case .text = split[0].kind, split[0].content == tail {
            return ([], tail)
        }

        var lifted: [Segment] = []
        var remaining = ""
        for (i, seg) in split.enumerated() {
            let isLast = (i == split.count - 1)
            if isLast, case .text = seg.kind {
                remaining = seg.content
            } else {
                lifted.append(seg)
            }
        }
        return (lifted, remaining)
    }

    fileprivate static func splitTailAtTrailingTable(_ tail: String) -> (text: String, tableLines: [String]?) {
        let lines = tail.components(separatedBy: "\n")
        guard lines.count >= 2 else { return (tail, nil) }

        var regions: [(start: Int, end: Int)] = []
        var i = 0
        while i < lines.count - 1 {
            let headerLine = lines[i].trimmingCharacters(in: .whitespaces)
            let separatorLine = lines[i + 1].trimmingCharacters(in: .whitespaces)
            if headerLine.contains("|") {
                let sepRange = NSRange(location: 0, length: (separatorLine as NSString).length)
                if tableSepRegex.firstMatch(in: separatorLine, range: sepRange) != nil {
                    let headerCols = parseTableRow(headerLine)
                    let sepCols = parseTableRow(separatorLine)
                    if headerCols.count == sepCols.count, headerCols.count >= 1 {
                        var end = i + 2
                        while end < lines.count {
                            let dataLine = lines[end].trimmingCharacters(in: .whitespaces)
                            if dataLine.isEmpty || !dataLine.contains("|") { break }
                            end += 1
                        }
                        regions.append((start: i, end: end))
                        i = end
                        continue
                    }
                }
            }
            i += 1
        }

        guard let last = regions.last else { return (tail, nil) }

        if last.end < lines.count {
            let trailing = lines[last.end...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trailing.isEmpty {
                return (tail, nil)
            }
        }

        let beforeLines = lines[..<last.start]
        let tableLines = Array(lines[last.start..<last.end])
        var beforeText = beforeLines.joined(separator: "\n")
        while beforeText.hasSuffix("\n") { beforeText.removeLast() }
        return (beforeText, tableLines)
    }

    static func splitTextSegmentsForTables(_ segments: [Segment]) -> [Segment] {
        var result: [Segment] = []

        for segment in segments {
            guard case .text = segment.kind else {
                result.append(segment)
                continue
            }

            let lines = segment.content.components(separatedBy: "\n")
            var tableRegions: [(start: Int, end: Int)] = []

            var i = 0
            while i < lines.count - 1 {
                let headerLine = lines[i].trimmingCharacters(in: .whitespaces)
                let separatorLine = lines[i + 1].trimmingCharacters(in: .whitespaces)

                if headerLine.contains("|") {
                    let sepRange = NSRange(location: 0, length: (separatorLine as NSString).length)
                    if Self.tableSepRegex.firstMatch(in: separatorLine, range: sepRange) != nil {
                        let headerCols = parseTableRow(headerLine)
                        let sepCols = parseTableRow(separatorLine)
                        if headerCols.count == sepCols.count, headerCols.count >= 1 {
                            var end = i + 2
                            while end < lines.count {
                                let dataLine = lines[end].trimmingCharacters(in: .whitespaces)
                                if dataLine.isEmpty || !dataLine.contains("|") { break }
                                let dataCols = parseTableRow(dataLine)
                                if dataCols.count != headerCols.count { break }
                                end += 1
                            }
                            tableRegions.append((start: i, end: end))
                            i = end
                            continue
                        }
                    }
                }
                i += 1
            }

            if tableRegions.isEmpty {
                result.append(segment)
                continue
            }

            var cursor = 0
            for region in tableRegions {
                if cursor < region.start {
                    let textLines = lines[cursor..<region.start]
                    let text = textLines.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        result.append(Segment(kind: .text, content: text))
                    }
                }
                let tableLines = Array(lines[region.start..<region.end])
                let rawContent = tableLines.joined(separator: "\n")
                result.append(Segment(kind: .table(lines: tableLines), content: rawContent))
                cursor = region.end
            }
            if cursor < lines.count {
                let text = lines[cursor...].joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    result.append(Segment(kind: .text, content: text))
                }
            }
        }
        return result
    }

    fileprivate static func parseTableRow(_ line: String) -> [String] {
        var trimmed = line
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    fileprivate static let tableSepRegex = try! NSRegularExpression(
        pattern: #"^\|[ \t]*:?-{1,}:?[ \t]*(\|[ \t]*:?-{1,}:?[ \t]*)*\|?[ \t]*$"#,
        options: .anchorsMatchLines
    )
}


@MainActor
final class IncrementalStreamingSegmentParser {

    private var lastInput: String = ""
    private var lastResult: StreamingSegmentParser.ParsedContent = .init(
        committed: [], tail: "", streamingTable: nil
    )
    private var lastSnapshotAtBoundary: StreamingSegmentParser.ScanState?
    private var lastNewlineIndex: String.Index?

    func reset() {
        lastInput = ""
        lastResult = .init(committed: [], tail: "", streamingTable: nil)
        lastSnapshotAtBoundary = nil
        lastNewlineIndex = nil
    }

    func parse(_ text: String) -> StreamingSegmentParser.ParsedContent {
        if text == lastInput { return lastResult }

        if !text.contains("```") && !text.contains("|") {
            let result = StreamingSegmentParser.ParsedContent(
                committed: [], tail: text, streamingTable: nil
            )
            lastInput = text
            lastResult = result
            lastSnapshotAtBoundary = nil
            lastNewlineIndex = nil
            return result
        }

        if text.hasPrefix(lastInput),
           !lastInput.isEmpty,
           let snapshot = lastSnapshotAtBoundary,
           let oldBoundary = lastNewlineIndex {
            return incrementalParse(text: text, oldBoundary: oldBoundary, snapshot: snapshot)
        }

        return fullParse(text: text)
    }

    private func fullParse(text: String) -> StreamingSegmentParser.ParsedContent {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var state = StreamingSegmentParser.ScanState.initial

        if lines.count <= 1 {
            if let only = lines.first {
                StreamingSegmentParser.scanLines(CollectionOfOne(only), into: &state)
            }
            let result = StreamingSegmentParser.finalizeScan(state: state)
            lastInput = text
            lastResult = result
            lastSnapshotAtBoundary = nil
            lastNewlineIndex = nil
            return result
        }

        StreamingSegmentParser.scanLines(lines.dropLast(), into: &state)
        let snapshot = state
        // finalState = snapshot + scan(lines.last)
        StreamingSegmentParser.scanLines(CollectionOfOne(lines[lines.index(before: lines.endIndex)]), into: &state)

        let result = StreamingSegmentParser.finalizeScan(state: state)
        lastInput = text
        lastResult = result
        lastSnapshotAtBoundary = snapshot
        lastNewlineIndex = text.lastIndex(of: "\n")
        return result
    }

    private func incrementalParse(
        text: String,
        oldBoundary: String.Index,
        snapshot: StreamingSegmentParser.ScanState
    ) -> StreamingSegmentParser.ParsedContent {
        let scanStart = text.index(after: oldBoundary)
        let suffix = text[scanStart..<text.endIndex]
        let suffixLines = suffix.split(separator: "\n", omittingEmptySubsequences: false)

        var state = snapshot

        if suffixLines.count <= 1 {
            if let only = suffixLines.first {
                StreamingSegmentParser.scanLines(CollectionOfOne(only), into: &state)
            }
            let result = StreamingSegmentParser.finalizeScan(state: state)
            lastInput = text
            lastResult = result
            lastSnapshotAtBoundary = snapshot
            lastNewlineIndex = oldBoundary
            return result
        }

        StreamingSegmentParser.scanLines(suffixLines.dropLast(), into: &state)
        let newSnapshot = state
        StreamingSegmentParser.scanLines(
            CollectionOfOne(suffixLines[suffixLines.index(before: suffixLines.endIndex)]),
            into: &state
        )

        let result = StreamingSegmentParser.finalizeScan(state: state)
        lastInput = text
        lastResult = result
        lastSnapshotAtBoundary = newSnapshot
        lastNewlineIndex = suffix.lastIndex(of: "\n")
        return result
    }
}
