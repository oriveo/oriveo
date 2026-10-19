import Foundation

/// Persistent-directive detection result: when isDirective is false, span / kind / scope are all nil.
public struct DirectiveDetection: Sendable, Equatable {
    public enum Kind: String, Sendable { case language, format, style, other }
    public enum Scope: String, Sendable { case conversation, global }

    public var isDirective: Bool
    public var span: String?
    public var kind: Kind?
    public var scope: Scope?

    public init(isDirective: Bool, span: String? = nil, kind: Kind? = nil, scope: Scope? = nil) {
        self.isDirective = isDirective
        self.span = span
        self.kind = kind
        self.scope = scope
    }

    public static let none = DirectiveDetection(isDirective: false)
}

/// Persistent-directive detector (source of truth is the algorithm in `shared/context-contracts/directive-detector.v2.json`).
/// Pure function, changes nothing. It works throughout on arrays of Unicode code points: String.contains / hasPrefix is not used
/// (Character semantics compare by canonical equivalence and would differ from the other platforms).
public enum DirectiveDetector {
    typealias Scalars = [UInt32]

    public static func detect(_ text: String) -> DirectiveDetection {
        for sentence in sentences(text) where !isQuestion(sentence.masked) {
            let words = SentenceForms(sentence.masked)
            for language in lexicon where isDirective(words, language) {
                return DirectiveDetection(
                    isDirective: true,
                    span: string(sentence.span),
                    kind: kind(words),
                    scope: matchesAny(words, \.globalMarkers) ? .global : .conversation
                )
            }
        }
        return .none
    }

    /// Image style prefix: sentences whose kind is style and that hit imageStyleWords are joined in order with one space, with total length not exceeding
    /// imageStylePrefixMax code points; if the first sentence alone is too long, take its first imageStylePrefixMax code points and trim. Empty string if none.
    public static func imageStylePrefix(_ instructions: String) -> String {
        let limit = DirectiveLexicon.imageStylePrefixMax
        var kept: [Scalars] = []
        for sentence in sentences(instructions) where !isQuestion(sentence.masked) {
            let words = SentenceForms(sentence.masked)
            if kind(words) == .style, matchesAny(words, \.imageStyleWords) {
                kept.append(sentence.span)
            }
        }
        guard let first = kept.first else { return "" }
        if first.count > limit {
            return string(trim(Array(first.prefix(limit))))
        }
        var result = first
        for span in kept.dropFirst() {
            guard result.count + 1 + span.count <= limit else { break }
            result.append(0x20)
            result.append(contentsOf: span)
        }
        return string(result)
    }

    // MARK: Decision

    private static func isDirective(_ words: SentenceForms, _ language: PreparedLanguage) -> Bool {
        (matches(words, language.markers, mode: language.mode) || matches(words, language.globalMarkers, mode: language.mode))
            && matches(words, language.verbs, mode: language.mode)
            && !matches(words, language.vetoes, mode: language.mode)
            && passesStarts(words, language)
    }

    private static func kind(_ words: SentenceForms) -> DirectiveDetection.Kind {
        if matchesAny(words, \.languageWords) { return .language }
        if matchesAny(words, \.formatWords) { return .format }
        if matchesAny(words, \.styleWords) || matchesAny(words, \.imageStyleWords) { return .style }
        return .other
    }

    static func matchesAny(_ words: SentenceForms, _ table: KeyPath<PreparedLanguage, [Term]>) -> Bool {
        lexicon.contains { matches(words, $0[keyPath: table], mode: $0.mode) }
    }

    static func matches(_ words: SentenceForms, _ terms: [Term], mode: DirectiveLexicon.Mode) -> Bool {
        terms.contains { term in
            switch mode {
            case .substring:
                return words.normContains(term.norm)
            case .word:
                return words.wordformContains(term.paddedWord)
            case .prefix:
                return words.wordformContains(term.leadingWord)
            }
        }
    }

    static func passesStarts(_ words: SentenceForms, _ language: PreparedLanguage) -> Bool {
        switch language.mode {
        case .substring:
            var head = trim(words.norm)
            var dropped = true
            while dropped {
                dropped = false
                for filler in language.fillers where !filler.norm.isEmpty && hasPrefix(head, filler.norm) {
                    head = trim(Array(head[filler.norm.count...]))
                    dropped = true
                    break
                }
            }
            return language.starts.contains { !$0.norm.isEmpty && hasPrefix(head, $0.norm) }
        case .word, .prefix:
            var head = words.wordform
            var dropped = true
            while dropped {
                dropped = false
                for filler in language.fillers where hasPrefix(head, filler.paddedWord) {
                    head = [0x20] + Array(head[filler.paddedWord.count...])
                    dropped = true
                    break
                }
            }
            return language.starts.contains {
                hasPrefix(head, language.mode == .word ? $0.paddedWord : $0.leadingWord)
            }
        }
    }

