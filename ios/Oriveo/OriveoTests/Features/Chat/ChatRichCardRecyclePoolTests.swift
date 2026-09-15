import Testing
import UIKit
@testable import Oriveo

/// Rich card reuse pool: entering the pool disconnects the previous cell's callbacks, eviction is by
/// count, and the pool clears when leaving a conversation, switching appearance, on a memory warning,
/// and when the language changes.
@Suite("Rich card reuse pool", .serialized)
@MainActor
struct ChatRichCardRecyclePoolTests {
    private final class Sentinel {}

    private func uniqueTableLines() -> [String] {
        ["| Pool \(UUID().uuidString.prefix(8)) | B |", "|---|---|", "| 1 | 2 |", "| 3 | 4 |"]
    }

    private func tableCard(_ lines: [String]) throws -> UIKitTableCard {
        let card = try #require(UIKitTableCard.make(lines: lines))
        card.frame = CGRect(x: 0, y: 0, width: 320, height: 10)
        card.layoutIfNeeded()
        card.completeDeferredRows()
        return card
    }

    @Test("a table card releases the previous cell's callbacks as soon as it enters the pool, not on the next take")
    func tableCardDropsCallbacksWhenRecycled() throws {
        let lines = uniqueTableLines()
        let card = try tableCard(lines)
        weak var weakSentinel: Sentinel?
        do {
            let sentinel = Sentinel()
            weakSentinel = sentinel
            card.onAskSelection = { _ in _ = sentinel }
            card.onIntrinsicHeightDidChange = { _ = sentinel }
        }
        #expect(weakSentinel != nil, "Precondition: the callbacks hold the captured object")

        UIKitTableCard.recycle(card)
        #expect(weakSentinel == nil, "A pooled card still holds the previous cell's closure chain")
        #expect(UIKitTableCard.make(lines: lines) === card)
    }

    @Test("a code card releases its save note, ask and height callbacks as soon as it enters the pool")
    func codeCardDropsCallbacksWhenRecycled() {
        let content = "let pool = \"\(UUID().uuidString)\""
        let card = UIKitCodeBlockCard.make(language: "swift", content: content, parentViewController: UIViewController())
        weak var weakSentinel: Sentinel?
        do {
            let sentinel = Sentinel()
            weakSentinel = sentinel
            card.onSaveNote = { _ = sentinel }
            card.onAskSelection = { _ in _ = sentinel }
            card.onIntrinsicHeightDidChange = { _ = sentinel }
        }
        #expect(weakSentinel != nil)

        UIKitCodeBlockCard.recycle(card)
        #expect(weakSentinel == nil, "A pooled code card still holds the previous cell's closure chain")
        #expect(card.onSaveNote == nil && card.onAskSelection == nil && card.onIntrinsicHeightDidChange == nil)
        #expect(UIKitCodeBlockCard.make(language: "swift", content: content, parentViewController: nil) === card)
    }

    @Test("count-based LRU eviction drops the oldest entries beyond the limit")
    func poolEvictsOldestBeyondLimit() {
        let pool = ChatRichCardRecyclePool<UIView>(countLimit: 3)
        let views = (0..<5).map { _ in UIView() }
        for (index, view) in views.enumerated() {
            pool.put(view, key: "k\(index)")
        }
        #expect(pool.count == 3)
        #expect(pool.take(key: "k0") == nil)
        #expect(pool.take(key: "k1") == nil)
        #expect(pool.take(key: "k4") === views[4])
        // A card still attached to a view hierarchy is not taken back.
        let parent = UIView()
        let attached = UIView()
        parent.addSubview(attached)
        pool.put(attached, key: "attached")
        #expect(pool.take(key: "attached") == nil)
        #expect(parent.subviews.contains(attached))
    }

    @Test("a memory warning clears the pools of both card types")
    func memoryWarningPurgesPools() throws {
        let card = try tableCard(uniqueTableLines())
        UIKitTableCard.recycle(card)
        let code = UIKitCodeBlockCard.make(language: nil, content: "memory \(UUID())", parentViewController: nil)
        UIKitCodeBlockCard.recycle(code)
        #expect(UIKitTableCard.recycledCardCountForTesting > 0)
        #expect(UIKitCodeBlockCard.recycledCardCountForTesting > 0)

        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #expect(UIKitTableCard.recycledCardCountForTesting == 0)
        #expect(UIKitCodeBlockCard.recycledCardCountForTesting == 0)
    }

    @Test("leaving the chat screen (dismantling the representable) clears the pools")
    func dismantlingChatListPurgesPools() throws {
        UIKitTableCard.recycle(try tableCard(uniqueTableLines()))
        #expect(UIKitTableCard.recycledCardCountForTesting > 0)
        ChatListViewControllerRepresentable.dismantleUIViewController(ChatListViewController(), coordinator: ())
        #expect(UIKitTableCard.recycledCardCountForTesting == 0)
    }

    @Test("switching between light and dark on the chat list clears the pools")
    func interfaceStyleChangePurgesPools() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = .light
        let controller = ChatListViewController()
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()

        UIKitTableCard.recycle(try tableCard(uniqueTableLines()))
        #expect(UIKitTableCard.recycledCardCountForTesting > 0)
        window.overrideUserInterfaceStyle = .dark
        controller.view.updateTraitsIfNeeded()
        #expect(UIKitTableCard.recycledCardCountForTesting == 0, "Cards built in the old appearance stayed in the pool")
    }

    @Test("after changing the in-app language, a code card built in the old language is not taken back (its labels are written at build time)")
    func languageChangeInvalidatesPool() {
        var preference = AppPreferencesStore.load()
        let original = preference.language
        defer {
            var restore = AppPreferencesStore.load()
            restore.language = original
            AppPreferencesStore.save(restore)
            L10n.invalidateCache()
        }
        preference.language = .english
        AppPreferencesStore.save(preference)
        L10n.invalidateCache()

        let content = "print(\"\(UUID().uuidString)\")"
        let english = UIKitCodeBlockCard.make(language: nil, content: content, parentViewController: nil)
        UIKitCodeBlockCard.recycle(english)

        preference.language = .japanese
        AppPreferencesStore.save(preference)
        L10n.invalidateCache()
        let japanese = UIKitCodeBlockCard.make(language: nil, content: content, parentViewController: nil)
        #expect(japanese !== english, "A card built in English was taken back after the language changed")
        let labels = allLabels(in: japanese).compactMap(\.text)
        #expect(labels.contains(L10n.tr("Code").uppercased()), "The language badge should use the current language: \(labels)")
    }

    private func allLabels(in view: UIView) -> [UILabel] {
        view.subviews.flatMap { subview in
            ((subview as? UILabel).map { [$0] } ?? []) + allLabels(in: subview)
        }
    }
}
