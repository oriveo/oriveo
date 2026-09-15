import UIKit

/// Cross-cell reuse pool for rich chat cards (tables and code blocks).
///
/// - Owned by the main thread with count-based LRU eviction: NSCache can evict and release objects on
///   a background thread under memory pressure, and a UIView must be released on the main thread.
/// - Only detached cards are taken back; when the same content is on two cells at once, the second one
///   builds a new card.
/// - Callers clear a card's callbacks before it enters the pool, so the pool never holds a previous
///   cell's closure chain.
/// - A change of the in-app language drops the whole pool, because localized labels are written when a
///   card is built. Appearance does not: a card corrects itself for the current appearance when it
///   returns to a window.
@MainActor
final class ChatRichCardRecyclePool<Card: UIView> {
    private struct Entry {
        let keyHash: Int
        let key: String
        let card: Card
    }

    private let countLimit: Int
    /// The most recently added entry is last.
    private var entries: [Entry] = []
    private var language: AppLanguage?

    init(countLimit: Int) {
        self.countLimit = countLimit
        ChatRichCardRecycling.installMemoryWarningObserverIfNeeded()
    }

    var count: Int { entries.count }

    func take(key: String) -> Card? {
        dropIfLanguageChanged()
        let keyHash = key.hashValue
        guard let index = entries.lastIndex(where: {
            $0.keyHash == keyHash && $0.key == key && $0.card.superview == nil
        }) else { return nil }
        return entries.remove(at: index).card
    }

    func put(_ card: Card, key: String) {
        dropIfLanguageChanged()
        entries.removeAll { $0.card === card }
        entries.append(Entry(keyHash: key.hashValue, key: key, card: card))
        if entries.count > countLimit {
            entries.removeFirst(entries.count - countLimit)
        }
    }

    func removeAll() {
        entries.removeAll()
    }

    private func dropIfLanguageChanged() {
        let current = AppLocalization.currentLanguage
        if language != current {
            entries.removeAll()
            language = current
        }
    }
}

/// One place to clear the reuse pools: leaving or switching conversations, switching between light and
/// dark appearance, and receiving a memory warning clear the pools of both card types.
@MainActor
enum ChatRichCardRecycling {
    private static var memoryWarningObserver: NSObjectProtocol?

    static func purgeAll() {
        UIKitTableCard.purgeRecycledCards()
        UIKitCodeBlockCard.purgeRecycledCards()
    }

    static func installMemoryWarningObserverIfNeeded() {
        guard memoryWarningObserver == nil else { return }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                purgeAll()
            }
        }
    }
}