    static func isQuestion(_ masked: Scalars) -> Bool {
        var text = trim(masked)
        if let last = text.last, questionEnders.contains(last) { return true }
        if let first = text.first, questionStarters.contains(first) { return true }
        while let last = text.last, questionTrailers.contains(last) {
            text.removeLast()
        }
        text = trim(text)
        let words = SentenceForms(text)
        return lexicon.contains { language in
            language.questionParticlesAtEnd.contains { particle in
                switch language.mode {
                case .substring:
                    return !particle.norm.isEmpty && hasSuffix(words.norm, particle.norm)
                case .word, .prefix:
                    return hasSuffix(words.wordform, particle.paddedWord)
                }
            }
        }
    }

    // MARK: Masking and sentence splitting

    struct Sentence {
        var masked: Scalars
        var span: Scalars
    }

    static func sentences(_ text: String) -> [Sentence] {
        let original = Array(text.unicodeScalars.prefix(DirectiveLexicon.maxScanCodePoints).map(\.value))
        let masked = mask(original)
        var result: [Sentence] = []
        var start = 0
        func cut(_ end: Int) {
            guard end > start else { return }
            let span = trim(Array(original[start..<end]))
            if !span.isEmpty {
                result.append(Sentence(masked: Array(masked[start..<end]), span: span))
            }
            start = end
        }
        for index in masked.indices {
            let value = masked[index]
            if value == newline || sentenceEnders.contains(value) {
                cut(index + 1)
            } else if value == 0x2E, index + 1 == masked.count || isWhiteSpace(masked[index + 1]) {
                cut(index + 1)
            }
        }
        cut(masked.count)
        return result
    }

    static func mask(_ text: Scalars) -> Scalars {
        var masked = text
        let fence: Scalars = [0x60, 0x60, 0x60]
        func blank(_ range: Range<Int>) {
            for index in range where masked[index] != newline {
                masked[index] = 0x20
            }
        }
        var index = 0
        while index < text.count {
            if hasPrefix(text, fence, at: index) {
                let end = find(text, fence, from: index + 3).map { $0 + 3 } ?? text.count
                blank(index..<end)
                index = end
                continue
            }
            let value = text[index]
            let closer: UInt32? = value == 0x60 ? 0x60 : quotePairs.first { $0.opener == value }?.closer
            if let closer, let end = text[(index + 1)...].firstIndex(of: closer) {
                blank(index..<(end + 1))
                index = end + 1
                continue
            }
            index += 1
        }
        return masked
    }

    // MARK: Normalization

    /// One sentence's norm() and wordform() with a space on each side. The lexicon has thousands of entries searched as substrings, and comparing position by position on long sentences (up to 4000 code points) is too slow,
    /// so a position index is built by first code point and comparison happens only at positions sharing the first code point.
    final class SentenceForms {
        let norm: Scalars
        let wordform: Scalars
        private lazy var normIndex = DirectiveDetector.positions(norm)
        private lazy var wordformIndex = DirectiveDetector.positions(wordform)

        init(_ text: Scalars) {
            norm = DirectiveDetector.norm(DirectiveDetector.string(text))
            wordform = [0x20] + DirectiveDetector.words(norm) + [0x20]
        }

        func normContains(_ needle: Scalars) -> Bool {
            DirectiveDetector.contains(norm, needle, index: normIndex)
        }

        func wordformContains(_ needle: Scalars) -> Bool {
            DirectiveDetector.contains(wordform, needle, index: wordformIndex)
        }
    }

    static func positions(_ text: Scalars) -> [UInt32: [Int]] {
        var index: [UInt32: [Int]] = [:]
        for (offset, value) in text.enumerated() {
            index[value, default: []].append(offset)
        }
        return index
    }

    /// An empty string never counts as a hit (empty lexicon entries do not take part in matching in the contract).
    static func contains(_ text: Scalars, _ needle: Scalars, index: [UInt32: [Int]]) -> Bool {
        guard let first = needle.first, let starts = index[first] else { return false }
        return starts.contains { hasPrefix(text, needle, at: $0) }
    }

    struct Term {
        let norm: Scalars
        /// ' ' + wordform(term) + ' '
        let paddedWord: Scalars
        /// ' ' + wordform(term)
        let leadingWord: Scalars

        init(_ text: String) {
            norm = DirectiveDetector.norm(text)
            let word = DirectiveDetector.words(norm)
            leadingWord = [0x20] + word
            paddedWord = leadingWord + [0x20]
        }
    }

    struct PreparedLanguage {
        let mode: DirectiveLexicon.Mode
        let markers: [Term]
        let globalMarkers: [Term]
        let verbs: [Term]
        let starts: [Term]
        let vetoes: [Term]
        let fillers: [Term]
        let questionParticlesAtEnd: [Term]
        let languageWords: [Term]
        let formatWords: [Term]
        let styleWords: [Term]
        let imageStyleWords: [Term]

