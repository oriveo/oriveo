import Foundation

// Pure functions for L3 recall (source of truth: rules 1-11 in `shared/context-contracts/memory-recall.v1.json`).
// Every platform uses the same in-memory tokenizer + BM25: the same items and query produce the same hits byte for byte; no platform FTS engine is used.
// Floating point is compared only after round6; CJK detection uses the cjkRanges code point intervals, not the Script property.

/// Recall context: this conversation id, this folder id (nil if none), and the current time (epoch milliseconds).
public struct MemoryRecallContext: Hashable, Sendable {
    public var conversationId: String
    public var folderId: String?
    public var nowMs: Int64

    public init(conversationId: String, folderId: String?, nowMs: Int64) {
        self.conversationId = conversationId
        self.folderId = folderId
        self.nowMs = nowMs
    }
}

/// One hit: date is the UTC YYYY-MM-DD of time, nil when there is no parsable time.
public struct MemoryRecallHit: Hashable, Sendable {
    public var id: String
    public var text: String
    public var date: String?
    public var score: Double
    public var coverage: Double

    public init(id: String, text: String, date: String?, score: Double, coverage: Double) {
        self.id = id
        self.text = text
        self.date = date
        self.score = score
        self.coverage = coverage
    }

    /// Item handed to assemble dynamic.recall.
    public var entry: ContextRecallEntry {
        ContextRecallEntry(id: id, text: text, date: date)
    }
}

/// Conflict resolution (rules 11).
public enum MemoryConflictResolution: String, Codable, Hashable, Sendable, CaseIterable {
    case useNew
    case keepBoth
    case useOld
}

/// One patch produced by resolve: the repository rewrites these three fields of the matching item according to it.
public struct MemoryRecallPatch: Codable, Hashable, Sendable {
    public var id: String
    public var status: MemoryStatus
    public var conflictGroupId: String?
    public var supersedes: [String]

    public init(id: String, status: MemoryStatus, conflictGroupId: String?, supersedes: [String]) {
        self.id = id
        self.status = status
        self.conflictGroupId = conflictGroupId
        self.supersedes = supersedes
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, conflictGroupId, supersedes
    }

    /// null is written as null, with the same key order as the fixture.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(status, forKey: .status)
        try container.encode(conflictGroupId, forKey: .conflictGroupId)
        try container.encode(supersedes, forKey: .supersedes)
    }
}

/// The built index (rules 4): includes only episodic + active items with at least one term; rebuilt whenever the item set changes.
public struct MemoryRecallIndex: Sendable {
    struct Document: Sendable {
        var id: String
        var text: String
        /// Deduplicated terms in first-occurrence order (the summation order is fixed, so floating point is identical on all platforms).
        var terms: [String]
        var termFrequency: [String: Int]
        var length: Int
        var sumIdf: Double
        var timeMs: Double?
        /// nil = never expires; -inf = set but unparsable (treated as expired).
        var expiresMs: Double?
        var scopeType: MemoryScopeType
        var scopeId: String?
        var pinned: Bool
        var confidence: Double
    }

    var documents: [Document]
    var idf: [String: Double]
    var postings: [String: [Int]]
    var averageLength: Double

    /// Number of items included in the index (N).
    public var count: Int { documents.count }
}

public enum MemoryRecall {
    // MARK: Constants (fixture constants, verbatim)

    public static let k1 = 1.2
    public static let b = 0.75
    public static let topK = 5
    public static let coverageMin = 0.25
    public static let minMatchedTerms = 2
    public static let idfPriorDocs = 20
    public static let scopeFactorConversation = 1.2
    public static let scopeFactorFolder = 1.1
    public static let scopeFactorGlobal = 1.0
    public static let pinnedFactor = 1.2
    public static let halfLifeDays = 180.0
    public static let timeFloor = 0.5
    public static let confidenceFloor = 0.5
    public static let maxQueryCodePoints = 8000
    public static let conflictJaccardMin = 0.5
    public static let joiners = "_.-/#"
    public static let cjkRanges: [ClosedRange<UInt32>] = [
        4352...4607, 12352...12447, 12448...12543, 12592...12687, 12784...12799,
        13312...19903, 19968...40959, 44032...55215, 63744...64255, 131072...201551,
    ]

