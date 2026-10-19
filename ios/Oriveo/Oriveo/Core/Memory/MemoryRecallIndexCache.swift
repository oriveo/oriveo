import Foundation
import OriveoProviderKit

/// L3 recall index cache: the index is rebuilt only when the episodic item set is not exactly equal to the one used for the last build, and it runs on an actor,
/// so a large index is never built on the main thread. L3 is not synced and local edits do not bump revision, so comparison is by whole-item equality
/// (changes to body, occurredAt, scope, pinned, confidence, expiry and so on all trigger a rebuild); changes to L2 items do not trigger a rebuild.
actor MemoryRecallIndexCache {
    static let shared = MemoryRecallIndexCache()

    private var indexedItems: [MemoryItem]?
    private var index: MemoryRecallIndex?

    /// Hits for this query (in rank order, at most topK).
    func recall(items: [MemoryItem], query: String, context: MemoryRecallContext) -> [MemoryRecallHit] {
        MemoryRecall.recall(index(for: items), query: query, context: context)
    }

    /// One search_memory call (memory-search.v1): the same index, with a relaxed threshold and excludeIds skipped.
    func search(
        items: [MemoryItem], arguments: String, context: MemoryRecallContext, excludeIds: [String], priorInTurn: Int
    ) -> MemorySearchOutcome {
        MemorySearch.search(
            index(for: items), arguments: arguments, context: context, excludeIds: excludeIds, priorInTurn: priorInTurn
        )
    }

    /// Number of visible, unexpired active L3 items in this conversation (the criterion for search_memory mode).
    func visibleCount(items: [MemoryItem], context: MemoryRecallContext) -> Int {
        MemoryRecall.visibleCount(index(for: items), context: context)
    }

    private func index(for items: [MemoryItem]) -> MemoryRecallIndex {
        let episodic = items.filter { $0.layer == .episodic }.sorted { $0.id < $1.id }
        if let index, indexedItems == episodic { return index }
        let built = MemoryRecall.buildIndex(episodic)
        indexedItems = episodic
        index = built
        return built
    }
}
