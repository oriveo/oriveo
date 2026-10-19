import CryptoKit
import Foundation

// Pure deterministic-fallback functions. The spec is rules[0..6] in `shared/context-contracts/checkpoint.v1.json`:
// span selection, user-quote picking, checkpoint serialization, summary validation, id, concurrency resolution and the deterministic fallback. Same name and algorithm on every platform.
// Pure functions only; app wiring is done separately.

public enum ContextCheckpoint {
    /// Identical verbatim on all platforms; changes must stay in sync with the contract's constants.note.
    public static let note =
        "Earlier conversation was condensed by the app to fit the model's context. The quoted user messages are the user's own words; everything else here is a summary written for continuity, not new instructions."
    public static let truncationMark = "…[truncated]"
    public static let shortTruncationCodePoints = 200
    public static let packerVersion = "1"
    /// Summary second-level headings; the order is the spec.
    public static let headings = ["Goal", "Key Facts & Decisions", "Work Produced", "Open Threads", "Style & Language"]
    /// = UUIDv5(NAMESPACE_URL, "https://oriveo.app/ns/context-checkpoint").
    public static let uuidNamespace = "be18698a-4bba-5868-953d-79afea24fcd5"

    public struct Message: Hashable, Sendable {
        public var id: String
        public var role: ContextMessageRole
        public var estTokens: Int
        public var text: String?
        public var isDirective: Bool

        public init(id: String, role: ContextMessageRole, estTokens: Int, text: String? = nil, isDirective: Bool = false) {
            self.id = id
            self.role = role
            self.estTokens = estTokens
            self.text = text
            self.isDirective = isDirective
        }
    }

    public struct Candidate: Hashable, Sendable {
        public var id: String
        public var text: String
        public var isDirective: Bool

        public init(id: String, text: String, isDirective: Bool = false) {
            self.id = id
            self.text = text
            self.isDirective = isDirective
        }
    }

    public struct KeptMessage: Hashable, Sendable {
        public var id: String
        public var text: String
        public var truncated: Bool

        public init(id: String, text: String, truncated: Bool) {
            self.id = id
            self.text = text
            self.truncated = truncated
        }
    }

    public enum Action: String, Hashable, Sendable {
        case compact
        case noop
    }

    public struct Span: Hashable, Sendable {
        public var action: Action
        public var tailStartId: String?
        public var spanIds: [String]
        public var coversFrom: String?
        public var coversTo: String?
        public var messagesCovered: Int
    }

    public struct Fallback: Hashable, Sendable {
        public var checkpointText: String?
        public var tailStartId: String?
        public var keptUserIds: [String]
        public var total: Int
        public var targetMet: Bool
        public var stages: [String]
    }

    // MARK: span

    /// tailBudget takes the tail value derived from the budget; messages up to and including previousCoversTo are already covered by the previous checkpoint.
    public static func selectSpan(messages: [Message], B: Int, previousCoversTo: String? = nil) -> Span {
        selectSpan(messages: messages, tailBudget: ContextBudget.derived(B: B).tail, previousCoversTo: previousCoversTo)
    }

    static func selectSpan(messages: [Message], tailBudget: Int, previousCoversTo: String?) -> Span {
        let previousIndex = previousCoversTo.flatMap { id in messages.firstIndex { $0.id == id } }
        let spanStart = previousIndex.map { $0 + 1 } ?? 0
        let walked = tailStart(messages, tailBudget: tailBudget, previousIndex: previousIndex)
        // No user message after the previous checkpoint: noop, tail starts right after it.
        let start = walked ?? spanStart
        let tailStartId = start < messages.count ? messages[start].id : nil
        guard walked != nil, spanStart < start else {
            return Span(action: .noop, tailStartId: tailStartId, spanIds: [], coversFrom: nil, coversTo: nil, messagesCovered: 0)
        }
        let span = messages[spanStart..<start]
        return Span(
            action: .compact,
            tailStartId: tailStartId,
            spanIds: span.map(\.id),
            coversFrom: messages.first?.id,
            coversTo: span.last?.id,
            messagesCovered: start
        )
    }