    private static let joinerSet: Set<UInt32> = Set(joiners.unicodeScalars.map(\.value))
    private static let dayMs = 86_400_000.0

    /// round6(x) = floor(x·1e6 + 0.5)/1e6.
    public static func round6(_ value: Double) -> Double {
        (value * 1e6 + 0.5).rounded(.down) / 1e6
    }

    // MARK: rules 1-3 tokenization

    public static func tokens(_ text: String) -> [String] {
        let scalars = normalized(text)
        var words: [String] = []
        var compounds: [String] = []
        var index = 0
        while index < scalars.count {
            guard isWord(scalars[index]) else {
                index += 1
                continue
            }
            var end = index
            while end < scalars.count, isWord(scalars[end]) { end += 1 }
            appendWordTokens(scalars[index..<end], into: &words)
            index = end
        }
        index = 0
        while index < scalars.count {
            guard isWord(scalars[index]) || isJoiner(scalars[index]) else {
                index += 1
                continue
            }
            var end = index
            while end < scalars.count, isWord(scalars[end]) || isJoiner(scalars[end]) { end += 1 }
            var lower = index
            var upper = end
            while lower < upper, isJoiner(scalars[lower]) { lower += 1 }
            while upper > lower, isJoiner(scalars[upper - 1]) { upper -= 1 }
            if scalars[lower..<upper].contains(where: isJoiner) {
                compounds.append(string(scalars[lower..<upper]))
            }
            index = end
        }
        return words + compounds
    }

    /// NFKC -> lowercase (locale-independent) -> fold final sigma into sigma.
    private static func normalized(_ text: String) -> [Unicode.Scalar] {
        text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars.map {
            $0.value == 0x03C2 ? Unicode.Scalar(0x03C3)! : $0
        }
    }