        init(_ source: DirectiveLexicon.Language) {
            mode = source.mode
            markers = source.markers.map(Term.init)
            globalMarkers = source.globalMarkers.map(Term.init)
            verbs = source.verbs.map(Term.init)
            starts = source.starts.map(Term.init)
            vetoes = source.vetoes.map(Term.init)
            fillers = source.fillers.map(Term.init)
            questionParticlesAtEnd = source.questionParticlesAtEnd.map(Term.init)
            languageWords = source.languageWords.map(Term.init)
            formatWords = source.formatWords.map(Term.init)
            styleWords = source.styleWords.map(Term.init)
            imageStyleWords = source.imageStyleWords.map(Term.init)
        }
    }

    static let lexicon: [PreparedLanguage] = DirectiveLexicon.languages.map(PreparedLanguage.init)

    /// NFKC -> lowercase the whole string (Unicode default, no locale) -> delete Arabic diacritics / tatweel / U+0307 per code point and merge glyph variants.
    static func norm(_ text: String) -> Scalars {
        let lowered = text.precomposedStringWithCompatibilityMapping.lowercased()
        var result: Scalars = []
        result.reserveCapacity(lowered.unicodeScalars.count)
        for scalar in lowered.unicodeScalars {
            let value = scalar.value
            if (0x064B...0x065F).contains(value) || value == 0x0670 || value == 0x0640 || value == 0x0307 {
                continue
            }
            switch value {
            case 0x0623, 0x0625, 0x0622, 0x0671: result.append(0x0627)
            case 0x0649: result.append(0x064A)
            case 0x0629: result.append(0x0647)
            case 0x0131: result.append(0x69)
            case 0x03C2: result.append(0x03C3)
            default: result.append(value)
            }
        }
        return result
    }

    /// wordform has no padding on either side: code points outside L* / N* / M* become spaces, runs of spaces collapse into one, and leading/trailing spaces are removed.
    static func words(_ norm: Scalars) -> Scalars {
        var result: Scalars = []
        result.reserveCapacity(norm.count)
        for value in norm {
            if isWordScalar(value) {
                result.append(value)
            } else if let last = result.last, last != 0x20 {
                result.append(0x20)
            }
        }
        if result.last == 0x20 { result.removeLast() }
        return result
    }

    static func isWordScalar(_ value: UInt32) -> Bool {
        guard let scalar = Unicode.Scalar(value) else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    // MARK: Code point array helpers

    private static let newline: UInt32 = 0x0A
    private static let sentenceEnders = Set(DirectiveLexicon.sentenceEnders.flatMap { $0.unicodeScalars.map(\.value) })
    private static let questionEnders = Set(DirectiveLexicon.questionEnders.flatMap { $0.unicodeScalars.map(\.value) })
    private static let questionStarters = Set(DirectiveLexicon.questionStarters.flatMap { $0.unicodeScalars.map(\.value) })
    /// Characters ("。", "！", "!", ".") stripped from the end of a sentence before judging whether it is a question
    private static let questionTrailers: Set<UInt32> = [0x3002, 0xFF01, 0x21, 0x2E]
    private static let quotePairs: [(opener: UInt32, closer: UInt32)] = DirectiveLexicon.quotePairs.compactMap { pair in
        guard pair.count == 2,
              let opener = pair[0].unicodeScalars.first?.value,
              let closer = pair[1].unicodeScalars.first?.value else { return nil }
        return (opener, closer)
    }

    /// The same set as ContextSanitizer.unicodeWhiteSpace (Unicode White_Space; U+FEFF does not count).
    static func isWhiteSpace(_ value: UInt32) -> Bool {
        guard let scalar = Unicode.Scalar(value) else { return false }
        return ContextSanitizer.unicodeWhiteSpace.contains(scalar)
    }

    static func trim(_ text: Scalars) -> Scalars {
        guard let first = text.firstIndex(where: { !isWhiteSpace($0) }),
              let last = text.lastIndex(where: { !isWhiteSpace($0) }) else { return [] }
        return Array(text[first...last])
    }

    static func string(_ scalars: Scalars) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars.compactMap(Unicode.Scalar.init))
        return String(view)
    }

    private static func hasPrefix(_ text: Scalars, _ prefix: Scalars, at start: Int = 0) -> Bool {
        guard start + prefix.count <= text.count else { return false }
        for offset in prefix.indices where text[start + offset] != prefix[offset] {
            return false
        }
        return true
    }

    private static func hasSuffix(_ text: Scalars, _ suffix: Scalars) -> Bool {
        suffix.count <= text.count && hasPrefix(text, suffix, at: text.count - suffix.count)
    }

    static func find(_ text: Scalars, _ needle: Scalars, from start: Int) -> Int? {
        guard !needle.isEmpty, start <= text.count - needle.count else { return nil }
        for index in start...(text.count - needle.count) where hasPrefix(text, needle, at: index) {
            return index
        }
        return nil
    }
}
