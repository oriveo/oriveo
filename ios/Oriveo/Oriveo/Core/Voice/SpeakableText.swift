import Foundation

/// A speakable segment: a sentence or a block placeholder (code / table / formula).
nonisolated enum SpeakablePlaceholder: String, Sendable, Equatable {
    case code
    case table
    case math
}

nonisolated enum SpeakableSegment: Sendable, Equatable {
    case sentence(String)
    case placeholder(SpeakablePlaceholder)
}

/// Implements the rules of shared/voice-contracts/speakable-text.v1.json one by one.
/// All positions are Unicode code points (unicodeScalars), not UTF-16 units or grapheme clusters.
nonisolated enum SpeakableText {
    static let maxSentenceCodePoints = 200

    static let appLocales = [
        "ar", "de", "en", "es", "fr", "hi", "id", "ja", "ko", "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant",
    ]

    // MARK: - Entry points

    /// final=false means a streaming prefix: the last line is incomplete.
    static func segments(text: String, final: Bool) -> [SpeakableSegment] {
        var lines = splitLines(text)
        let openLine: [Unicode.Scalar]? = final ? nil : lines.removeLast()
        var state = BlockState()
        var raw: [SpeakableSegment] = []
        for line in lines { processLine(line, complete: true, state: &state, out: &raw) }
        if let openLine { processLine(openLine, complete: false, state: &state, out: &raw) }
        var out: [SpeakableSegment] = []
        for seg in raw {
            if case .placeholder(let kind) = seg, case .placeholder(let lastKind)? = out.last, lastKind == kind {
                continue
            }
            out.append(seg)
        }
        return out
    }

    /// Placeholder sentences use the reading language; the UI language is used only when the reading language is not one of the 16 app languages.
    static func placeholderLocale(reading: String?, ui: String?) -> String {
        appLocale(for: reading) ?? appLocale(for: ui) ?? "en"
    }

    /// BCP-47 → one of the 16 app languages; nil when nothing matches.
    static func appLocale(for tag: String?) -> String? {
        guard let tag, !tag.isEmpty else { return nil }
        let parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-", omittingEmptySubsequences: false)
        let lang = parts[0].lowercased()
        let rest = parts.dropFirst().map { $0.lowercased() }
        if lang == "zh" {
            if rest.contains("hant") || rest.contains(where: { ["tw", "hk", "mo"].contains($0) }) { return "zh-Hant" }
            return "zh-Hans"
        }
        if lang == "pt" { return "pt-BR" }
        if lang == "in" { return "id" }
        return appLocales.contains(lang) ? lang : nil
    }

    // MARK: - Character classes

    private typealias S = Unicode.Scalar

    private static func isWS(_ c: S) -> Bool {
        switch c.value {
        case 0x20, 0x09, 0x0B, 0x0C, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    /// JS `\s` (used for tag detection and trimming).
    private static func isJSSpace(_ c: S) -> Bool {
        switch c.value {
        case 0x0A, 0x0D, 0xFEFF: return true
        default: return isWS(c)
        }
    }

    private static func isRemoved(_ c: S) -> Bool {
        switch c.value {
        case 0x200B...0x200D, 0x2060, 0xFE0E...0xFE0F, 0x20E3,
             0x231A...0x231B, 0x23E9...0x23F3, 0x23F8...0x23FA, 0x25FD...0x25FE,
             0x2600...0x27BF, 0x2B1B...0x2B1C, 0x2B50, 0x2B55,
             0x1F000...0x1FAFF, 0xE0020...0xE007F:
            return true
        default:
            return false
        }
    }

    private static func isLetterOrNumber(_ c: S) -> Bool {
        switch c.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    private static func isMark(_ c: S) -> Bool {
        switch c.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    private static func isAsciiPunct(_ c: S) -> Bool {
        switch c.value {
        case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E: return true
        default: return false
        }
    }

    private static func isDigit(_ c: S) -> Bool { (0x30...0x39).contains(c.value) }

    private static func isAsciiLetter(_ c: S) -> Bool {
        (0x41...0x5A).contains(c.value) || (0x61...0x7A).contains(c.value)
    }

    private static func isSpaceOrTab(_ c: S) -> Bool { c == " " || c == "\t" }

    private static let weakTerminators: Set<S> = [".", "!", "?", ";"]
    private static let strongTerminators: Set<S> = ["。", "！", "？", "；", "｡", "؟", "۔", "؛", "।", "॥"]
    private static let closers: Set<S> = [
        "\"", "'", ")", "]", "}", "\u{201D}", "\u{2019}", "」", "』", "）", "】", "》", "〉", "»", "›", "〕", "〗", "］", "｝",
    ]
    private static let openers: Set<S> = ["(", "\"", "'", "\u{201C}", "\u{2018}", "「", "『", "（", "【", "《"]
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g", "i.e", "inc", "ltd", "co", "fig",
        "approx", "u.s", "a.m", "p.m",
    ]

    private static func isTerminator(_ c: S) -> Bool { weakTerminators.contains(c) || strongTerminators.contains(c) }

    // MARK: - Inline

    /// One item of u: a single code point or a formula placeholder.
    private enum Item: Equatable {
        case ch(S)
        case ph(SpeakablePlaceholder)

        var scalar: S? { if case .ch(let c) = self { return c } else { return nil } }
        var isPH: Bool { if case .ph = self { return true } else { return false } }
        var isWS: Bool { scalar.map(SpeakableText.isWS) ?? false }
    }

    private struct Pending: Error {}

    private struct BracketResult {
        var unmatched = false
        var labelFrom = 0
        var labelTo = 0
        var end = 0
        var link = false
    }

    private static func push(_ c: S, _ u: inout [Item]) {
        if isWS(c) {
            if u.isEmpty || u[u.count - 1].isWS { return }
            u.append(.ch(" "))
            return
        }
        if isRemoved(c) { return }
        u.append(.ch(c))
    }

    private static func pushString(_ s: String, _ u: inout [Item]) {
        for c in s.unicodeScalars { push(c, &u) }
    }

    /// Converts the code points of one line (block markers removed) into u. open=true means more text may arrive after `to`;
    /// a construct that needs text after `to` to resolve throws Pending, and the caller keeps only what was already written to u.
    private static func inline(_ cs: [S], _ from: Int, _ to: Int, _ open: Bool, _ u: inout [Item]) throws {
        func avail(_ k: Int) -> Bool { k < to }
        // nil = undecided (not enough characters while open)
        func startsWith(_ i: Int, _ s: String) -> Bool? {
            for (k, ch) in s.unicodeScalars.enumerated() {
                if !avail(i + k) { return open ? nil : false }
                if cs[i + k] != ch { return false }
            }
            return true
        }
        func runLength(_ i: Int, _ ch: S) throws -> Int {
            var j = i
            while avail(j) && cs[j] == ch { j += 1 }
            if !avail(j) && open { throw Pending() }
            return j - i
        }

        var i = from
        while i < to {
            let c = cs[i]

            if c == "\\" {
                if !avail(i + 1) {
                    if open { throw Pending() }
                    i += 1; continue
                }
                let n = cs[i + 1]
                if n == "(" || n == "[" {
                    let close: S = n == "(" ? ")" : "]"
                    var j = -1
                    var k = i + 2
                    while k + 1 < to {
                        if cs[k] == "\\" && cs[k + 1] == close { j = k; break }
                        k += 1
                    }
                    if j >= 0 { u.append(.ph(.math)); i = j + 2; continue }
                    if open { throw Pending() }
                    push(n, &u); i += 2; continue
                }
                if isAsciiPunct(n) { push(n, &u); i += 2; continue }
                push("\\", &u); i += 1; continue
            }

            if c == "`" {
                let run = try runLength(i, "`")
                var k = i + run
                var found = -1
                while k < to {
                    if cs[k] == "`" {
                        let r = try runLength(k, "`")
                        if r == run { found = k; break }
                        k += r
                    } else {
                        k += 1
                    }
                }
                if found >= 0 {
                    for q in (i + run)..<found { push(cs[q], &u) }
                    i = found + run; continue
                }
                if open { throw Pending() }
                i += run; continue
            }

            if c == "$" {
                if !avail(i + 1) {
                    if open { throw Pending() }
                    push("$", &u); i += 1; continue
                }
                if cs[i + 1] == "$" {
                    var j = -1
                    var k = i + 2
                    while k + 1 < to {
                        if cs[k] == "$" && cs[k + 1] == "$" { j = k; break }
                        k += 1
                    }
                    if j >= 0 { u.append(.ph(.math)); i = j + 2; continue }
                    if open { throw Pending() }
                    i += 2; continue
                }
                let n = cs[i + 1]
                if isWS(n) || isDigit(n) { push("$", &u); i += 1; continue }
                var j = -1
                var k = i + 2
                while k < to {
                    defer { k += 1 }
                    if cs[k] != "$" || isWS(cs[k - 1]) || cs[k - 1] == "\\" { continue }
                    if !avail(k + 1) {
                        if open { throw Pending() }
                        j = k; break
                    }
                    if !isDigit(cs[k + 1]) { j = k; break }
                }
                if j >= 0 { u.append(.ph(.math)); i = j + 1; continue }
                if open { throw Pending() }
                push("$", &u); i += 1; continue
            }

            if c == "!" {
                if !avail(i + 1) {
                    if open { throw Pending() }
                    push("!", &u); i += 1; continue
                }
                if cs[i + 1] == "[" {
                    let r = try parseBracket(cs, i + 1, to, open)
                    if r.link {
                        try inline(cs, r.labelFrom, r.labelTo, false, &u)
                        i = r.end; continue
                    }
                }
                push("!", &u); i += 1; continue
            }

            if c == "[" {
                let r = try parseBracket(cs, i, to, open)
                if r.unmatched { i += 1; continue }
                let label = Array(cs[r.labelFrom..<r.labelTo])
                if !isFootnoteLabel(label) && !isCitationLabel(label) {
                    try inline(cs, r.labelFrom, r.labelTo, false, &u)
                }
                i = r.end; continue
            }

            if c == "<" {
                if !avail(i + 1) {
                    if open { throw Pending() }
                    push("<", &u); i += 1; continue
                }
                let n = cs[i + 1]
                if isAsciiLetter(n) || n == "/" {
                    var gt = -1
                    var k = i + 1
                    while k < to {
                        if cs[k] == ">" { gt = k; break }
                        if cs[k] == "<" { break }
                        k += 1
                    }
                    if gt < 0 {
                        if open {
                            var sawLt = false
                            for k in (i + 1)..<to where cs[k] == "<" { sawLt = true }
                            if !sawLt { throw Pending() }
                        }
                        push("<", &u); i += 1; continue
                    }
                    let body = Array(cs[i...gt])
                    if let url = autolinkURL(body) { pushString(hostOf(url), &u); i = gt + 1; continue }
                    if let tagName = htmlTagName(body) {
                        if tagName.lowercased() == "br" { push(" ", &u) }
                        i = gt + 1; continue
                    }
                }
                push("<", &u); i += 1; continue
            }

            if c == "h" && (i == 0 || !isLetterOrNumber(cs[i - 1])) {
                let http = startsWith(i, "http://")
                let https = startsWith(i, "https://")
                if http != true && https != true && (http == nil || https == nil) { throw Pending() }
                if http == true || https == true {
                    var j = i
                    while j < to && (0x21...0x7E).contains(cs[j].value) && !"<>\"`".unicodeScalars.contains(cs[j]) {
                        j += 1
                    }
                    if j == to && open { throw Pending() }
                    var end = j
                    while end > i && ".,:;!?'\")]}*_~".unicodeScalars.contains(cs[end - 1]) { end -= 1 }
                    pushString(hostOf(String(String.UnicodeScalarView(cs[i..<end]))), &u)
                    i = end; continue
                }
            }

            if c == "*" || c == "_" || c == "~" {
                let run = try runLength(i, c)
                if c == "~" && run != 2 {
                    for _ in 0..<run { push("~", &u) }
                    i += run; continue
                }
                let prev: S = i > 0 ? cs[i - 1] : " "
                if !avail(i + run) && open { throw Pending() }
                let next: S = avail(i + run) ? cs[i + run] : " "
                let canOpen = !isWS(next) && (c != "_" || !isLetterOrNumber(prev))
                func canCloseAt(_ k: Int, _ r: Int) throws -> Bool {
                    let p = cs[k - 1]
                    if !avail(k + r) && open { throw Pending() }
                    let nx: S = avail(k + r) ? cs[k + r] : " "
                    return !isWS(p) && (c != "_" || !isLetterOrNumber(nx))
                }
                if canOpen {
                    var k = i + run
                    var found = -1
                    while k < to {
                        if cs[k] == c {
                            let r = try runLength(k, c)
                            if try r == run && canCloseAt(k, r) { found = k; break }
                            k += r
                        } else {
                            k += 1
                        }
                    }
                    if found >= 0 {
                        try inline(cs, i + run, found, false, &u)
                        i = found + run; continue
                    }
                    if open { throw Pending() }
                    i += run; continue
                }
                let canClose = !isWS(prev) && (c != "_" || !isLetterOrNumber(next))
                if canClose { i += run; continue }
                for _ in 0..<run { push(c, &u) }
                i += run; continue
            }

            push(c, &u)
            i += 1
        }
    }

    /// [label](url) / [label]: returns the label range and end position; while open, a missing closing bracket or next character is Pending.
    private static func parseBracket(_ cs: [S], _ i: Int, _ to: Int, _ open: Bool) throws -> BracketResult {
        var depth = 0
        var j = -1
        var k = i
        while k < to {
            if cs[k] == "\\" { k += 2; continue }
            if cs[k] == "[" {
                depth += 1
            } else if cs[k] == "]" {
                depth -= 1
                if depth == 0 { j = k; break }
            }
            k += 1
        }
        if j < 0 {
            if open { throw Pending() }
            return BracketResult(unmatched: true)
        }
        if j + 1 >= to {
            if open { throw Pending() }
            return BracketResult(labelFrom: i + 1, labelTo: j, end: j + 1, link: false)
        }
        if cs[j + 1] == "(" {
            var d = 0
            var k2 = -1
            var q = j + 1
            while q < to {
                if cs[q] == "(" {
                    d += 1
                } else if cs[q] == ")" {
                    d -= 1
                    if d == 0 { k2 = q; break }
                }
                q += 1
            }
            if k2 >= 0 { return BracketResult(labelFrom: i + 1, labelTo: j, end: k2 + 1, link: true) }
            if open { throw Pending() }
        }
        return BracketResult(labelFrom: i + 1, labelTo: j, end: j + 1, link: false)
    }

    /// /^\s*\^/
    private static func isFootnoteLabel(_ label: [S]) -> Bool {
        var k = 0
        while k < label.count && isJSSpace(label[k]) { k += 1 }
        return k < label.count && label[k] == "^"
    }

    /// /^\s*\d+(?:\s*[,\u{FF0C}\u{3001}\-–]\s*\d+)*\s*$/ (U+FF0C fullwidth comma, U+3001 ideographic comma)
    private static func isCitationLabel(_ label: [S]) -> Bool {
        var k = 0
        let n = label.count
        func skipSpaces() { while k < n && isJSSpace(label[k]) { k += 1 } }
        func digits() -> Bool {
            let start = k
            while k < n && isDigit(label[k]) { k += 1 }
            return k > start
        }
        skipSpaces()
        guard digits() else { return false }
        let separators: Set<S> = [",", "，", "、", "-", "–"]
        while true {
            skipSpaces()
            if k == n { return true }
            guard separators.contains(label[k]) else { return false }
            k += 1
            skipSpaces()
            guard digits() else { return false }
        }
    }

    /// /^<(https?:\/\/[^\s<>]*)>$/i: returns the URL inside the angle brackets.
    private static func autolinkURL(_ body: [S]) -> String? {
        guard body.count >= 2, body.first == "<", body.last == ">" else { return nil }
        let inner = Array(body[1..<(body.count - 1)])
        let innerString = String(String.UnicodeScalarView(inner))
        let lower = innerString.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        guard !inner.contains(where: { isJSSpace($0) || $0 == "<" || $0 == ">" }) else { return nil }
        return innerString
    }

    /// /^<\/?([A-Za-z][A-Za-z0-9-]*)(?:\s[^<>]*)?\/?>$/: returns the tag name.
    private static func htmlTagName(_ body: [S]) -> String? {
        guard body.count >= 3, body.first == "<", body.last == ">" else { return nil }
        let n = body.count - 1 // index of the trailing '>'
        var k = 1
        if body[k] == "/" { k += 1 }
        guard k < n, isAsciiLetter(body[k]) else { return nil }
        let nameStart = k
        while k < n && (isAsciiLetter(body[k]) || isDigit(body[k]) || body[k] == "-") { k += 1 }
        let name = String(String.UnicodeScalarView(body[nameStart..<k]))
        if k == n { return name }
        if body[k] == "/" && k + 1 == n { return name }
        if isJSSpace(body[k]) {
            // [^<>]* consumes the rest (body has no < > except at its ends)
            for q in (k + 1)..<n where body[q] == "<" || body[q] == ">" { return nil }
            return name
        }
        return nil
    }

    /// /^[A-Za-z]+:\/\/([^/?#:]*)/, then strips a leading www. (case-insensitive).
    private static func hostOf(_ url: String) -> String {
        let cs = Array(url.unicodeScalars)
        var k = 0
        while k < cs.count && isAsciiLetter(cs[k]) { k += 1 }
        guard k > 0, k + 2 < cs.count, cs[k] == ":", cs[k + 1] == "/", cs[k + 2] == "/" else { return "" }
        k += 3
        let start = k
        while k < cs.count && !"/?#:".unicodeScalars.contains(cs[k]) { k += 1 }
        var host = String(String.UnicodeScalarView(cs[start..<k]))
        if host.lowercased().hasPrefix("www.") { host = String(host.unicodeScalars.dropFirst(4)) }
        return host
    }

    // MARK: - Sentence splitting

    private enum Closure {
        case placeholder(Int)
        case closure(Int)
        case end(Int)
        case wait

        var index: Int? {
            switch self {
            case .placeholder(let c), .closure(let c), .end(let c): return c
            case .wait: return nil
            }
        }
    }

    private static func isAbbreviation(_ u: [Item], _ s: Int, _ i: Int) -> Bool {
        var k = i
        while k > s && !u[k - 1].isWS && !u[k - 1].isPH { k -= 1 }
        while k < i, let c = u[k].scalar, openers.contains(c) { k += 1 }
        let word = u[k..<i].compactMap(\.scalar)
        if word.count == 1 && isAsciiLetter(word[0]) { return true }
        let lowered = String(String.UnicodeScalarView(word.map { c -> S in
            (0x41...0x5A).contains(c.value) ? S(c.value + 0x20)! : c
        }))
        return abbreviations.contains(lowered)
    }

    private static func findClosure(_ u: [Item], _ s: Int, _ blockEnd: Bool) -> Closure {
        let n = u.count
        var i = s
        while i < n {
            let x = u[i]
            if x.isPH { return .placeholder(i) }
            if let xc = x.scalar, isTerminator(xc) {
                var j = i
                while j < n, let c = u[j].scalar, isTerminator(c) { j += 1 }
                if j == n && !blockEnd { return .wait }
                let run = u[i..<j].compactMap(\.scalar)
                if run.count >= 2 && run.allSatisfy({ $0 == "." }) { i = j; continue }
                let strong = run.contains { strongTerminators.contains($0) }
                if !strong && run.count == 1 && run[0] == "." && isAbbreviation(u, s, i) { i = j; continue }
                var k = j
                while k < n, let c = u[k].scalar, closers.contains(c) { k += 1 }
                if k == n { return blockEnd ? .closure(n) : .wait }
                if strong || u[k].isWS || u[k].isPH { return .closure(k) }
                i = j
                continue
            }
            i += 1
        }
        return blockEnd ? .end(n) : .wait
    }

    private static func emitSentence(_ out: inout [SpeakableSegment], _ items: ArraySlice<Item>) {
        // Collapse spaces; removing characters can leave "word + space + terminator", so drop that space; then trim
        var scalars: [S] = []
        for item in items {
            guard let c = item.scalar else { continue }
            if c == " ", scalars.last == " " { continue }
            if isTerminator(c), scalars.last == " " { scalars.removeLast() }
            scalars.append(c)
        }
        while let first = scalars.first, isJSSpace(first) { scalars.removeFirst() }
        while let last = scalars.last, isJSSpace(last) { scalars.removeLast() }
        guard scalars.contains(where: isLetterOrNumber) else { return }
        out.append(.sentence(String(String.UnicodeScalarView(scalars))))
    }

    private static func split(_ u: [Item], _ blockEnd: Bool, _ out: inout [SpeakableSegment]) {
        let n = u.count
        let limit = maxSentenceCodePoints
        var s = 0
        while true {
            while s < n && u[s].isWS { s += 1 }
            if s >= n { return }
            let r = findClosure(u, s, blockEnd)
            if let c = r.index, c - s <= limit {
                if c > s { emitSentence(&out, u[s..<c]) }
                if case .placeholder = r, case .ph(let kind) = u[c] {
                    out.append(.placeholder(kind))
                    s = c + 1
                    continue
                }
                if case .end = r { return }
                s = c
                continue
            }
            if n - s > limit {
                var q = -1
                var k = s + limit
                while k > s {
                    if u[k].isWS { q = k; break }
                    k -= 1
                }
                if q > 0 { emitSentence(&out, u[s..<q]); s = q; continue }
                var p = s + limit
                while p > s + 1, let c = u[p].scalar, isMark(c) { p -= 1 }
                emitSentence(&out, u[s..<p])
                s = p
                continue
            }
            return
        }
    }

    // MARK: - Blocks

    private struct BlockState {
        var fence: (ch: S, len: Int)?
        var math: [S]?
    }

    /// Normalizes CRLF and lone CR to LF, then splits on LF (line count = LF count + 1).
    private static func splitLines(_ text: String) -> [[S]] {
        var lines: [[S]] = []
        var current: [S] = []
        var pendingCR = false
        for c in text.unicodeScalars {
            if pendingCR {
                pendingCR = false
                if c == "\n" { continue }
            }
            if c == "\r" {
                lines.append(current); current = []
                pendingCR = true
            } else if c == "\n" {
                lines.append(current); current = []
            } else {
                current.append(c)
            }
        }
        lines.append(current)
        return lines
    }

    private static func leadingSpaceOrTab(_ line: [S], from: Int = 0) -> Int {
        var k = from
        while k < line.count && isSpaceOrTab(line[k]) { k += 1 }
        return k - from
    }

    private static func contains(_ line: [S], _ needle: [S]) -> Bool {
        guard needle.count <= line.count else { return false }
        for start in 0...(line.count - needle.count) where Array(line[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }

    /// JS `.` does not match line terminators; `(.*)$` requires the rest to contain no U+2028 / U+2029.
    private static func dotAllMatches(_ rest: ArraySlice<S>) -> Bool {
        !rest.contains { $0 == "\u{2028}" || $0 == "\u{2029}" }
    }

    /// Match length of /^[ \t]{0,3}>[ \t]?/.
    private static func quoteMarker(_ line: [S]) -> Int? {
        let ws = leadingSpaceOrTab(line)
        guard ws <= 3, ws < line.count, line[ws] == ">" else { return nil }
        var k = ws + 1
        if k < line.count && isSpaceOrTab(line[k]) { k += 1 }
        return k
    }

    /// /^[ \t]{0,3}(`{3,}|~{3,})(.*)$/
    private static func fenceOpen(_ line: [S]) -> (ch: S, len: Int, rest: ArraySlice<S>)? {
        let ws = leadingSpaceOrTab(line)
        guard ws <= 3, ws < line.count, line[ws] == "`" || line[ws] == "~" else { return nil }
        let ch = line[ws]
        var k = ws
        while k < line.count && line[k] == ch { k += 1 }
        let len = k - ws
        guard len >= 3 else { return nil }
        let rest = line[k...]
        guard dotAllMatches(rest) else { return nil }
        return (ch, len, rest)
    }

    /// /^[ \t]{0,3}F{n,}[ \t]*$/
    private static func fenceCloses(_ line: [S], ch: S, len: Int) -> Bool {
        let ws = leadingSpaceOrTab(line)
        guard ws <= 3 else { return false }
        var k = ws
        while k < line.count && line[k] == ch { k += 1 }
        guard k - ws >= len else { return false }
        return line[k...].allSatisfy(isSpaceOrTab)
    }

    /// /^[ \t]*(\$\$|\\\[)(.*)$/: returns the matching closer and the rest of the line.
    private static func displayMathOpen(_ line: [S]) -> (closer: [S], rest: ArraySlice<S>)? {
        let ws = leadingSpaceOrTab(line)
        guard ws + 1 < line.count else { return nil }
        let closer: [S]
        if line[ws] == "$" && line[ws + 1] == "$" {
            closer = ["$", "$"]
        } else if line[ws] == "\\" && line[ws + 1] == "[" {
            closer = ["\\", "]"]
        } else {
            return nil
        }
        let rest = line[(ws + 2)...]
        guard dotAllMatches(rest) else { return nil }
        return (closer, rest)
    }

    /// /^[ \t]{0,3}([-*_=])(?:[ \t]*\1){2,}[ \t]*$/
    private static func isThematicBreak(_ line: [S]) -> Bool {
        let ws = leadingSpaceOrTab(line)
        guard ws <= 3, ws < line.count else { return false }
        let ch = line[ws]
        guard ch == "-" || ch == "*" || ch == "_" || ch == "=" else { return false }
        var count = 0
        for c in line[ws...] {
            if c == ch { count += 1 } else if !isSpaceOrTab(c) { return false }
        }
        return count >= 3
    }

    /// Match length of /^[ \t]{0,3}#{1,6}(?:[ \t]+|$)/.
    private static func headingMarker(_ line: [S]) -> Int? {
        let ws = leadingSpaceOrTab(line)
        guard ws <= 3 else { return nil }
        var k = ws
        while k < line.count && line[k] == "#" { k += 1 }
        let hashes = k - ws
        guard (1...6).contains(hashes) else { return nil }
        if k == line.count { return k }
        guard isSpaceOrTab(line[k]) else { return nil }
        return k + leadingSpaceOrTab(line, from: k)
    }

    /// Strips /(?:^|[ \t]+)#+[ \t]*$/.
    private static func stripClosingHashes(_ content: [S]) -> [S] {
        var end = content.count
        while end > 0 && isSpaceOrTab(content[end - 1]) { end -= 1 }
        var k = end
        while k > 0 && content[k - 1] == "#" { k -= 1 }
        guard k < end else { return content }
        if k == 0 { return [] }
        guard isSpaceOrTab(content[k - 1]) else { return content }
        while k > 0 && isSpaceOrTab(content[k - 1]) { k -= 1 }
        return Array(content[..<k])
    }

    /// Match length of /^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?/.
    private static func listMarker(_ line: [S]) -> Int? {
        var k = leadingSpaceOrTab(line)
        guard k < line.count else { return nil }
        if line[k] == "-" || line[k] == "*" || line[k] == "+" {
            k += 1
        } else {
            let start = k
            while k < line.count && isDigit(line[k]) { k += 1 }
            guard (1...9).contains(k - start), k < line.count, line[k] == "." || line[k] == ")" else { return nil }
            k += 1
        }
        let gap = leadingSpaceOrTab(line, from: k)
        guard gap >= 1 else { return nil }
        k += gap
        if k + 2 < line.count, line[k] == "[", [" ", "x", "X"].contains(line[k + 1]), line[k + 2] == "]" {
            let after = leadingSpaceOrTab(line, from: k + 3)
            if after >= 1 { k += 3 + after }
        }
        return k
    }

    private static func processLine(
        _ raw: [S],
        complete: Bool,
        state: inout BlockState,
        out: inout [SpeakableSegment]
    ) {
        var line = raw
        while let m = quoteMarker(line) { line = Array(line[m...]) }

        if let fence = state.fence {
            if complete && fenceCloses(line, ch: fence.ch, len: fence.len) { state.fence = nil }
            return
        }
        if let closer = state.math {
            if complete && contains(line, closer) { state.math = nil }
            return
        }

        if let fence = fenceOpen(line), !(fence.ch == "`" && fence.rest.contains("`")) {
            guard complete else { return }
            out.append(.placeholder(.code))
            state.fence = (fence.ch, fence.len)
            return
        }
        if let math = displayMathOpen(line) {
            guard complete else { return }
            out.append(.placeholder(.math))
            if !contains(Array(math.rest), math.closer) { state.math = math.closer }
            return
        }
        let tableWS = leadingSpaceOrTab(line)
        if tableWS < line.count && line[tableWS] == "|" {
            if complete { out.append(.placeholder(.table)) }
            return
        }
        if isThematicBreak(line) { return }

        var content = line
        if let m = headingMarker(line) {
            content = Array(line[m...])
            if complete { content = stripClosingHashes(content) }
        } else if let m = listMarker(line) {
            content = Array(line[m...])
        }

        var u: [Item] = []
        var pending = false
        do {
            try inline(content, 0, content.count, !complete, &u)
        } catch {
            pending = true
        }
        split(u, complete && !pending, &out)
    }
}
