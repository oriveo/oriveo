import Foundation

// Pure functions for memory-write intent classification and candidates (source of truth: algorithm 1-14 in `shared/context-contracts/memory-intent.v1.json`).
// Pure functions only: no storage, no cloud. All directive primitives are reused from DirectiveDetector; everything works on arrays of Unicode code points,
// and String.contains / hasPrefix is not used (Character semantics compare by canonical equivalence and would differ from the other platforms).

// MARK: - Candidate record and transition result (fields = fixture candidate; times are epoch milliseconds)

public enum MemoryCandidateStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case pending
    case accepted
    case rejected
    case superseded
    case expired
}

public struct MemoryCandidateSource: Codable, Hashable, Sendable {
    public var type: MemorySourceType
    public var conversationId: String?
    public var messageIds: [String]
    public var observedAtMs: Int64?

    public init(type: MemorySourceType, conversationId: String?, messageIds: [String], observedAtMs: Int64?) {
        self.type = type
        self.conversationId = conversationId
        self.messageIds = messageIds
        self.observedAtMs = observedAtMs
    }

    private enum CodingKeys: String, CodingKey {
        case type, conversationId, messageIds, observedAtMs
    }

    /// null is written as null, with the same key order as the fixture.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(conversationId, forKey: .conversationId)
        try container.encode(messageIds, forKey: .messageIds)
        try container.encode(observedAtMs, forKey: .observedAtMs)
    }
}

/// Candidate record. pending carries the body and source; accepted / rejected clear the body and source and keep only the fingerprint for short-term dedup.
public struct MemoryCandidate: Codable, Hashable, Sendable {
    public var id: String
    public var status: MemoryCandidateStatus
    public var proposedLayer: MemoryLayer
    public var proposedKind: MemoryKind
    public var content: String
    public var scope: MemoryScope
    public var source: MemoryCandidateSource
    public var sensitivity: MemorySensitivity
    public var confidence: Double
    public var fingerprint: String
    public var createdAtMs: Int64
    public var expiresAtMs: Int64
    public var resolvedAtMs: Int64?

    private enum CodingKeys: String, CodingKey {
        case id, status, proposedLayer, proposedKind, content, scope, source, sensitivity, confidence, fingerprint, createdAtMs, expiresAtMs, resolvedAtMs
    }

    /// null is written as null, with the same key order as the fixture.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(status, forKey: .status)
        try container.encode(proposedLayer, forKey: .proposedLayer)
        try container.encode(proposedKind, forKey: .proposedKind)
        try container.encode(content, forKey: .content)
        try container.encode(scope, forKey: .scope)
        try container.encode(source, forKey: .source)
        try container.encode(sensitivity, forKey: .sensitivity)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encode(createdAtMs, forKey: .createdAtMs)
        try container.encode(expiresAtMs, forKey: .expiresAtMs)
        try container.encode(resolvedAtMs, forKey: .resolvedAtMs)
    }
}

/// Item draft produced by accept: the client creates a new Memory Item through the normal creation path, and the candidate itself never becomes an item.
public struct MemoryItemDraft: Codable, Hashable, Sendable {
    public var layer: MemoryLayer
    public var kind: MemoryKind
    public var status: MemoryStatus
    public var content: String
    public var scope: MemoryScope
    public var source: MemoryCandidateSource
    public var sensitivity: MemorySensitivity
    public var confidence: Double
}

/// The user's edits at accept time; fields that are nil keep the record's original values.
public struct MemoryCandidateEdit: Codable, Hashable, Sendable {
    public var content: String?
    public var kind: MemoryKind?
    public var scope: MemoryScope?

    public init(content: String? = nil, kind: MemoryKind? = nil, scope: MemoryScope? = nil) {
        self.content = content
        self.kind = kind
        self.scope = scope
    }
}

public struct MemoryCandidateContext: Codable, Hashable, Sendable {
    public var conversationId: String
    public var folderId: String?
    public var messageId: String
    public var nowMs: Int64
    public var activeContents: [String]
    public var records: [MemoryCandidate]
    /// Auto-suggest switch (after rule 11): when off it blocks only implicit candidates and an explicit "remember" works as usual; a fixture default counts as on.
    public var autoSuggest: Bool

    private enum CodingKeys: String, CodingKey {
        case conversationId, folderId, messageId, nowMs, activeContents, records, autoSuggest
    }