    private static func isWord(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    private static func isJoiner(_ scalar: Unicode.Scalar) -> Bool {
        joinerSet.contains(scalar.value)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        cjkRanges.contains { $0.contains(scalar.value) }
    }

    /// Splits a run of word characters by CJK or not: a non-CJK sub-run is one term as a whole; a CJK sub-run of length 1 takes that character, and of length >= 2 takes adjacent bigrams.
    private static func appendWordTokens(_ run: ArraySlice<Unicode.Scalar>, into tokens: inout [String]) {
        var start = run.startIndex
        while start < run.endIndex {
            let cjk = isCJK(run[start])
            var end = start
            while end < run.endIndex, isCJK(run[end]) == cjk { end += 1 }
            if !cjk {
                tokens.append(string(run[start..<end]))
            } else if end - start == 1 {
                tokens.append(string(run[start..<end]))
            } else {
                for position in start..<(end - 1) {
                    tokens.append(string(run[position...(position + 1)]))
                }
            }
            start = end
        }
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    // MARK: rules 4 index

    public static func buildIndex(_ items: [MemoryItem]) -> MemoryRecallIndex {
        var documents: [MemoryRecallIndex.Document] = []
        var documentFrequency: [String: Int] = [:]
        var totalLength = 0
        for raw in items {
            let item = MemoryItems.canonical(raw)
            guard item.layer == .episodic, item.status == .active else { continue }
            let all = tokens(item.content)
            guard !all.isEmpty else { continue }
            var frequency: [String: Int] = [:]
            var distinct: [String] = []
            for token in all {
                if frequency[token] == nil { distinct.append(token) }
                frequency[token, default: 0] += 1
            }
            for term in distinct { documentFrequency[term, default: 0] += 1 }
            totalLength += all.count
            documents.append(MemoryRecallIndex.Document(
                id: item.id,
                text: item.content,
                terms: distinct,
                termFrequency: frequency,
                length: all.count,
                sumIdf: 0,
                timeMs: timeMs(item),
                expiresMs: item.expiresAt.map { epochMs($0) ?? -Double.infinity },
                scopeType: item.scope.type,
                scopeId: item.scope.id?.lowercased(),
                pinned: item.pinned,
                confidence: item.confidence
            ))
        }
        let N = Double(documents.count)
        var idf: [String: Double] = [:]
        for (term, df) in documentFrequency {
            let d = Double(df)
            idf[term] = log(1 + (N + Double(idfPriorDocs) - d + 0.5) / (d + 0.5))
        }
        var postings: [String: [Int]] = [:]
        for position in documents.indices {
            var sum = 0.0
            for term in documents[position].terms {
                sum += idf[term] ?? 0
                postings[term, default: []].append(position)
            }
            documents[position].sumIdf = sum
        }
        return MemoryRecallIndex(
            documents: documents,
            idf: idf,
            postings: postings,
            averageLength: documents.isEmpty ? 0 : Double(totalLength) / N
        )
    }

    // MARK: rules 5-8 recall

    public static func recall(_ index: MemoryRecallIndex, query: String, context: MemoryRecallContext) -> [MemoryRecallHit] {
        guard !index.documents.isEmpty else { return [] }
        var limited = String.UnicodeScalarView()
        limited.append(contentsOf: query.unicodeScalars.prefix(maxQueryCodePoints))
        return rank(
            index,
            queryTerms: Set(tokens(String(limited))),
            context: context,
            coverageMin: coverageMin,
            minMatchedTerms: minMatchedTerms,
            excludeIds: [],
            topK: topK
        )
    }

    /// Scoring and ranking for rules 5-8; the threshold, skipped ids and Top-K are supplied by the caller (recall uses this file's constants, search_memory uses its own).
    static func rank(
        _ index: MemoryRecallIndex,
        queryTerms: Set<String>,
        context: MemoryRecallContext,
        coverageMin: Double,
        minMatchedTerms: Int,
        excludeIds: Set<String>,
        topK: Int
    ) -> [MemoryRecallHit] {
        guard !index.documents.isEmpty, !queryTerms.isEmpty else { return [] }
        var candidates = Set<Int>()
        for term in queryTerms {
            for position in index.postings[term] ?? [] { candidates.insert(position) }
        }
        let nowMs = Double(context.nowMs)
        let conversationId = context.conversationId.lowercased()
        let folderId = context.folderId?.lowercased()
        var hits: [MemoryRecallHit] = []
        for position in candidates.sorted() {
            let document = index.documents[position]
            guard !excludeIds.contains(document.id),
                  let scopeFactor = visibleScopeFactor(document, nowMs: nowMs, conversationId: conversationId, folderId: folderId)
            else { continue }
            var bm25 = 0.0
            var matched = 0
            var matchedIdf = 0.0
            let lengthNorm = 1 - b + b * Double(document.length) / index.averageLength
            for term in document.terms where queryTerms.contains(term) {
                let idf = index.idf[term] ?? 0
                let tf = Double(document.termFrequency[term] ?? 0)
                bm25 += idf * tf * (k1 + 1) / (tf + k1 * lengthNorm)
                matched += 1
                matchedIdf += idf
            }
            guard bm25 > 0, matched >= min(minMatchedTerms, document.terms.count) else { continue }
            let coverage = round6(matchedIdf / document.sumIdf)
            guard coverage >= coverageMin else { continue }
            let ageDays = document.timeMs.map { max(0, (nowMs - $0) / dayMs) } ?? 0
            let timeFactor = timeFloor + (1 - timeFloor) * pow(0.5, ageDays / halfLifeDays)
            let confidenceFactor = confidenceFloor + (1 - confidenceFloor) * min(max(document.confidence, 0), 1)
            let score = round6(
                bm25 * scopeFactor * (document.pinned ? pinnedFactor : 1) * timeFactor * confidenceFactor
            )
            hits.append(MemoryRecallHit(
                id: document.id,
                text: document.text,
                date: document.timeMs.map(utcDate),
                score: score,
                coverage: coverage
            ))
        }
        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return Array(lhs.id.utf16).lexicographicallyPrecedes(Array(rhs.id.utf16))
        }
        return Array(hits.prefix(topK))
    }

    /// Number of items visible to this conversation and not expired (the search_memory mode criterion: "at least one recallable L3 item").
    public static func visibleCount(_ index: MemoryRecallIndex, context: MemoryRecallContext) -> Int {
        let nowMs = Double(context.nowMs)
        let conversationId = context.conversationId.lowercased()
        let folderId = context.folderId?.lowercased()
        return index.documents.filter {
            visibleScopeFactor($0, nowMs: nowMs, conversationId: conversationId, folderId: folderId) != nil
        }.count
    }

    /// nil if expired or the scope is neither this conversation nor this folder; otherwise the scope coefficient.
    private static func visibleScopeFactor(
        _ document: MemoryRecallIndex.Document, nowMs: Double, conversationId: String, folderId: String?
    ) -> Double? {
        if let expires = document.expiresMs, !(expires > nowMs) { return nil }
        switch document.scopeType {
        case .global:
            return scopeFactorGlobal
        case .conversation:
            return document.scopeId == conversationId ? scopeFactorConversation : nil
        case .folder:
            guard let folderId, document.scopeId == folderId else { return nil }
            return scopeFactorFolder
        }
    }

    /// time = the first of occurredAt, source.observedAt and createdAt that parses as RFC 3339.
    private static func timeMs(_ item: MemoryItem) -> Double? {
        for candidate in [item.occurredAt, item.source.observedAt, item.createdAt] {
            if let candidate, let ms = epochMs(candidate) { return ms }
        }
        return nil
    }

    private static func epochMs(_ text: String) -> Double? {
        MemoryItems.instant(text).map { ($0.timeIntervalSince1970 * 1000).rounded() }
    }

    private static func utcDate(_ ms: Double) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ms / 1000))
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: rules 10 conflict

    /// When saving an L3 item, find the conflicting target: another active episodic item of the same kind and scope with Jaccard in [min, 1);
    /// take the highest Jaccard, then the smallest id. Returns nil if none.
    public static func conflict(saved: MemoryItem, items: [MemoryItem]) -> String? {
        let target = MemoryItems.canonical(saved)
        let targetTerms = Set(tokens(target.content))
        let targetScopeId = target.scope.id?.lowercased()
        var best: (id: String, jaccard: Double)?
        for raw in items {
            let item = MemoryItems.canonical(raw)
            guard item.id != target.id, item.layer == .episodic, item.status == .active,
                  item.kind == target.kind, item.scope.type == target.scope.type,
                  item.scope.id?.lowercased() == targetScopeId else { continue }
            let terms = Set(tokens(item.content))
            let union = targetTerms.union(terms).count
            guard union > 0 else { continue }
            let jaccard = round6(Double(targetTerms.intersection(terms).count) / Double(union))
            guard jaccard >= conflictJaccardMin, jaccard < 1 else { continue }
            if let current = best {
                let better = jaccard > current.jaccard
                    || (jaccard == current.jaccard && Array(item.id.utf16).lexicographicallyPrecedes(Array(current.id.utf16)))
                if !better { continue }
            }
            best = (item.id, jaccard)
        }
        return best?.id
    }

    // MARK: rules 11 resolution

    /// [newer's patch, older's patch]; both conflictGroupIds are cleared and no item is deleted.
    public static func resolve(
        newer: MemoryItem, older: MemoryItem, resolution: MemoryConflictResolution
    ) -> [MemoryRecallPatch] {
        let newer = MemoryItems.canonical(newer)
        let older = MemoryItems.canonical(older)
        var newerSupersedes = newer.supersedes
        let newerStatus: MemoryStatus
        let olderStatus: MemoryStatus
        switch resolution {
        case .useNew:
            if !newerSupersedes.contains(older.id) { newerSupersedes.append(older.id) }
            newerStatus = .active
            olderStatus = .superseded
        case .useOld:
            newerStatus = .superseded
            olderStatus = .active
        case .keepBoth:
            newerStatus = .active
            olderStatus = .active
        }
        return [
            MemoryRecallPatch(id: newer.id, status: newerStatus, conflictGroupId: nil, supersedes: newerSupersedes),
            MemoryRecallPatch(id: older.id, status: olderStatus, conflictGroupId: nil, supersedes: older.supersedes),
        ]
    }
}