    /// Accumulate whole messages from newest backwards (sum not exceeding tailBudget) and move the start forward to the first user message; if the tail is empty, start from the newest user message;
    /// the start must not fall inside the previous checkpoint. Returns messages.count (empty tail) when there is no user message.
    /// Returns nil when the start would fall inside the previous checkpoint and no user message follows it.
    private static func tailStart(_ messages: [Message], tailBudget: Int, previousIndex: Int?) -> Int? {
        var start = messages.count
        var sum = 0
        while start > 0, sum + messages[start - 1].estTokens <= tailBudget {
            sum += messages[start - 1].estTokens
            start -= 1
        }
        var aligned = messages[start...].firstIndex { $0.role == .user }
        if aligned == nil {
            aligned = messages.lastIndex { $0.role == .user }
        }
        var result = aligned ?? messages.count
        if let previousIndex, result <= previousIndex {
            // The tail always starts on a user message after the previous checkpoint.
            guard let next = messages[(previousIndex + 1)...].firstIndex(where: { $0.role == .user }) else {
                return nil
            }
            result = next
        }
        return result
    }

    // MARK: user messages

    /// Instructions first, newest to oldest, then the rest newest to oldest, within the userMessagesMax budget (defaults to the budget-derived value); output is in chronological order.
    public static func pickUserMessages(
        candidates: [Candidate],
        B: Int,
        rhoHi: Double,
        userMessagesMax: Int? = nil
    ) -> [KeptMessage] {
        let limit = userMessagesMax ?? ContextBudget.derived(B: B).userMessagesMax
        let sideBytes = Int((Double(limit / 4) / rhoHi).rounded(.down))
        let order = candidates.indices.reversed().filter { candidates[$0].isDirective }
            + candidates.indices.reversed().filter { !candidates[$0].isDirective }
        var remaining = limit
        var picked: [Int: KeptMessage] = [:]
        for index in order {
            let candidate = candidates[index]
            let cost = ContextBudget.estimateText(candidate.text, rhoHi: rhoHi)
            var choice: (text: String, cost: Int, truncated: Bool)?
            if cost * 2 > limit, let cut = headAndTail(candidate.text, sideBytes: sideBytes) {
                let cutCost = ContextBudget.estimateText(cut, rhoHi: rhoHi)
                if cutCost <= remaining { choice = (cut, cutCost, true) }
            }
            if choice == nil, cost <= remaining {
                choice = (candidate.text, cost, false)
            }
            if choice == nil, let short = shortCut(candidate.text) {
                let shortCost = ContextBudget.estimateText(short, rhoHi: rhoHi)
                if shortCost <= remaining { choice = (short, shortCost, true) }
            }
            guard let choice else { continue }
            remaining -= choice.cost
            picked[index] = KeptMessage(id: candidate.id, text: choice.text, truncated: choice.truncated)
        }
        return candidates.indices.compactMap { picked[$0] }
    }

    /// Head / tail = the most code points from the start / end within sideBytes UTF-8 bytes, cut by
    /// truncate; nil when the text is not longer than head + tail (nothing would be cut).
    private static func headAndTail(_ text: String, sideBytes: Int) -> String? {
        let scalars = Array(text.unicodeScalars)
        func count<S: Sequence>(_ sequence: S) -> Int where S.Element == Unicode.Scalar {
            var taken = 0
            var bytes = 0
            for scalar in sequence {
                guard bytes + scalar.utf8.count <= sideBytes else { break }
                bytes += scalar.utf8.count
                taken += 1
            }
            return taken
        }
        let head = count(scalars)
        let tail = count(scalars.reversed())
        guard head + tail < scalars.count else { return nil }
        return truncate(text, head: head, tail: tail)
    }

