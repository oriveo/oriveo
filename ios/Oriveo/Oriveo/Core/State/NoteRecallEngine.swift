import Foundation

nonisolated enum NoteRecallEngine {
    static let tagWeight = 8
    static let titleWeight = 4
    static let bodyWeight = 2
    static let minScore = 4
    static let limit = 2

    /// Composer recall is best-effort UI assistance, not the message transport. Bound the
    /// derived search work so a large paste cannot monopolize the main thread or allocate an
    /// unbounded CJK n-gram set. The full composer text is still sent unchanged.
    static let maxDraftCharacters = 4_096
    static let maxTerms = 128
    static let maxNoteBodyCharacters = NoteRecallCandidate.maxBodyCharacters
    static let maxCandidateNotes = 128
    static let recentCandidateNotes = 24

    private static let stopwords: Set<String> = [
        "about", "after", "also", "and", "are", "can", "could", "does", "for", "from",
        "how", "into", "should", "that", "the", "this", "use", "what", "when", "where",
        "with", "would"
    ]

    static func findRelatedNotes(draftText: String, notes: [NoteSummary]) -> [NoteSummary] {
        let terms = tokenize(recallSample(from: draftText)).sorted()
        guard !terms.isEmpty else { return [] }
        let boundedNotes = Array(
            notes.lazy
                .filter { $0.deletedAt == nil }
                .prefix(maxCandidateNotes)
        )
        let notesByID = Dictionary(uniqueKeysWithValues: boundedNotes.map { ($0.id, $0) })
        let preparedNotes = boundedNotes.map(candidate).map(prepare)
        let suggestions = (try? findRelatedNotes(terms: terms, preparedNotes: preparedNotes)) ?? []
        return suggestions.compactMap { notesByID[$0.id] }
    }

    static func candidate(_ note: NoteSummary) -> NoteRecallCandidate {
        NoteRecallCandidate(
            id: note.id,
            title: String(note.title.prefix(NoteRecallCandidate.maxTitleCharacters)),
            body: String(note.body.prefix(NoteRecallCandidate.maxBodyCharacters)),
            tags: note.tags.prefix(NoteRecallCandidate.maxTags).map {
                String($0.prefix(NoteRecallCandidate.maxTagCharacters))
            },
            sourceModelName: note.sourceModelName.map {
                String($0.prefix(NoteRecallCandidate.maxSourceCharacters))
            },
            sourceProviderKind: note.sourceProviderKind,
            sourceProviderName: note.sourceProviderName.map {
                String($0.prefix(NoteRecallCandidate.maxSourceCharacters))
            },
            captureKind: note.captureKind,
            updatedAt: note.updatedAt
        )
    }

    static func prepare(_ candidate: NoteRecallCandidate) -> PreparedNote {
        return PreparedNote(
            suggestion: Suggestion(candidate: candidate),
            title: normalizeText(candidate.title),
            body: normalizeText(candidate.body),
            tags: candidate.tags.map(normalizeText).filter { !$0.isEmpty }
        )
    }

    static func findRelatedNotes(
        terms: [String],
        preparedNotes: [PreparedNote]
    ) throws -> [Suggestion] {
        try Task.checkCancellation()
        guard !terms.isEmpty else { return [] }

        let matcher = LiteralMultiPatternMatcher(patterns: terms)
        var scored: [(suggestion: Suggestion, score: Int)] = []
        scored.reserveCapacity(min(preparedNotes.count, limit * 4))

        for prepared in preparedNotes {
            try Task.checkCancellation()
            let titleMatches = try matcher.matches(in: prepared.title)
            let bodyMatches = try matcher.matches(in: prepared.body)
            var tagMatches = Set<Int>()
            for tag in prepared.tags {
                try Task.checkCancellation()
                tagMatches.formUnion(try matcher.matches(in: tag))
                for (index, term) in terms.enumerated() where term.contains(tag) {
                    tagMatches.insert(index)
                }
            }

            let score = tagMatches.count * tagWeight
                + titleMatches.count * titleWeight
                + bodyMatches.count * bodyWeight
            if score >= minScore {
                scored.append((prepared.suggestion, score))
            }
        }

        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.suggestion.updatedAt > b.suggestion.updatedAt
        }
        return Array(scored.prefix(limit).map(\.suggestion))
    }

    static func normalizeText(_ value: String) -> String {
        value.lowercased()
            .precomposedStringWithCompatibilityMapping            // NFKC
            .replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[^\\p{L}\\p{N}\\s]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tokenize(_ text: String) -> Set<String> {
        var terms = Set<String>()

        func insert(_ term: String) {
            guard terms.count < maxTerms else { return }
            terms.insert(term)
        }

        for word in normalizeText(text).split(separator: " ") {
            let w = String(word)
            if w.count >= 3, w.count <= 64, !stopwords.contains(w) { insert(w) }
            if terms.count >= maxTerms { return terms }
        }

        for run in cjkRuns(in: text) {
            let normalized = normalizeText(run).replacingOccurrences(of: " ", with: "")
            guard normalized.count >= 2 else { continue }
            let chars = Array(normalized)
            if chars.count <= 64 { insert(normalized) }
            if chars.count >= 4 {
                for i in 0...(chars.count - 4) {
                    insert(String(chars[i..<i + 4]))
                    if terms.count >= maxTerms { return terms }
                }
            }
            if chars.count >= 3 {
                for i in 0...(chars.count - 3) {
                    insert(String(chars[i..<i + 3]))
                    if terms.count >= maxTerms { return terms }
                }
            }
        }
        return terms
    }

    /// Preserve both the opening context and the most recent intent for pathological pastes.
    /// Normal drafts are returned byte-for-byte unchanged.
    static func recallSample(from text: String) -> String {
        guard let cutoff = text.index(
            text.startIndex,
            offsetBy: maxDraftCharacters,
            limitedBy: text.endIndex
        ), cutoff != text.endIndex else {
            return text
        }
        let half = maxDraftCharacters / 2
        return String(text.prefix(half)) + "\n" + String(text.suffix(half))
    }

    private static func cjkRuns(in text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for ch in text {
            if ch.isCJK {
                current.append(ch)
            } else {
                if current.count >= 2 { runs.append(current) }
                current = ""
            }
        }
        if current.count >= 2 { runs.append(current) }
        return runs
    }
}

