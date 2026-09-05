import Foundation

struct ReasoningCanonicalStream {

    static let defaultMaxHoldUTF16 = 4_096

    private static let ambiguityWindow = 4

    private let maxHoldUTF16: Int

    private var pending: String = ""
    private var openLineKind: MarkdownAttributedStringRenderer.CanonicalLineKind?

    init(maxHoldUTF16: Int = defaultMaxHoldUTF16) {
        self.maxHoldUTF16 = maxHoldUTF16
    }

    // MARK: - API

    mutating func consume(_ delta: String) -> NSAttributedString? {
        guard !delta.isEmpty else { return nil }
        pending += delta
        return flush(isEnd: false)
    }

    mutating func drain() -> NSAttributedString? {
        flush(isEnd: true)
    }

    mutating func reset() {
        pending = ""
        openLineKind = nil
    }

    var hasPending: Bool { !pending.isEmpty }

    var pendingUTF16Length: Int { (pending as NSString).length }


    private mutating func flush(isEnd: Bool) -> NSAttributedString? {
        let output = NSMutableAttributedString()

        if let kind = openLineKind {
            let ns = pending as NSString
            let nl = ns.range(of: "\n")
            if nl.location == NSNotFound {
                appendMidLineSpan(kind: kind, to: output, isEnd: isEnd)
                return output.length > 0 ? output : nil
            }
            let span = ns.substring(to: nl.location)
            if !span.isEmpty {
                output.append(MarkdownAttributedStringRenderer.renderCommittedSpan(
                    kind: kind, span: span, isLineStart: false
                ))
            }
            output.append(MarkdownAttributedStringRenderer.canonicalLineSeparator())
            pending = ns.substring(from: nl.location + 1)
            openLineKind = nil
        }

        while true {
            let ns = pending as NSString
            guard ns.length > 0 else { return output.length > 0 ? output : nil }
            let lastNL = ns.range(of: "\n", options: .backwards)
            guard lastNL.location != NSNotFound else { break }
            let forced = isEnd || ns.length > maxHoldUTF16
            let groupEnd = Self.safeGroupEnd(ns, lastNewline: lastNL.location, forced: forced)
            guard groupEnd > 0 else { return output.length > 0 ? output : nil }
            appendGroup(ns.substring(to: groupEnd), to: output)
            pending = ns.substring(from: groupEnd)
            if groupEnd > lastNL.location { break }
        }

        guard !pending.isEmpty else { return output.length > 0 ? output : nil }
        let forced = isEnd || (pending as NSString).length > maxHoldUTF16
        guard let kind = Self.lineStartKind(of: pending, forced: forced) else {
            return output.length > 0 ? output : nil
        }
        openLineKind = kind
        appendMidLineSpan(kind: kind, to: output, isEnd: isEnd, isLineStart: true)
        return output.length > 0 ? output : nil
    }

    private mutating func appendMidLineSpan(
        kind: MarkdownAttributedStringRenderer.CanonicalLineKind,
        to output: NSMutableAttributedString,
        isEnd: Bool,
        isLineStart: Bool = false
    ) {
        let ns = pending as NSString
        guard ns.length > 0 else { return }
        let forced = isEnd || ns.length > maxHoldUTF16
        let safeEnd = forced
            ? ns.length
            : StreamingInlineSpanScanner.safeBoundary(in: pending)
        guard safeEnd > 0 else { return }
        let span = ns.substring(to: safeEnd)
        output.append(MarkdownAttributedStringRenderer.renderCommittedSpan(
            kind: kind, span: span, isLineStart: isLineStart
        ))
        pending = ns.substring(from: safeEnd)
    }

    private func appendGroup(_ group: String, to output: NSMutableAttributedString) {
        let body = group.hasSuffix("\n") ? String(group.dropLast()) : group
        if !body.isEmpty {
            output.append(MarkdownAttributedStringRenderer.renderPreservingBoundaries(body))
        }
        output.append(MarkdownAttributedStringRenderer.canonicalLineSeparator())
    }


    static func lineStartKind(
        of line: String,
        forced: Bool
    ) -> MarkdownAttributedStringRenderer.CanonicalLineKind? {
        if forced { return MarkdownAttributedStringRenderer.canonicalLineKind(line) }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count < ambiguityWindow, trimmed.allSatisfy(isBlockMarkerCandidate) { return nil }
        if let first = trimmed.first,
           first == "-" || first == "*" || first == "_",
           trimmed.count >= 2, trimmed.allSatisfy({ $0 == first }) { return nil }
        if trimmed.contains("|") || trimmed.hasPrefix("$$") { return nil }
        return MarkdownAttributedStringRenderer.canonicalLineKind(line)
    }

    static func safeGroupEnd(_ ns: NSString, lastNewline: Int, forced: Bool) -> Int {
        let end = lastNewline + 1
        if forced { return end }

        var lines: [String] = []
        var cursor = 0
        while cursor < end {
            let nl = ns.range(of: "\n", range: NSRange(location: cursor, length: end - cursor))
            let stop = nl.location == NSNotFound ? end : nl.location
            lines.append(ns.substring(with: NSRange(location: cursor, length: stop - cursor)))
            cursor = stop + 1
        }
        guard !lines.isEmpty else { return end }

        var keep = lines.count
        while keep > 0 {
            if isInsideOpenBlockMath(lines, upTo: keep) { keep -= 1; continue }
            if lines[keep - 1].trimmingCharacters(in: .whitespaces).contains("|") {
                keep -= 1
                continue
            }
            break
        }
        guard keep > 0 else { return 0 }
        guard keep < lines.count else { return end }

        var offset = 0
        for i in 0..<keep { offset += (lines[i] as NSString).length + 1 }
        return offset
    }

    private static func isInsideOpenBlockMath(_ lines: [String], upTo count: Int) -> Bool {
        var open = false
        for i in 0..<count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if open {
                if trimmed.hasSuffix("$$") { open = false }
                continue
            }
            guard trimmed.hasPrefix("$$") else { continue }
            if !(trimmed.count >= 4 && trimmed.hasSuffix("$$")) { open = true }
        }
        return open
    }

    private static func isBlockMarkerCandidate(_ c: Character) -> Bool {
        "#>-*_$|`~+ \t".contains(c)
    }
}
