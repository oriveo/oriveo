import Foundation

enum StreamingBlockChunker {

    enum BoundaryKind: Equatable {
        case wordChunk
        case lineEnd
        case paragraphEnd
        case tableRows
        case codeChunk
        case snap
        case held
    }

    struct Boundary: Equatable {
        let newVisible: String
        let kind: BoundaryKind
    }


    static func nextBoundary(
        visible: String,
        target: String,
        profile: StreamingPacerLanguageProfile,
        cadence: BlockCommitCadence,
        isStreamEnd: Bool,
        isInsideFence: Bool? = nil
    ) -> Boundary {
        guard target.hasPrefix(visible) else {
            return Boundary(newVisible: target, kind: .snap)
        }
        let nsT = target as NSString
        let tLen = nsT.length
        let vLen = (visible as NSString).length
        guard vLen < tLen else {
            return Boundary(newVisible: visible, kind: .held)
        }

        if isInsideFence ?? StreamingPacer.isInsideUnclosedCodeFence(visible) {
            return codeChunkBoundary(nsT: nsT, tLen: tLen, vLen: vLen, isStreamEnd: isStreamEnd)
        }

        let lastNL = vLen > 0
            ? nsT.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: vLen))
            : NSRange(location: NSNotFound, length: 0)
        let lineStart = lastNL.location == NSNotFound ? 0 : lastNL.location + 1
        let nextNL = nsT.range(of: "\n", range: NSRange(location: vLen, length: tLen - vLen))
        let lineEndNL: Int? = nextNL.location == NSNotFound ? nil : nextNL.location
        let lineSoFarEnd = lineEndNL ?? tLen
        let lineSoFar = nsT.substring(with: NSRange(location: lineStart, length: lineSoFarEnd - lineStart))
        let committedInLine = vLen - lineStart
        let lineComplete = lineEndNL != nil

        if committedInLine == 0 {
            if let special = lineStartProtocol(
                nsT: nsT, tLen: tLen,
                lineStart: lineStart, lineSoFar: lineSoFar,
                lineEndNL: lineEndNL, lineComplete: lineComplete,
                visible: visible, isStreamEnd: isStreamEnd
            ) {
                return special
            }
        }

        if lineComplete {
            return commitCompletedLines(
                nsT: nsT, tLen: tLen, vLen: vLen,
                firstLineEndNL: lineEndNL!, firstLineBlank: lineSoFar.trimmingCharacters(in: .whitespaces).isEmpty,
                cadence: cadence
            )
        }

        return wordChunkBoundary(
            nsT: nsT, lineStart: lineStart, lineSoFar: lineSoFar,
            committedInLine: committedInLine,
            profile: profile, cadence: cadence, isStreamEnd: isStreamEnd,
            isFirstReveal: vLen == 0
        )
    }


    private static func codeChunkBoundary(nsT: NSString, tLen: Int, vLen: Int, isStreamEnd: Bool) -> Boundary {
        let backlog = tLen - vLen
        var end = min(vLen + StreamingPacer.codeStepSize(for: backlog), tLen)
        let searchStart = max(0, vLen - 1)
        let closeFence = nsT.range(of: "\n```", range: NSRange(location: searchStart, length: tLen - searchStart))
        if closeFence.location != NSNotFound {
            let fenceLineStart = closeFence.location + 1
            let closeLineNL = nsT.range(
                of: "\n",
                range: NSRange(location: fenceLineStart, length: tLen - fenceLineStart)
            )
            let lineComplete = closeLineNL.location != NSNotFound
            let fenceBoundary = lineComplete ? closeLineNL.location + 1 : tLen
            if end > fenceBoundary {
                end = fenceBoundary
            } else if !isStreamEnd, end > fenceLineStart, end < fenceBoundary {
                end = lineComplete ? fenceBoundary : max(vLen, fenceLineStart)
            }
        }
        if !isStreamEnd {
            let lastNL = nsT.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: tLen))
            let lastLineStart = lastNL.location == NSNotFound ? 0 : lastNL.location + 1
            if lastLineStart < tLen, end > lastLineStart {
                let trimmed = nsT.substring(from: lastLineStart).trimmingCharacters(in: .whitespaces)
                if trimmed.count < 3, trimmed.allSatisfy({ $0 == "`" }) {
                    end = min(end, max(lastLineStart, vLen))
                }
            }
        }
        end = roundDownToComposedBoundary(nsT, proposed: end, floor: vLen)
        guard end > vLen else { return Boundary(newVisible: nsT.substring(to: vLen), kind: .held) }
        return Boundary(newVisible: nsT.substring(to: end), kind: .codeChunk)
    }


    private static func lineStartProtocol(
        nsT: NSString, tLen: Int,
        lineStart: Int, lineSoFar: String,
        lineEndNL: Int?, lineComplete: Bool,
        visible: String, isStreamEnd: Bool
    ) -> Boundary? {
        let trimmed = lineSoFar.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("```") {
            if let nl = lineEndNL {
                return Boundary(newVisible: nsT.substring(to: nl + 1), kind: .lineEnd)
            }
            if isStreamEnd {
                return Boundary(newVisible: nsT.substring(to: tLen), kind: .lineEnd)
            }
            return Boundary(newVisible: nsT.substring(to: lineStart), kind: .held)
        }

        if trimmed.hasPrefix("|") {
            return tableProtocol(
                nsT: nsT, tLen: tLen, lineStart: lineStart,
                lineEndNL: lineEndNL, lineSoFar: lineSoFar,
                visible: visible, isStreamEnd: isStreamEnd
            )
        }

        if trimmed.hasPrefix("$$") {
            return blockMathProtocol(
                nsT: nsT, tLen: tLen, lineStart: lineStart,
                lineSoFar: lineSoFar, lineEndNL: lineEndNL, isStreamEnd: isStreamEnd,
                opener: "$$", closer: "$$"
            )
        }

        if trimmed.hasPrefix("\\[") {
            return blockMathProtocol(
                nsT: nsT, tLen: tLen, lineStart: lineStart,
                lineSoFar: lineSoFar, lineEndNL: lineEndNL, isStreamEnd: isStreamEnd,
                opener: "\\[", closer: "\\]"
            )
        }

        if !trimmed.isEmpty, let first = trimmed.first,
           first == "-" || first == "*" || first == "_",
           trimmed.allSatisfy({ $0 == first }) {
            if let nl = lineEndNL {
                return Boundary(newVisible: nsT.substring(to: nl + 1), kind: .lineEnd)
            }
            if isStreamEnd {
                return Boundary(newVisible: nsT.substring(to: tLen), kind: .lineEnd)
            }
            return Boundary(newVisible: nsT.substring(to: lineStart), kind: .held)
        }

        if !lineComplete, !isStreamEnd, (lineSoFar as NSString).length < 4,
           !lineSoFar.isEmpty, isAllMarkerCandidates(lineSoFar) {
            return Boundary(newVisible: nsT.substring(to: lineStart), kind: .held)
        }

        return nil
    }

    private static func isAllMarkerCandidates(_ s: String) -> Bool {
        let ns = s as NSString
        for i in 0..<ns.length {
            switch ns.character(at: i) {
            case 0x23, 0x3E, 0x2D, 0x2A, 0x5F, 0x24, 0x7C, 0x60, 0x7E, 0x20, 0x09,
                 0x5C, 0x5B:
                continue
            default:
                return false
            }
        }
        return true
    }


    private static func tableProtocol(
        nsT: NSString, tLen: Int, lineStart: Int,
        lineEndNL: Int?, lineSoFar: String,
        visible: String, isStreamEnd: Bool
    ) -> Boundary {
        let held = Boundary(newVisible: nsT.substring(to: lineStart), kind: .held)

        if visibleEndsInOpenTable(visible) {
            guard let nl = lineEndNL else {
                return isStreamEnd
                    ? Boundary(newVisible: nsT.substring(to: tLen), kind: .tableRows)
                    : held
            }
            let end = extendThroughCompleteTableRows(nsT: nsT, tLen: tLen, from: nl + 1)
            return Boundary(newVisible: nsT.substring(to: end), kind: .tableRows)
        }

        guard let headerNL = lineEndNL else {
            return isStreamEnd
                ? Boundary(newVisible: nsT.substring(to: tLen), kind: .lineEnd)
                : held
        }
        let sepStart = headerNL + 1
        let sepNL = nsT.range(of: "\n", range: NSRange(location: sepStart, length: tLen - sepStart))
        let sepEnd = sepNL.location == NSNotFound ? tLen : sepNL.location
        let sepComplete = sepNL.location != NSNotFound
        guard sepComplete || isStreamEnd else { return held }
        let separator = nsT.substring(with: NSRange(location: sepStart, length: sepEnd - sepStart))

        if StreamingSegmentParser.isTableHeaderSeparatorPair(header: lineSoFar, separator: separator) {
            let afterSep = sepComplete ? sepEnd + 1 : tLen
            let end = extendThroughCompleteTableRows(nsT: nsT, tLen: tLen, from: afterSep)
            return Boundary(newVisible: nsT.substring(to: end), kind: .tableRows)
        }
        return Boundary(newVisible: nsT.substring(to: headerNL + 1), kind: .lineEnd)
    }

    private static func extendThroughCompleteTableRows(nsT: NSString, tLen: Int, from: Int) -> Int {
        var end = from
        while end < tLen {
            let nl = nsT.range(of: "\n", range: NSRange(location: end, length: tLen - end))
            guard nl.location != NSNotFound else { break }
            let line = nsT.substring(with: NSRange(location: end, length: nl.location - end))
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.contains("|") else { break }
            end = nl.location + 1
        }
        return end
    }

    static func visibleEndsInOpenTable(_ visible: String) -> Bool {
        let ns = visible as NSString
        var end = ns.length
        if end > 0, ns.character(at: end - 1) == 0x0A { end -= 1 }
        guard end > 0 else { return false }

        var first: NSRange?
        var second: NSRange?
        var lineEnd = end
        while lineEnd > 0 {
            let nl = ns.range(
                of: "\n",
                options: .backwards,
                range: NSRange(location: 0, length: lineEnd)
            )
            let lineStart = nl.location == NSNotFound ? 0 : nl.location + 1
            let line = NSRange(location: lineStart, length: lineEnd - lineStart)
            let t = ns.substring(with: line).trimmingCharacters(in: .whitespaces)
            if t.isEmpty || !t.contains("|") { break }
            second = first
            first = line
            if lineStart == 0 { break }
            lineEnd = lineStart - 1
        }
        guard let first, let second else { return false }
        return StreamingSegmentParser.isTableHeaderSeparatorPair(
            header: ns.substring(with: first),
            separator: ns.substring(with: second)
        )
    }


    private static func blockMathProtocol(
        nsT: NSString, tLen: Int, lineStart: Int,
        lineSoFar: String, lineEndNL: Int?, isStreamEnd: Bool,
        opener: String, closer: String
    ) -> Boundary {
        let held = Boundary(newVisible: nsT.substring(to: lineStart), kind: .held)
        let trimmed = lineSoFar.trimmingCharacters(in: .whitespaces)

        if let nl = lineEndNL,
           trimmed.count >= opener.count + closer.count,
           trimmed.hasSuffix(closer),
           trimmed != opener {
            return Boundary(newVisible: nsT.substring(to: nl + 1), kind: .lineEnd)
        }

        if let openerNL = lineEndNL {
            var cursor = openerNL + 1
            while cursor < tLen {
                let nl = nsT.range(of: "\n", range: NSRange(location: cursor, length: tLen - cursor))
                let lineEnd = nl.location == NSNotFound ? tLen : nl.location
                let line = nsT.substring(with: NSRange(location: cursor, length: lineEnd - cursor))
                if line.contains(closer) {
                    if nl.location != NSNotFound {
                        return Boundary(newVisible: nsT.substring(to: nl.location + 1), kind: .lineEnd)
                    }
                    return isStreamEnd
                        ? Boundary(newVisible: nsT.substring(to: tLen), kind: .lineEnd)
                        : held
                }
                guard nl.location != NSNotFound else { break }
                cursor = nl.location + 1
            }
        }
        return isStreamEnd
            ? Boundary(newVisible: nsT.substring(to: tLen), kind: .lineEnd)
            : held
    }


    private static func commitCompletedLines(
        nsT: NSString, tLen: Int, vLen: Int,
        firstLineEndNL: Int, firstLineBlank: Bool,
        cadence: BlockCommitCadence
    ) -> Boundary {
        var commitEnd = firstLineEndNL + 1
        var lastBlank = firstLineBlank

        let backlog = tLen - vLen
        if backlog > cadence.multiLineBacklog {
            var linesCommitted = 1
            while linesCommitted < cadence.multiLineMax {
                let nl = nsT.range(of: "\n", range: NSRange(location: commitEnd, length: tLen - commitEnd))
                guard nl.location != NSNotFound else { break }
                let line = nsT.substring(with: NSRange(location: commitEnd, length: nl.location - commitEnd))
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("```") || t.hasPrefix("|") || t.hasPrefix("$$") || t.hasPrefix("\\[") { break }
                commitEnd = nl.location + 1
                linesCommitted += 1
                lastBlank = t.isEmpty
            }
        }

        return Boundary(
            newVisible: nsT.substring(to: commitEnd),
            kind: lastBlank ? .paragraphEnd : .lineEnd
        )
    }


    private static func wordChunkBoundary(
        nsT: NSString, lineStart: Int, lineSoFar: String,
        committedInLine: Int,
        profile: StreamingPacerLanguageProfile,
        cadence: BlockCommitCadence,
        isStreamEnd: Bool,
        isFirstReveal: Bool
    ) -> Boundary {
        let nsLine = lineSoFar as NSString
        let lineLen = nsLine.length
        let held = Boundary(newVisible: nsT.substring(to: lineStart + committedInLine), kind: .held)

        let markerLen = lineMarkerUTF16Length(lineSoFar)
        guard lineLen > markerLen else { return held }

        let scanInput = nsLine.substring(from: markerLen)
        var safeRel = StreamingInlineSpanScanner.safeBoundary(in: scanInput)
        let scanLen = (scanInput as NSString).length
        if isStreamEnd || (scanLen - safeRel) > cadence.maxInlineHoldUTF16 {
            safeRel = scanLen
        }
        let safeAbs = markerLen + safeRel
        var committable = safeAbs

        if profile == .ascii, !isStreamEnd {
            let capped = capAtLastWhitespace(nsLine, upTo: committable, floor: markerLen)
            if (safeAbs - capped) > cadence.maxWordHoldUTF16 {
                committable = safeAbs
            } else if capped <= markerLen, isFirstReveal {
                committable = safeAbs
            } else {
                committable = capped
            }
        }
        guard committable > committedInLine else { return held }

        var end: Int
        if isStreamEnd {
            end = committable
        } else {
            let chunkLen = profile == .ascii ? cadence.wordChunkLenASCII : cadence.wordChunkLenCJK
            let ideal = max(committedInLine, markerLen) + chunkLen
            if ideal >= committable {
                end = committable
            } else if profile == .ascii {
                var w = ideal
                let scanLimit = min(committable, ideal + 64)
                while w < scanLimit, !isWhitespace(nsLine.character(at: w)) { w += 1 }
                end = w < scanLimit ? w + 1 : min(ideal, committable)
            } else {
                end = roundDownToComposedBoundary(nsLine, proposed: ideal, floor: committedInLine)
            }
            while end > committedInLine, end < committable {
                let prefix = nsLine.substring(with: NSRange(location: markerLen, length: end - markerLen))
                if StreamingInlineSpanScanner.safeBoundary(in: prefix) == (prefix as NSString).length {
                    break
                }
                end += 1
            }
        }
        guard end > committedInLine else { return held }

        let kind: BoundaryKind = isStreamEnd && end == lineLen ? .lineEnd : .wordChunk
        return Boundary(newVisible: nsT.substring(to: lineStart + end), kind: kind)
    }

    private static func lineMarkerUTF16Length(_ line: String) -> Int {
        let ns = line as NSString
        let len = ns.length
        var i = 0
        while i < len, i < 6, ns.character(at: i) == 0x23 { i += 1 }   // '#'
        if i >= 1 {
            guard i < len, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 else { return 0 }
            var j = i
            while j < len, ns.character(at: j) == 0x20 || ns.character(at: j) == 0x09 { j += 1 }
            return j
        }
        if line.hasPrefix("> ") { return 2 }
        var k = 0
        while k < len, ns.character(at: k) == 0x20 || ns.character(at: k) == 0x09 { k += 1 }
        if k < len, ns.character(at: k) == 0x2D || ns.character(at: k) == 0x2A,
           k + 1 < len, ns.character(at: k + 1) == 0x20 {
            return k + 2
        }
        return 0
    }

    private static func capAtLastWhitespace(_ nsLine: NSString, upTo limit: Int, floor: Int) -> Int {
        var last: Int?
        var i = floor
        while i < limit {
            if isWhitespace(nsLine.character(at: i)) { last = i }
            i += 1
        }
        guard let last else { return floor }
        return last + 1
    }

    private static func isWhitespace(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09
    }

    private static func roundDownToComposedBoundary(_ ns: NSString, proposed: Int, floor: Int) -> Int {
        guard proposed > floor, proposed < ns.length else { return proposed }
        let r = ns.rangeOfComposedCharacterSequence(at: proposed - 1)
        if r.location < proposed, r.location + r.length > proposed {
            return max(floor, r.location)
        }
        return proposed
    }
}