    public init(
        conversationId: String,
        folderId: String?,
        messageId: String,
        nowMs: Int64,
        activeContents: [String],
        records: [MemoryCandidate],
        autoSuggest: Bool = true
    ) {
        self.conversationId = conversationId
        self.folderId = folderId
        self.messageId = messageId
        self.nowMs = nowMs
        self.activeContents = activeContents
        self.records = records
        self.autoSuggest = autoSuggest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversationId = try container.decode(String.self, forKey: .conversationId)
        folderId = try container.decodeIfPresent(String.self, forKey: .folderId)
        messageId = try container.decode(String.self, forKey: .messageId)
        nowMs = try container.decode(Int64.self, forKey: .nowMs)
        activeContents = try container.decode([String].self, forKey: .activeContents)
        records = try container.decode([MemoryCandidate].self, forKey: .records)
        autoSuggest = try container.decodeIfPresent(Bool.self, forKey: .autoSuggest) ?? true
    }
}

public enum MemoryCandidateAction: String, Codable, Hashable, Sendable {
    case create
    case skip
}

public enum MemoryCandidateSkipReason: String, Codable, Hashable, Sendable, CaseIterable {
    case noSuggestion = "no_suggestion"
    case duplicateActive = "duplicate_active"
    case exists
    case duplicatePending = "duplicate_pending"
    case rejectedRecently = "rejected_recently"
    case autoSuggestOff = "auto_suggest_off"
}

public struct MemoryCandidateDecision: Codable, Hashable, Sendable {
    public var action: MemoryCandidateAction
    public var reason: MemoryCandidateSkipReason?
    public var candidate: MemoryCandidate?

    private enum CodingKeys: String, CodingKey {
        case action, reason, candidate
    }

    /// null is written as null, with the same key order as the fixture.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encode(reason, forKey: .reason)
        try container.encode(candidate, forKey: .candidate)
    }
}

public enum MemoryCandidateTransitionError: String, Codable, Hashable, Sendable, CaseIterable {
    case notPending = "not_pending"
    case expired
    case empty
    case tooLong = "too_long"
}

/// accept -> {record, item}; reject -> {record}; failure -> {error}. When encoding, nil fields do not write their key (same as the fixture).
public struct MemoryCandidateTransition: Codable, Hashable, Sendable {
    public var record: MemoryCandidate?
    public var item: MemoryItemDraft?
    public var error: MemoryCandidateTransitionError?
}

/// sweep result, with each list in input order; expired / superseded ones are also in purgedIds.
public struct MemoryCandidateSweep: Codable, Hashable, Sendable {
    public var keptIds: [String]
    public var expiredIds: [String]
    public var supersededIds: [String]
    public var purgedIds: [String]
}

// MARK: - Classification

public enum MemoryIntent {
    public enum Intent: String, Codable, Hashable, Sendable, CaseIterable {
        case explicitPersist = "explicit_persist"
        case implicitPersist = "implicit_persist"
        case transient
        case recall
        case deleteOrSupersede = "delete_or_supersede"
        case ackOrMeta = "ack_or_meta"
        case uncertain
        case none

        var persists: Bool { self == .explicitPersist || self == .implicitPersist }
    }

    public enum Rule: String, Codable, Hashable, Sendable, CaseIterable {
        case quoted, meta, question, recall, delete, supersede, transient, reminder, reminisce, anaphor, persist, directive
        case looseDirective = "loose_directive"
        case ack
        case anaphorDirective = "anaphor_directive"
    }

    public enum Scope: String, Codable, Hashable, Sendable, CaseIterable {
        case global, folder, conversation, unspecified
    }

    public enum Sensitive: String, Codable, Hashable, Sendable, CaseIterable {
        case none, secret, special
    }

    public enum Blocked: String, Codable, Hashable, Sendable, CaseIterable {
        case conversationScope = "conversation_scope"
        case secret
        case special
        case tooLong = "too_long"
    }

    public enum Suggestion: String, Codable, Hashable, Sendable, CaseIterable {
        case memory, conversationInstruction, none
    }

    /// proposition / kind / scope / blocked are non-nil only for explicit_persist / implicit_persist.
    public struct Classification: Codable, Hashable, Sendable {
        public var intent: Intent
        public var rule: Rule?
        public var span: String?
        public var proposition: String?
        public var kind: MemoryKind?
        public var scope: Scope?
        public var sensitive: Sensitive
        public var blocked: Blocked?
        public var suggestion: Suggestion

        private enum CodingKeys: String, CodingKey {
            case intent, rule, span, proposition, kind, scope, sensitive, blocked, suggestion
        }