nonisolated extension NoteRecallEngine {
    struct Suggestion: Identifiable, Sendable {
        let id: UUID
        let title: String
        let sourceModelName: String?
        let sourceProviderKind: ProviderKind?
        let sourceProviderName: String?
        let captureKind: NoteCaptureKind
        let updatedAt: Date

        var showsSourceBadge: Bool {
            captureKind != .blank && (sourceProviderKind != nil || sourceModelName != nil)
        }

        init(candidate: NoteRecallCandidate) {
            id = candidate.id
            title = candidate.title
            sourceModelName = candidate.sourceModelName
            sourceProviderKind = candidate.sourceProviderKind
            sourceProviderName = candidate.sourceProviderName
            captureKind = candidate.captureKind
            updatedAt = candidate.updatedAt
        }
    }

    struct PreparedNote: Sendable {
        let suggestion: Suggestion
        let title: String
        let body: String
        let tags: [String]
    }

    struct LiteralMultiPatternMatcher: Sendable {
        private struct Node: Sendable {
            var transitions: [Character: Int] = [:]
            var failure = 0
            var outputs: [Int] = []
        }

        private let nodes: [Node]
        private let patternCount: Int

        init(patterns: [String]) {
            var nodes = [Node()]
            for (patternIndex, pattern) in patterns.enumerated() {
                var state = 0
                for character in pattern {
                    if let next = nodes[state].transitions[character] {
                        state = next
                    } else {
                        nodes.append(Node())
                        let next = nodes.count - 1
                        nodes[state].transitions[character] = next
                        state = next
                    }
                }
                nodes[state].outputs.append(patternIndex)
            }

            var queue: [Int] = []
            queue.reserveCapacity(nodes.count)
            for child in nodes[0].transitions.values {
                queue.append(child)
            }

            var cursor = 0
            while cursor < queue.count {
                let state = queue[cursor]
                cursor += 1
                for (character, next) in nodes[state].transitions {
                    queue.append(next)
                    var fallback = nodes[state].failure
                    while fallback != 0 && nodes[fallback].transitions[character] == nil {
                        fallback = nodes[fallback].failure
                    }
                    if let target = nodes[fallback].transitions[character], target != next {
                        nodes[next].failure = target
                    }
                    nodes[next].outputs.append(contentsOf: nodes[nodes[next].failure].outputs)
                }
            }

            self.nodes = nodes
            self.patternCount = patterns.count
        }

        func matches(in text: String) throws -> Set<Int> {
            guard !text.isEmpty, patternCount > 0 else { return [] }
            var matches = Set<Int>()
            var state = 0
            var processed = 0

            for character in text {
                while state != 0 && nodes[state].transitions[character] == nil {
                    state = nodes[state].failure
                }
                if let next = nodes[state].transitions[character] {
                    state = next
                }
                matches.formUnion(nodes[state].outputs)
                if matches.count == patternCount { return matches }

                processed += 1
                if processed.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
            }
            return matches
        }
    }
}

actor NoteRecallWorker {
    struct CacheMetrics: Equatable, Sendable {
        let cachedNotes: Int
        let preparedNotes: Int
    }

    private struct CacheEntry: Sendable {
        let updatedAt: Date
        let prepared: NoteRecallEngine.PreparedNote
    }

    private var cache: [UUID: CacheEntry] = [:]
    private var preparedNoteCount = 0

    func terms(for draftText: String) throws -> [String] {
        try Task.checkCancellation()
        let terms = NoteRecallEngine.tokenize(
            NoteRecallEngine.recallSample(from: draftText)
        ).sorted()
        try Task.checkCancellation()
        return terms
    }

    func findRelatedNotes(terms: [String], candidates: [NoteRecallCandidate]) throws -> [NoteRecallEngine.Suggestion] {
        try Task.checkCancellation()
        let candidates = Array(candidates.prefix(NoteRecallEngine.maxCandidateNotes))
        let activeIDs = Set(candidates.map(\.id))
        cache = cache.filter { activeIDs.contains($0.key) }

        var preparedNotes: [NoteRecallEngine.PreparedNote] = []
        preparedNotes.reserveCapacity(activeIDs.count)
        for candidate in candidates {
            try Task.checkCancellation()
            if let entry = cache[candidate.id], entry.updatedAt == candidate.updatedAt {
                preparedNotes.append(entry.prepared)
                continue
            }
            let prepared = NoteRecallEngine.prepare(candidate)
            cache[candidate.id] = CacheEntry(updatedAt: candidate.updatedAt, prepared: prepared)
            preparedNoteCount += 1
            preparedNotes.append(prepared)
        }

        return try NoteRecallEngine.findRelatedNotes(
            terms: terms,
            preparedNotes: preparedNotes
        )
    }

    func cacheMetrics() -> CacheMetrics {
        CacheMetrics(cachedNotes: cache.count, preparedNotes: preparedNoteCount)
    }
}

nonisolated private extension Character {
    var isCJK: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3400...0x4DBF).contains(scalar.value) ||
            (0x3040...0x30FF).contains(scalar.value) ||
            (0xAC00...0xD7AF).contains(scalar.value)
        }
    }
}