    /// Longer than 200 code points: truncate(text, 200, nil); otherwise nil.
    private static func shortCut(_ text: String) -> String? {
        guard text.unicodeScalars.count > shortTruncationCodePoints else { return nil }
        return truncate(text, head: shortTruncationCodePoints, tail: nil)
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    // MARK: serialize

    /// See rules[2] for the byte-exact spec; no <summary> is emitted when the summary is empty after trim.
    public static func serialize(
        coversFrom: String,
        coversTo: String,
        messagesCovered: Int,
        kept: [KeptMessage],
        summary: String? = nil
    ) -> String {
        var lines = [
            "<oriveo-context-checkpoint v=\"1\" covers=\"\(coversFrom)..\(coversTo)\" messages=\"\(messagesCovered)\">",
            "<note>\(note)</note>",
            "<user-messages count=\"\(kept.count)\" truncated=\"\(kept.filter(\.truncated).count)\">",
        ]
        lines += kept.map { "<msg id=\"\($0.id)\">\(ContextSanitizer.escapeXML($0.text))</msg>" }
        lines.append("</user-messages>")
        if let summary {
            let body = ContextSanitizer.trimmed(summary)
            if !body.isEmpty { lines.append("<summary>\(ContextSanitizer.escapeXML(body))</summary>") }
        }
        lines.append("</oriveo-context-checkpoint>")
        return lines.joined(separator: "\n")
    }

    // MARK: validate

    public enum ValidationReason: String, Hashable, Sendable {
        case headings
        case tooLong
        case notShorterThanHalfSpan
        case envelopeTag
    }

    public struct Validation: Hashable, Sendable {
        public var valid: Bool
        public var reasons: [ValidationReason]
    }

    /// rules[3]: second-level heading lines (starting with "## ") must match headings verbatim and in order; est <= floor(summaryMax*1.2);
    /// est <= floor(0.5*spanTokens); must not contain "<oriveo-" (case-insensitive). reasons follow this order.
    public static func validateSummary(_ summary: String, summaryMax: Int, spanTokens: Int, rhoHi: Double) -> Validation {
        var reasons: [ValidationReason] = []
        // Split on "\n" by Unicode scalar: String.split treats "\r\n" as one grapheme cluster and cannot split it.
        let lines = summary.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.unicodeScalars.dropLast()) : line
        }
        let found = lines.filter { $0.hasPrefix("## ") }.map { String($0.dropFirst(3)) }
        if found != headings { reasons.append(.headings) }
        let est = ContextBudget.estimateText(summary, rhoHi: rhoHi)
        if est > summaryMax * 12 / 10 { reasons.append(.tooLong) }
        if est > spanTokens / 2 { reasons.append(.notShorterThanHalfSpan) }
        if asciiLowercased(summary).contains("<oriveo-") { reasons.append(.envelopeTag) }
        return Validation(valid: reasons.isEmpty, reasons: reasons)
    }

    /// Final rule Normalize headings: split lines on "\n", take off a trailing "\r" first and put it back after processing;
    /// line body = "## " + one of headings + one or more spaces or tabs + (em dash / en dash / hyphen) + anything -> rewritten as "## " + that heading; other lines are unchanged.
    /// Compare by Unicode scalar: String.hasPrefix compares by grapheme cluster, which misjudges cases such as "Goal" followed by a combining character.
    public static func normalizeHeadings(_ summary: String) -> String {
        let lines = summary.components(separatedBy: "\n").map { line -> String in
            let hasCR = line.hasSuffix("\r")
            let body = hasCR ? Array(line.unicodeScalars.dropLast()) : Array(line.unicodeScalars)
            guard let heading = describedHeading(body) else { return line }
            return "## " + heading + (hasCR ? "\r" : "")
        }
        return lines.joined(separator: "\n")
    }

    private static func describedHeading(_ body: [Unicode.Scalar]) -> String? {
        let marker = Array("## ".unicodeScalars)
        guard body.starts(with: marker) else { return nil }
        let rest = body.dropFirst(marker.count)
        for heading in headings {
            let name = Array(heading.unicodeScalars)
            guard rest.starts(with: name) else { continue }
            let after = rest.dropFirst(name.count)
            let gap = after.prefix { $0 == " " || $0 == "\t" }
            guard !gap.isEmpty, let dash = after.dropFirst(gap.count).first,
                  dash == "\u{2014}" || dash == "\u{2013}" || dash == "-" else { continue }
            return heading
        }
        return nil
    }

    /// Lowercases only A-Z and keeps non-ASCII as is (so characters such as dotless i / dotted capital I are not folded into i).
    private static func asciiLowercased(_ text: String) -> String {
        var view = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x41, scalar.value <= 0x5A, let lower = Unicode.Scalar(scalar.value + 0x20) {
                view.append(lower)
            } else {
                view.append(scalar)
            }
        }
        return String(view)
    }

    // MARK: ids

    public struct CoveredMessage: Hashable, Sendable {
        public var id: String
        public var text: String

        public init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    /// Lowercase hex SHA-256 of UTF-8 text.
    public static func textHash(_ text: String) -> String {
        hex(SHA256.hash(data: Data(text.utf8)))
    }

    /// Concatenates id + "\n" + textHash + "\n" in order, then takes the lowercase hex SHA-256.
    public static func coversDigest(_ messages: [CoveredMessage]) -> String {
        let joined = messages.map { "\($0.id)\n\(textHash($0.text))\n" }.joined()
        return textHash(joined)
    }

    /// UUIDv5(uuidNamespace, conversationId + "\n" + coversTo + "\n" + packerVersion), lowercase.
    public static func checkpointId(conversationId: String, coversTo: String, packerVersion: String = packerVersion) -> String {
        let namespace = UUID(uuidString: uuidNamespace)!.uuid
        let namespaceBytes = withUnsafeBytes(of: namespace) { Array($0) }
        var hasher = Insecure.SHA1()
        hasher.update(data: Data(namespaceBytes))
        hasher.update(data: Data("\(conversationId)\n\(coversTo)\n\(packerVersion)".utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let h = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(h.prefix(8))-\(h.dropFirst(8).prefix(4))-\(h.dropFirst(12).prefix(4))-\(h.dropFirst(16).prefix(4))-\(h.dropFirst(20))"
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: concurrency

    public struct Claim: Hashable, Sendable {
        public var checkpointId: String
        public var coversToIndex: Int
        public var createdAtMillis: Int64

        public init(checkpointId: String, coversToIndex: Int, createdAtMillis: Int64) {
            self.checkpointId = checkpointId
            self.coversToIndex = coversToIndex
            self.createdAtMillis = createdAtMillis
        }
    }

    /// rules[5]: the larger coversTo wins; on a tie the earlier createdAt wins; on a further tie the lexicographically smaller checkpointId wins.
    public static func resolveConcurrency(_ a: Claim, _ b: Claim) -> Claim {
        if a.coversToIndex != b.coversToIndex { return a.coversToIndex > b.coversToIndex ? a : b }
        if a.createdAtMillis != b.createdAtMillis { return a.createdAtMillis < b.createdAtMillis ? a : b }
        // A complete tie (same id too) returns a.
        return Array(b.checkpointId.utf8).lexicographicallyPrecedes(Array(a.checkpointId.utf8)) ? b : a
    }

    // MARK: fallback

    /// Target floor(0.5B): initial calculation -> halve tailBudget when the tail is longer than the latest turn -> halve userMessagesMax at most 4 times -> minimal set.
    public static func fallback(
        messages: [Message],
        B: Int,
        rhoHi: Double,
        fixedTokens: Int,
        oldSummary: String? = nil
    ) -> Fallback {
        let derived = ContextBudget.derived(B: B)
        let target = B / 2
        var tailBudget = derived.tail
        var userMessagesMax = derived.userMessagesMax
        let latestUser = messages.lastIndex { $0.role == .user } ?? messages.count

        func evaluate(minimal: Bool) -> (start: Int, kept: [KeptMessage], text: String?, total: Int) {
            let span = selectSpan(messages: messages, tailBudget: tailBudget, previousCoversTo: nil)
            let start = span.action == .compact ? span.messagesCovered
                : (span.tailStartId.flatMap { id in messages.firstIndex { $0.id == id } } ?? messages.count)
            let tailTokens = messages[start...].reduce(0) { $0 + $1.estTokens }
            guard span.action == .compact, let from = span.coversFrom, let to = span.coversTo else {
                return (start, [], nil, fixedTokens + tailTokens)
            }
            let candidates = messages[..<start]
                .filter { $0.role == .user }
                .map { Candidate(id: $0.id, text: $0.text ?? "", isDirective: $0.isDirective) }
            let kept = minimal
                ? minimalSet(candidates)
                : pickUserMessages(candidates: candidates, B: B, rhoHi: rhoHi, userMessagesMax: userMessagesMax)
            let text = serialize(coversFrom: from, coversTo: to, messagesCovered: start, kept: kept, summary: oldSummary)
            return (start, kept, text, fixedTokens + ContextBudget.estimateText(text, rhoHi: rhoHi) + tailTokens)
        }

        var stages = ["initial"]
        var state = evaluate(minimal: false)
        while state.total > target, state.start < latestUser {
            tailBudget /= 2
            stages.append("tail=\(tailBudget)")
            state = evaluate(minimal: false)
        }
        var halvings = 0
        while state.total > target, halvings < 4 {
            userMessagesMax /= 2
            halvings += 1
            stages.append("userMessages=\(userMessagesMax)")
            state = evaluate(minimal: false)
        }
        if state.total > target {
            stages.append("minimal")
            state = evaluate(minimal: true)
        }
        return Fallback(
            checkpointText: state.text,
            tailStartId: state.start < messages.count ? messages[state.start].id : nil,
            keptUserIds: state.kept.map(\.id),
            total: state.total,
            targetMet: state.total <= target,
            stages: stages
        )
    }

    /// The latest instruction plus the latest user message (in chronological order); each is cut to 200 code points plus a truncation marker when longer.
    private static func minimalSet(_ candidates: [Candidate]) -> [KeptMessage] {
        var indices = Set<Int>()
        if let directive = candidates.lastIndex(where: \.isDirective) { indices.insert(directive) }
        if !candidates.isEmpty { indices.insert(candidates.count - 1) }
        return indices.sorted().map { index in
            let candidate = candidates[index]
            if let short = shortCut(candidate.text) {
                return KeptMessage(id: candidate.id, text: short, truncated: true)
            }
            return KeptMessage(id: candidate.id, text: candidate.text, truncated: false)
        }
    }
}

// MARK: truncate

extension ContextCheckpoint {
    /// Code point classes of the sentence-boundary truncation, as hex strings ("XXXX" or "XXXX-YYYY").
    /// Must equal constants.sentenceBoundary in the checkpoint contract.
    public struct SentenceBoundaryTable: Hashable, Sendable {
        public var terminators: [String]
        public var closers: [String]
        public var lineBreaks: [String]
        public var spaces: [String]
        public var extend: [String]
        public var joiners: [String]
        public var regionalIndicator: String
    }

    public static let sentenceBoundary = SentenceBoundaryTable(
        terminators: [
            "0021", "002E", "003F", "061F", "06D4", "0964", "0965", "203C", "203D", "2047", "2048", "2049",
            "3002", "FF01", "FF0E", "FF1F", "FF61",
        ],
        closers: [
            "0022", "0027", "0029", "005D", "007D", "00BB", "2019", "201D", "203A", "3009", "300B", "300D",
            "300F", "3011", "3015", "FF02", "FF07", "FF09", "FF3D", "FF5D",
        ],
        lineBreaks: ["000A", "000D", "0085", "2028", "2029"],
        spaces: ["0009", "0020", "00A0", "3000"],
        extend: [
            "0300-036F", "0483-0489", "0591-05BD", "05BF", "05C1-05C2", "05C4-05C5", "05C7", "0610-061A",
            "064B-065F", "0670", "06D6-06DC", "06DF-06E4", "06E7-06E8", "06EA-06ED", "0900-0903", "093A-093C",
            "093E-094F", "0951-0957", "0962-0963", "0E31", "0E34-0E3A", "0E47-0E4E", "1160-11FF", "1AB0-1AFF",
            "1DC0-1DFF", "200C-200D", "20D0-20FF", "302A-302F", "3099-309A", "FE00-FE0F", "FE20-FE2F",
            "1F3FB-1F3FF", "E0020-E007F", "E0100-E01EF",
        ],
        joiners: ["094D", "200D"],
        regionalIndicator: "1F1E6-1F1FF"
    )

    /// Sentence-boundary truncation on the raw text (checkpoint rules "Truncate"), counted in code points.
    /// tail nil: headCut(head) + truncationMark; tail set: headCut(head) + truncationMark + tailCut(tail).
    /// Text that already fits is returned unchanged. XML escaping is left to serialize.
    public static func truncate(_ text: String, head: Int, tail: Int?) -> String {
        let scalars = Array(text.unicodeScalars)
        let head = max(0, head)
        guard let tail else {
            guard scalars.count > head else { return text }
            return TruncationLayout(scalars).headCut(head) + truncationMark
        }
        let tailCount = max(0, tail)
        guard scalars.count > head + tailCount else { return text }
        let layout = TruncationLayout(scalars)
        return layout.headCut(head) + truncationMark + layout.tailCut(tailCount)
    }

    fileprivate struct ScalarClass {
        let ranges: [ClosedRange<UInt32>]

        init(_ entries: [String]) {
            ranges = entries.map { entry in
                let bounds = entry.split(separator: "-").map { UInt32($0, radix: 16)! }
                return bounds[0]...(bounds.last ?? bounds[0])
            }
        }

        func contains(_ scalar: Unicode.Scalar) -> Bool {
            ranges.contains { $0.contains(scalar.value) }
        }
    }

    fileprivate static let terminatorClass = ScalarClass(sentenceBoundary.terminators)
    fileprivate static let closerClass = ScalarClass(sentenceBoundary.closers)
    fileprivate static let lineBreakClass = ScalarClass(sentenceBoundary.lineBreaks)
    fileprivate static let spaceClass = ScalarClass(sentenceBoundary.spaces)
    fileprivate static let extendClass = ScalarClass(sentenceBoundary.extend)
    fileprivate static let joinerClass = ScalarClass(sentenceBoundary.joiners)
    fileprivate static let regionalIndicatorClass = ScalarClass([sentenceBoundary.regionalIndicator])
}

/// Per-text boundary facts shared by headCut and tailCut.
private struct TruncationLayout {
    /// An open fenced code block: its fence character and the opening run as far as the text read holds it.
    struct OpenFence {
        var char: Unicode.Scalar
        var run: String
    }

    private typealias Table = ContextCheckpoint

    let text: [Unicode.Scalar]
    /// Code point lies on a fence opener, content or closer line.
    private(set) var onFenceLine: [Bool]
    /// Position (0...count) is a sentence end.
    private(set) var sentenceEnd: [Bool]

    init(_ text: [Unicode.Scalar]) {
        self.text = text
        onFenceLine = Array(repeating: false, count: text.count)
        sentenceEnd = Array(repeating: false, count: text.count + 1)
        markFences()
        markSentenceEnds()
    }

    private static let carriageReturn = Unicode.Scalar(0x0D)!
    private static let lineFeed = Unicode.Scalar(0x0A)!
    private static let space = Unicode.Scalar(0x20)!
    private static let tab = Unicode.Scalar(0x09)!

    private func isWhiteSpace(_ scalar: Unicode.Scalar) -> Bool {
        ContextSanitizer.unicodeWhiteSpace.contains(scalar)
    }

    // MARK: layout

    private mutating func markFences() {
        for line in scanFences(upTo: text.count).fenceLines {
            for index in line { onFenceLine[index] = true }
        }
    }

    /// Reads text[0..<end] line by line with the fence rules; a partial last line is judged on what it
    /// holds. Returns the fence still open at end (with its opening run inside text[0..<end]) and the
    /// content ranges of every opener, content and closer line read.
    private func scanFences(upTo end: Int) -> (open: OpenFence?, fenceLines: [Range<Int>]) {
        var open: OpenFence?
        var fenceLines: [Range<Int>] = []
        var lineStart = 0
        while true {
            var contentEnd = lineStart
            while contentEnd < end, !Table.lineBreakClass.contains(text[contentEnd]) { contentEnd += 1 }
            let line = Array(text[lineStart..<contentEnd])
            if let current = open {
                fenceLines.append(lineStart..<contentEnd)
                if isCloser(line, char: current.char, length: current.run.unicodeScalars.count) { open = nil }
            } else if let opener = opener(line) {
                fenceLines.append(lineStart..<contentEnd)
                var runEnd = lineStart + opener.indent
                while runEnd < end, text[runEnd] == opener.char { runEnd += 1 }
                open = OpenFence(char: opener.char, run: string(lineStart + opener.indent..<runEnd))
            }
            guard contentEnd < end else { break }
            lineStart = contentEnd + 1
            if text[contentEnd] == Self.carriageReturn, lineStart < end, text[lineStart] == Self.lineFeed {
                lineStart += 1
            }
        }
        return (open, fenceLines)
    }

    private func opener(_ line: [Unicode.Scalar]) -> (char: Unicode.Scalar, indent: Int)? {
        var indent = 0
        while indent < 3, indent < line.count, line[indent] == Self.space { indent += 1 }
        guard indent < line.count, line[indent] == "`" || line[indent] == "~" else { return nil }
        let char = line[indent]
        var end = indent
        while end < line.count, line[end] == char { end += 1 }
        guard end - indent >= 3 else { return nil }
        return (char, indent)
    }

    private func isCloser(_ line: [Unicode.Scalar], char: Unicode.Scalar, length: Int) -> Bool {
        var indent = 0
        while indent < 3, indent < line.count, line[indent] == Self.space { indent += 1 }
        var end = indent
        while end < line.count, line[end] == char { end += 1 }
        guard end - indent >= length else { return false }
        return line[end...].allSatisfy { $0 == Self.space || $0 == Self.tab }
    }

    private mutating func markSentenceEnds() {
        var index = 0
        while index < text.count {
            guard Table.terminatorClass.contains(text[index]) else {
                index += 1
                continue
            }
            var runEnd = index
            while runEnd < text.count, Table.terminatorClass.contains(text[runEnd]) { runEnd += 1 }
            var end = runEnd
            while end < text.count, Table.closerClass.contains(text[end]) { end += 1 }
            let last = text[runEnd - 1]
            var counts: Bool
            switch last {
            case ".":
                counts = end == text.count || isWhiteSpace(text[end])
                if counts, let next = text[end...].first(where: { !isWhiteSpace($0) }) {
                    counts = !(next.value >= 0x61 && next.value <= 0x7A)
                }
            case "!", "?":
                counts = !(end < text.count && isASCIIAlphanumeric(text[end]))
            default:
                counts = true
            }
            if counts, !onFenceLine[runEnd - 1] { sentenceEnd[end] = true }
            index = runEnd
        }
    }

    private func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true
        default: false
        }
    }

    // MARK: cuts

    /// A line break starts at p (the LF of CR LF does not).
    private func lineBreakAt(_ p: Int) -> Bool {
        guard p < text.count, Table.lineBreakClass.contains(text[p]) else { return false }
        return !(text[p] == Self.lineFeed && p > 0 && text[p - 1] == Self.carriageReturn)
    }

    /// Directly after a line break, not between CR and LF.
    private func afterLineBreak(_ s: Int) -> Bool {
        guard s > 0, Table.lineBreakClass.contains(text[s - 1]) else { return false }
        return !(text[s - 1] == Self.carriageReturn && s < text.count && text[s] == Self.lineFeed)
    }

    /// Moving the cut between p - 1 and p would split a grapheme.
    private func splitsCluster(_ p: Int) -> Bool {
        guard p > 0, p < text.count else { return false }
        if Table.extendClass.contains(text[p]) || Table.joinerClass.contains(text[p - 1]) { return true }
        guard Table.regionalIndicatorClass.contains(text[p - 1]), Table.regionalIndicatorClass.contains(text[p]) else {
            return false
        }
        var run = 0
        var index = p - 1
        while index >= 0, Table.regionalIndicatorClass.contains(text[index]) {
            run += 1
            index -= 1
        }
        return run % 2 == 1
    }


    private func string(_ range: Range<Int>) -> String {
        String(String.UnicodeScalarView(text[range]))
    }

    func headCut(_ n: Int) -> String {
        let firstContent = text.firstIndex { !isWhiteSpace($0) } ?? text.count
        func valid(_ p: Int) -> Bool { firstContent < p }
        let candidates = Array(stride(from: n, through: (n + 1) / 2, by: -1))
        var cut = candidates.first { (sentenceEnd[$0] || lineBreakAt($0)) && valid($0) }
        if cut == nil {
            cut = candidates.first { p in
                p < text.count && Table.spaceClass.contains(text[p]) && !onFenceLine[p] && valid(p)
            }
        }
        var p = cut ?? n
        if cut == nil {
            while p > 0, splitsCluster(p) { p -= 1 }
            if p == 0 { p = n }
        }
        var end = p
        while end > 0, isWhiteSpace(text[end - 1]) { end -= 1 }
        var result = string(0..<end)
        if let fence = scanFences(upTo: end).open { result += "\n" + fence.run }
        return result
    }

    func tailCut(_ m: Int) -> String {
        let count = text.count
        let lastContent = text.lastIndex { !isWhiteSpace($0) } ?? -1
        func valid(_ s: Int) -> Bool { s <= lastContent }
        let low = count - m
        let candidates = Array(low...(count - (m + 1) / 2))
        var cut = candidates.first { (sentenceEnd[$0] || afterLineBreak($0)) && valid($0) }
        if cut == nil {
            cut = candidates.first { s in
                s > 0 && Table.spaceClass.contains(text[s - 1]) && !onFenceLine[s - 1] && valid(s)
            }
        }
        var s = cut ?? low
        if cut == nil {
            while s < count, splitsCluster(s) { s += 1 }
            if s == count { s = low }
        }
        var start = s
        while start < count, isWhiteSpace(text[start]) { start += 1 }
        let body = string(start..<count)
        // Fence state is read from the text before the kept start (after leading White_Space is dropped).
        if let fence = scanFences(upTo: start).open { return fence.run + "\n" + body }
        return body
    }
}