        /// null is written as null, with the same key order as the fixture.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(intent, forKey: .intent)
            try container.encode(rule, forKey: .rule)
            try container.encode(span, forKey: .span)
            try container.encode(proposition, forKey: .proposition)
            try container.encode(kind, forKey: .kind)
            try container.encode(scope, forKey: .scope)
            try container.encode(sensitive, forKey: .sensitive)
            try container.encode(blocked, forKey: .blocked)
            try container.encode(suggestion, forKey: .suggestion)
        }
    }

    typealias Scalars = [UInt32]
    private typealias Detector = DirectiveDetector
    private typealias Forms = DirectiveDetector.SentenceForms
    private typealias Term = DirectiveDetector.Term

    // MARK: Rules 4, 7, 8, 9

    public static func classify(_ text: String) -> Classification {
        var best: Decided?
        for sentence in Detector.sentences(text) {
            guard let decided = decide(sentence) else { continue }
            if best == nil || decided.rank > best!.rank {
                best = decided
            }
        }
        let sensitive = sensitivity(text)
        guard let best else {
            return Classification(
                intent: .none, rule: nil, span: nil, proposition: nil, kind: nil, scope: nil,
                sensitive: sensitive, blocked: nil, suggestion: suggestion(text, intent: .none, blocked: nil, sensitive: sensitive)
            )
        }
        var proposition: String?
        var kind: MemoryKind?
        var scope: Scope?
        var blocked: Blocked?
        if best.intent.persists, let value = best.proposition {
            proposition = Detector.string(value)
            kind = best.kind
            scope = best.scope
            if best.scope == .conversation {
                blocked = .conversationScope
            } else if sensitive == .secret {
                blocked = .secret
            } else if sensitive == .special {
                blocked = .special
            } else if value.count > MemoryIntentLexicon.contentMaxCodePoints {
                blocked = .tooLong
            }
        }
        return Classification(
            intent: best.intent, rule: best.rule, span: Detector.string(best.span), proposition: proposition,
            kind: kind, scope: scope, sensitive: sensitive, blocked: blocked,
            suggestion: suggestion(text, intent: best.intent, blocked: blocked, sensitive: sensitive)
        )
    }

    private static func suggestion(_ text: String, intent: Intent, blocked: Blocked?, sensitive: Sensitive) -> Suggestion {
        if sensitive == .secret { return .none }
        if intent.persists, blocked == nil { return .memory }
        if Detector.detect(text).isDirective { return .conversationInstruction }
        return .none
    }

    private struct Decided {
        var intent: Intent
        var rule: Rule
        var span: Scalars
        var proposition: Scalars?
        var kind: MemoryKind?
        var scope: Scope?

        var rank: Int {
            switch intent {
            case .deleteOrSupersede: return 80
            case .explicitPersist: return 70
            case .implicitPersist: return scope == .conversation ? 60 : 65
            case .uncertain: return 50
            case .recall: return 40
            case .transient: return 30
            case .ackOrMeta: return 20
            case .none: return 0
            }
        }
    }

    /// Rule 4 steps (a)-(m): the first matching step decides the sentence; if none match, returns nil (the sentence does not count).
    private static func decide(_ sentence: DirectiveDetector.Sentence) -> Decided? {
        let span = sentence.span
        let masked = sentence.masked
        let original = Forms(span)
        let code = Forms(codeMask(masked))
        func result(_ intent: Intent, _ rule: Rule) -> Decided {
            Decided(intent: intent, rule: rule, span: span)
        }
        func implicit(global: Bool, rule: Rule) -> Decided {
            let scope: Scope = global ? .global : has(code, \.folderMarkers) ? .folder : .conversation
            return Decided(intent: .implicitPersist, rule: rule, span: span, proposition: span, kind: .instruction, scope: scope)
        }

        if has(original, \.memoryWords), !has(code, \.memoryWords) { return result(.ackOrMeta, .quoted) }
        if has(code, \.memoryWords), has(code, \.metaTerms) { return result(.ackOrMeta, .meta) }
        if Detector.isQuestion(masked) {
            if (has(code, \.memoryWords) && has(code, \.recallAddressees)) || has(code, \.recallTerms) {
                return result(.recall, .question)
            }
            return nil
        }
        if has(code, \.recallTerms) { return result(.recall, .recall) }
        if hasExcept(code, \.deleteTerms, \.deleteExceptions) { return result(.deleteOrSupersede, .delete) }
        if has(code, \.supersedeTerms) { return result(.deleteOrSupersede, .supersede) }
        if hasExcept(code, \.transientTerms, \.transientExceptions) { return result(.transient, .transient) }
        if head(code, .reminderStarts) {
            let detection = Detector.detect(Detector.string(span))
            if detection.isDirective {
                return implicit(global: detection.scope == .global, rule: .directive)
            }
            return result(.transient, .reminder)
        }
        if head(code, .persistStarts), !head(code, .ackTerms) {
            let value = proposition(span)
            if !value.isEmpty, head(Forms(value), .reminisceStarts) { return result(.ackOrMeta, .reminisce) }
            if anaphorOnly(value) { return result(.uncertain, .anaphor) }
            let scope: Scope = Detector.matchesAny(code, \.globalMarkers) ? .global
                : has(code, \.folderMarkers) ? .folder
                : has(code, \.conversationMarkers) ? .conversation
                : .unspecified
            return Decided(intent: .explicitPersist, rule: .persist, span: span, proposition: value, kind: kindOf(value), scope: scope)
        }
        let detection = Detector.detect(Detector.string(span))
        if detection.isDirective { return implicit(global: detection.scope == .global, rule: .directive) }
        if has(code, \.implicitMarkers), dirHas(code, \.verbs), !dirHas(code, \.vetoes), !has(code, \.ackTerms) {
            return implicit(global: Detector.matchesAny(code, \.globalMarkers), rule: .looseDirective)
        }
        if has(code, \.ackTerms) { return result(.ackOrMeta, .ack) }
        if has(code, \.uncertainMarkers), has(code, \.anaphorDirective) { return result(.uncertain, .anaphorDirective) }
        return nil
    }

    /// Rule 8: the original text within the scan range (not masked).
    private static func sensitivity(_ text: String) -> Sensitive {
        let scanned = Array(text.unicodeScalars.prefix(DirectiveLexicon.maxScanCodePoints).map(\.value))
        let forms = Forms(scanned)
        if has(forms, \.secretTerms) || matchesSecretPattern(Detector.string(scanned)) { return .secret }
        if has(forms, \.specialTerms) { return .special }
        return .none
    }

    private static func matchesSecretPattern(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for (pattern, regex) in secretRegexes {
            for match in regex.matches(in: text, range: range) {
                guard pattern.luhn else { return true }
                guard let matched = Range(match.range, in: text) else { continue }
                let digits = text[matched].unicodeScalars.compactMap { (0x30...0x39).contains($0.value) ? Int($0.value - 0x30) : nil }
                if passesLuhn(digits) { return true }
            }
        }
        return false
    }

    private static func passesLuhn(_ digits: [Int]) -> Bool {
        guard !digits.isEmpty else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    private static let secretRegexes: [(MemoryIntentLexicon.SecretPattern, NSRegularExpression)] =
        MemoryIntentLexicon.secretPatterns.map { pattern in
            // The lexicon is generated and covered by contract tests, so a compile failure means the generator is broken.
            (pattern, try! NSRegularExpression(pattern: pattern.regex))
        }

    // MARK: Rules 5, 6

    /// Rule 5: strip leading filler / polite words, persistStarts opening words and connectives from the span.
    static func proposition(_ span: Scalars) -> Scalars {
        let folded = span.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
        var index = 0
        func skipSeparators() {
            while index < folded.count, isSeparator(folded[index]) { index += 1 }
        }
        func longest(_ terms: [RawTerm]) -> Int? {
            terms.compactMap { $0.matchLength(folded, at: index) }.max()
        }
        while true {
            skipSeparators()
            if longest(persistStartTerms) != nil { break }
            guard let length = longest(leadingTerms) else { return Detector.trim(span) }
            index += length
        }
        index += longest(persistStartTerms) ?? 0
        while true {
            skipSeparators()
            guard let length = longest(linkerTerms) else { break }
            index += length
        }
        return Detector.trim(Array(span[index...]))
    }

    /// Rule 6: only anaphors remain (or nothing).
    private static func anaphorOnly(_ value: Scalars) -> Bool {
        var trimmed = Detector.trim(value)
        while let last = trimmed.last, isSeparator(last) { trimmed.removeLast() }
        if trimmed.isEmpty { return true }
        let normTrimmed = Detector.norm(Detector.string(trimmed))
        let core = Detector.words(Detector.norm(Detector.string(value)))
        return languages.contains { language in
            switch language.mode {
            case .substring:
                return language.anaphorOnly.contains { $0.norm == normTrimmed }
            case .word, .prefix:
                return language.anaphorOnly.contains { Array($0.leadingWord.dropFirst()) == core }
            }
        }
    }

    private static func kindOf(_ value: Scalars) -> MemoryKind {
        let forms = Forms(value)
        if Detector.detect(Detector.string(value)).isDirective
            || directivePrimary.contains(where: { Detector.passesStarts(forms, $0) }) {
            return .instruction
        }
        let order: [(MemoryKind, HeadKey)] = [
            (.project, .kindProject), (.goal, .kindGoal), (.preference, .kindPreference), (.identity, .kindIdentity),
        ]
        return order.first { head(forms, $0.1) }?.0 ?? .fact
    }

    // MARK: Matching for rules 1-3

    /// has(s, key): any language of this contract's lexicon matches according to its mode.
    private static func has(_ forms: Forms, _ table: KeyPath<PreparedLanguage, [Term]>) -> Bool {
        languages.contains { Detector.matches(forms, $0[keyPath: table], mode: $0.mode) }
    }

    /// dirHas(s, key): the zh-Hans and en languages of the directive lexicon.
    private static func dirHas(_ forms: Forms, _ table: KeyPath<DirectiveDetector.PreparedLanguage, [Term]>) -> Bool {
        directivePrimary.contains { Detector.matches(forms, $0[keyPath: table], mode: $0.mode) }
    }

    /// head(s, key): the opening-word check of rule 9; fillers use that language's directive fillers, and the opening words are swapped for this contract's key table.
    private static func head(_ forms: Forms, _ key: HeadKey) -> Bool {
        languages.contains { language in
            language.heads[key].map { Detector.passesStarts(forms, $0) } ?? false
        }
    }

    /// Rule 2: first replace exception words with a single space, then look for lexicon terms.
    private static func hasExcept(
        _ forms: Forms,
        _ table: KeyPath<PreparedLanguage, [Term]>,
        _ exceptions: KeyPath<PreparedLanguage, [Term]>
    ) -> Bool {
        languages.contains { language in
            switch language.mode {
            case .substring:
                var text = forms.norm
                for exception in language[keyPath: exceptions] where !exception.norm.isEmpty {
                    text = replacingAll(text, exception.norm)
                }
                return language[keyPath: table].contains { !$0.norm.isEmpty && Detector.find(text, $0.norm, from: 0) != nil }
            case .word, .prefix:
                var text = forms.wordform
                for exception in language[keyPath: exceptions] {
                    let needle = exception.paddedWord
                    while let start = Detector.find(text, needle, from: 0) {
                        text.replaceSubrange(start..<(start + needle.count), with: [0x20])
                    }
                }
                return language[keyPath: table].contains { Detector.find(text, $0.paddedWord, from: 0) != nil }
            }
        }
    }

    /// Replaces every occurrence of needle, left to right and without overlap, with a single space.
    private static func replacingAll(_ text: Scalars, _ needle: Scalars) -> Scalars {
        var result: Scalars = []
        result.reserveCapacity(text.count)
        var index = 0
        while index < text.count {
            if index + needle.count <= text.count, Array(text[index..<(index + needle.count)]) == needle {
                result.append(0x20)
                index += needle.count
            } else {
                result.append(text[index])
                index += 1
            }
        }
        return result
    }

    /// Rule 3: if a maximal run of U+0021..U+007E looks like code, the whole run is replaced with spaces (length unchanged).
    static func codeMask(_ masked: Scalars) -> Scalars {
        var result = masked
        var start = 0
        while start < masked.count {
            guard isPrintableASCII(masked[start]) else {
                start += 1
                continue
            }
            var end = start
            while end < masked.count, isPrintableASCII(masked[end]) { end += 1 }
            if isCode(masked[start..<end]) {
                for index in start..<end { result[index] = 0x20 }
            }
            start = end
        }
        return result
    }

    private static func isCode(_ run: ArraySlice<UInt32>) -> Bool {
        let values = Array(run)
        for (offset, value) in values.enumerated() {
            if codeTokenChars.contains(value) { return true }
            let next = offset + 1 < values.count ? values[offset + 1] : nil
            if isASCIILower(value), let next, isASCIIUpper(next) { return true }
            if isASCIILetter(value) || isASCIIDigit(value), next == 0x2E,
               offset + 2 < values.count, isASCIILetter(values[offset + 2]) {
                return true
            }
        }
        return false
    }

    private static func isPrintableASCII(_ value: UInt32) -> Bool { (0x21...0x7E).contains(value) }
    private static func isASCIILower(_ value: UInt32) -> Bool { (0x61...0x7A).contains(value) }
    private static func isASCIIUpper(_ value: UInt32) -> Bool { (0x41...0x5A).contains(value) }
    private static func isASCIILetter(_ value: UInt32) -> Bool { isASCIILower(value) || isASCIIUpper(value) }
    private static func isASCIIDigit(_ value: UInt32) -> Bool { (0x30...0x39).contains(value) }

    private static func isSeparator(_ value: UInt32) -> Bool {
        Detector.isWhiteSpace(value) || separators.contains(value)
    }

    private static let codeTokenChars = Set(MemoryIntentLexicon.codeTokenChars.unicodeScalars.map(\.value))
    private static let separators = Set(MemoryIntentLexicon.separators.unicodeScalars.map(\.value))

    // MARK: Lexicon preprocessing

    private enum HeadKey: CaseIterable {
        case reminderStarts, persistStarts, ackTerms, reminisceStarts
        case kindProject, kindGoal, kindPreference, kindIdentity

        func terms(_ language: MemoryIntentLexicon.Language) -> [String] {
            switch self {
            case .reminderStarts: return language.reminderStarts
            case .persistStarts: return language.persistStarts
            case .ackTerms: return language.ackTerms
            case .reminisceStarts: return language.reminisceStarts
            case .kindProject: return language.kindProject
            case .kindGoal: return language.kindGoal
            case .kindPreference: return language.kindPreference
            case .kindIdentity: return language.kindIdentity
            }
        }
    }

    private struct PreparedLanguage {
        let mode: DirectiveLexicon.Mode
        let memoryWords: [Term]
        let metaTerms: [Term]
        let recallAddressees: [Term]
        let recallTerms: [Term]
        let deleteTerms: [Term]
        let deleteExceptions: [Term]
        let supersedeTerms: [Term]
        let transientTerms: [Term]
        let transientExceptions: [Term]
        let anaphorOnly: [Term]
        let anaphorDirective: [Term]
        let uncertainMarkers: [Term]
        let implicitMarkers: [Term]
        let folderMarkers: [Term]
        let conversationMarkers: [Term]
        let ackTerms: [Term]
        let secretTerms: [Term]
        let specialTerms: [Term]
        /// Used by head(s, key): directive fillers + this contract's key table as starts.
        let heads: [HeadKey: DirectiveDetector.PreparedLanguage]

        init(_ source: MemoryIntentLexicon.Language) {
            mode = source.mode
            memoryWords = source.memoryWords.map(Term.init)
            metaTerms = source.metaTerms.map(Term.init)
            recallAddressees = source.recallAddressees.map(Term.init)
            recallTerms = source.recallTerms.map(Term.init)
            deleteTerms = source.deleteTerms.map(Term.init)
            deleteExceptions = source.deleteExceptions.map(Term.init)
            supersedeTerms = source.supersedeTerms.map(Term.init)
            transientTerms = source.transientTerms.map(Term.init)
            transientExceptions = source.transientExceptions.map(Term.init)
            anaphorOnly = source.anaphorOnly.map(Term.init)
            anaphorDirective = source.anaphorDirective.map(Term.init)
            uncertainMarkers = source.uncertainMarkers.map(Term.init)
            implicitMarkers = source.implicitMarkers.map(Term.init)
            folderMarkers = source.folderMarkers.map(Term.init)
            conversationMarkers = source.conversationMarkers.map(Term.init)
            ackTerms = source.ackTerms.map(Term.init)
            secretTerms = source.secretTerms.map(Term.init)
            specialTerms = source.specialTerms.map(Term.init)
            let fillers = directiveLanguage(source.code)?.fillers ?? []
            var heads: [HeadKey: DirectiveDetector.PreparedLanguage] = [:]
            for key in HeadKey.allCases {
                heads[key] = DirectiveDetector.PreparedLanguage(DirectiveLexicon.Language(
                    code: source.code, mode: source.mode, markers: [], verbs: [], starts: key.terms(source),
                    vetoes: [], fillers: fillers, questionParticlesAtEnd: [], languageWords: [], formatWords: [],
                    styleWords: [], imageStyleWords: [], globalMarkers: []
                ))
            }
            self.heads = heads
        }
    }

    /// Verbatim terms for rule 5 (compared with ASCII case folding only); word-mode terms require that the next code point is not L / N / M.
    private struct RawTerm {
        let scalars: Scalars
        let wordMode: Bool

        func matchLength(_ text: Scalars, at start: Int) -> Int? {
            guard !scalars.isEmpty, start + scalars.count <= text.count else { return nil }
            for offset in scalars.indices where text[start + offset] != scalars[offset] {
                return nil
            }
            let next = start + scalars.count
            if wordMode, next < text.count, Detector.isWordScalar(text[next]) { return nil }
            return scalars.count
        }
    }

    private static func rawTerms(_ terms: [String], mode: DirectiveLexicon.Mode) -> [RawTerm] {
        terms.map { RawTerm(scalars: $0.unicodeScalars.map(\.value), wordMode: mode != .substring) }
    }

    private static func directiveLanguage(_ code: String) -> DirectiveLexicon.Language? {
        DirectiveLexicon.languages.first { $0.code == code }
    }

    private static let languages: [PreparedLanguage] = MemoryIntentLexicon.languages.map(PreparedLanguage.init)

    /// The zh-Hans and en languages of the directive lexicon (used by dirHas and the instruction check of kindOf).
    private static let directivePrimary: [DirectiveDetector.PreparedLanguage] = ["zh-Hans", "en"].compactMap { code in
        DirectiveLexicon.languages.firstIndex { $0.code == code }.map { DirectiveDetector.lexicon[$0] }
    }

    private static let persistStartTerms: [RawTerm] = MemoryIntentLexicon.languages.flatMap {
        rawTerms($0.persistStarts, mode: $0.mode)
    }

    /// What phase one of rule 5 may remove: the directive fillers and politePrefixes of zh-Hans and en.
    private static let leadingTerms: [RawTerm] = ["zh-Hans", "en"].flatMap { code -> [RawTerm] in
        let fillers = directiveLanguage(code).map { rawTerms($0.fillers, mode: $0.mode) } ?? []
        let polite = MemoryIntentLexicon.languages.first { $0.code == code }.map { rawTerms($0.politePrefixes, mode: $0.mode) } ?? []
        return fillers + polite
    }

    private static let linkerTerms: [RawTerm] = MemoryIntentLexicon.languages.flatMap {
        rawTerms($0.linkers, mode: $0.mode)
    }

    // MARK: - Fingerprint (rule 10)

    /// norm(content), with runs of White_Space merged into one space and whitespace trimmed at both ends.
    public static func canonical(_ content: String) -> String {
        var result: Scalars = []
        var pendingSpace = false
        for value in Detector.norm(content) {
            if Detector.isWhiteSpace(value) {
                pendingSpace = !result.isEmpty
            } else {
                if pendingSpace { result.append(0x20) }
                pendingSpace = false
                result.append(value)
            }
        }
        return Detector.string(result)
    }

    public static func fingerprint(_ content: String) -> String {
        MemoryItems.sha256Hex(canonical(content))
    }

    // MARK: - Candidates (rules 11-14)

    public static func makeCandidate(_ classification: Classification, context: MemoryCandidateContext) -> MemoryCandidateDecision {
        guard classification.suggestion == .memory,
              classification.intent.persists,
              let proposition = classification.proposition,
              let kind = classification.kind,
              let scope = classification.scope else {
            return skip(.noSuggestion)
        }
        // Auto-suggest off: implicit candidates are no longer generated, while an explicit "remember" is unaffected.
        if !context.autoSuggest, classification.intent == .implicitPersist {
            return skip(.autoSuggestOff)
        }
        let fingerprint = fingerprint(proposition)
        if context.activeContents.contains(where: { self.fingerprint($0) == fingerprint }) {
            return skip(.duplicateActive)
        }
        let id = MemoryItems.uuidV5(context.messageId + "\n" + fingerprint)
        for record in context.records {
            if record.id == id { return skip(.exists) }
            if record.fingerprint == fingerprint {
                if record.status == .pending { return skip(.duplicatePending) }
                if record.status == .rejected, context.nowMs < record.expiresAtMs { return skip(.rejectedRecently) }
            }
        }
        let folder = context.folderId.map { MemoryScope(type: .folder, id: $0) }
        let candidateScope: MemoryScope
        switch scope {
        case .global:
            candidateScope = .global
        case .folder:
            candidateScope = folder ?? MemoryScope(type: .conversation, id: context.conversationId)
        case .unspecified:
            candidateScope = folder ?? .global
        case .conversation:
            // classify always blocks the conversation scope, so it never reaches here.
            candidateScope = MemoryScope(type: .conversation, id: context.conversationId)
        }
        let candidate = MemoryCandidate(
            id: id,
            status: .pending,
            proposedLayer: kind.layer,
            proposedKind: kind,
            content: proposition,
            scope: candidateScope,
            source: MemoryCandidateSource(
                type: .conversation, conversationId: context.conversationId,
                messageIds: [context.messageId], observedAtMs: context.nowMs
            ),
            sensitivity: .normal,
            confidence: classification.intent == .explicitPersist
                ? MemoryIntentLexicon.confidenceExplicit
                : MemoryIntentLexicon.confidenceImplicit,
            fingerprint: fingerprint,
            createdAtMs: context.nowMs,
            expiresAtMs: context.nowMs + MemoryIntentLexicon.candidateTtlMs,
            resolvedAtMs: nil
        )
        return MemoryCandidateDecision(action: .create, reason: nil, candidate: candidate)
    }

    private static func skip(_ reason: MemoryCandidateSkipReason) -> MemoryCandidateDecision {
        MemoryCandidateDecision(action: .skip, reason: reason, candidate: nil)
    }

    public static func accept(_ record: MemoryCandidate, edit: MemoryCandidateEdit?, nowMs: Int64) -> MemoryCandidateTransition {
        guard record.status == .pending else { return failure(.notPending) }
        guard nowMs < record.expiresAtMs else { return failure(.expired) }
        let content: Scalars = edit?.content.map { Detector.trim($0.unicodeScalars.map(\.value)) }
            ?? record.content.unicodeScalars.map(\.value)
        if content.isEmpty { return failure(.empty) }
        if content.count > MemoryIntentLexicon.contentMaxCodePoints { return failure(.tooLong) }
        let unchanged = content == record.content.unicodeScalars.map(\.value)
        // The layer is decided by the final kind (memory-propose.v2 rule 4): when the user changes the kind, the layer follows.
        let kind = edit?.kind ?? record.proposedKind
        let item = MemoryItemDraft(
            layer: kind.layer,
            kind: kind,
            status: .active,
            content: Detector.string(content),
            scope: edit?.scope ?? record.scope,
            source: record.source,
            sensitivity: record.sensitivity,
            confidence: unchanged ? record.confidence : 1
        )
        return MemoryCandidateTransition(
            record: cleared(record, status: .accepted, nowMs: nowMs, expiresAtMs: record.expiresAtMs),
            item: item,
            error: nil
        )
    }

    public static func reject(_ record: MemoryCandidate, nowMs: Int64) -> MemoryCandidateTransition {
        guard record.status == .pending else { return failure(.notPending) }
        return MemoryCandidateTransition(
            record: cleared(record, status: .rejected, nowMs: nowMs, expiresAtMs: nowMs + MemoryIntentLexicon.candidateTtlMs),
            item: nil,
            error: nil
        )
    }

    public static func sweep(_ records: [MemoryCandidate], activeContents: [String], nowMs: Int64) -> MemoryCandidateSweep {
        let active = Set(activeContents.map(fingerprint))
        var result = MemoryCandidateSweep(keptIds: [], expiredIds: [], supersededIds: [], purgedIds: [])
        for record in records {
            switch record.status {
            case .pending where nowMs >= record.expiresAtMs:
                result.expiredIds.append(record.id)
                result.purgedIds.append(record.id)
            case .pending where active.contains(record.fingerprint):
                result.supersededIds.append(record.id)
                result.purgedIds.append(record.id)
            case .pending:
                result.keptIds.append(record.id)
            case .rejected where nowMs < record.expiresAtMs:
                result.keptIds.append(record.id)
            default:
                result.purgedIds.append(record.id)
            }
        }
        return result
    }

    private static func failure(_ error: MemoryCandidateTransitionError) -> MemoryCandidateTransition {
        MemoryCandidateTransition(record: nil, item: nil, error: error)
    }

    /// Clears the body and source, keeping only the fingerprint.
    private static func cleared(_ record: MemoryCandidate, status: MemoryCandidateStatus, nowMs: Int64, expiresAtMs: Int64) -> MemoryCandidate {
        var result = record
        result.status = status
        result.content = ""
        result.source = MemoryCandidateSource(type: .conversation, conversationId: nil, messageIds: [], observedAtMs: nil)
        result.resolvedAtMs = nowMs
        result.expiresAtMs = expiresAtMs
        return result
    }
}
