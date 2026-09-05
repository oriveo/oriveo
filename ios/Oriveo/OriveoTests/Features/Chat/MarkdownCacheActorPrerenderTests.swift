import Foundation
import Testing
import UIKit
@testable import Oriveo

@Suite("MarkdownCacheActorPrerender")
@MainActor
struct MarkdownCacheActorPrerenderTests {

    @Test("Prewarm Fills Light Cache For Main Thread")
    func prewarmFillsLightCacheForMainThread() {
        let text = "**bold** prewarm \(UUID().uuidString)"
        MarkdownAttributedStringRenderer.invalidateCache(for: text)
        MarkdownAttributedStringRenderer.prewarm(text, isDark: false)
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            #expect(MarkdownAttributedStringRenderer.cachedRender(for: text) != nil)
        }
    }

    @Test("Prewarm Fills Dark Cache For Main Thread")
    func prewarmFillsDarkCacheForMainThread() {
        let text = "# Heading prewarm \(UUID().uuidString)"
        MarkdownAttributedStringRenderer.invalidateCache(for: text)
        MarkdownAttributedStringRenderer.prewarm(text, isDark: true)
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            #expect(MarkdownAttributedStringRenderer.cachedRender(for: text) != nil)
        }
    }

    @Test("Prewarm String Matches Sync Render")
    func prewarmStringMatchesSyncRender() {
        let text = "`code` and **bold** \(UUID().uuidString)"
        var synced: NSAttributedString?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            synced = MarkdownAttributedStringRenderer.render(text)
        }
        MarkdownAttributedStringRenderer.invalidateCache(for: text)
        MarkdownAttributedStringRenderer.prewarm(text, isDark: false)
        var prewarmed: NSAttributedString?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            prewarmed = MarkdownAttributedStringRenderer.cachedRender(for: text)
        }
        #expect(prewarmed?.string == synced?.string)
    }

    @Test("Render With Pending Latex Is Not Cached")
    func renderWithPendingLatexIsNotCached() {
        let unique = UUID().uuidString.prefix(8)
        let text = "before\n$$\\sqrt{x_{\(unique)}}$$\nafter"
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            _ = MarkdownAttributedStringRenderer.render(text)
            #expect(
                MarkdownAttributedStringRenderer.cachedRender(for: text) == nil,
                "once the placeholder render is cached, a formula that settles with no cell to consume the notification leaves the page showing the placeholder forever"
            )
        }
        let plain = "text without any formula \(UUID().uuidString)"
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            _ = MarkdownAttributedStringRenderer.render(plain)
            #expect(MarkdownAttributedStringRenderer.cachedRender(for: plain) != nil)
        }
    }

    @Test("Prewarm With Pending Latex Is Not Cached")
    func prewarmWithPendingLatexIsNotCached() {
        let unique = UUID().uuidString.prefix(8)
        let text = "heading\n$$\\frac{a_{\(unique)}}{b}$$"
        MarkdownAttributedStringRenderer.prewarm(text, isDark: false)
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            #expect(MarkdownAttributedStringRenderer.cachedRender(for: text) == nil)
        }
    }

    @Test("Actor Prepare Rendered Fills Cache")
    func actorPrepareRenderedFillsCache() async {
        let text = "actor prewarm \(UUID().uuidString)"
        MarkdownAttributedStringRenderer.invalidateCache(for: text)
        let cacheActor = MarkdownCacheActor()
        await cacheActor.prepareRendered(text: text, isDark: false)
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            #expect(MarkdownAttributedStringRenderer.cachedRender(for: text) != nil)
        }
    }
}
