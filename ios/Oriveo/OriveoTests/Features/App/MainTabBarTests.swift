import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// The bottom tab bar is the system TabView (native liquid glass from iOS 26). These tests drive the
/// real AppRootView and check that the system bar is present, that content makes room for it, that the
/// selection binding works both ways, and that pages stay alive across tab switches.
@Suite("MainTabBar", .serialized)
@MainActor
struct MainTabBarTests {
    @Test("every tab has its own line icon asset (a template image tinted by the system)")
    func everyTabHasItsLineIcon() {
        #expect(AppTab.allCases.map(\.tabBarIconAsset) == ["TabIconHome", "TabIconProviders", "TabIconSettings"])
        for tab in AppTab.allCases {
            let image = UIImage(named: tab.tabBarIconAsset)
            #expect(image != nil, "missing asset \(tab.tabBarIconAsset)")
            #expect(image?.renderingMode == .alwaysTemplate, "\(tab.tabBarIconAsset) should be a template image")
        }
    }

    @Test("the selected icons are colour originals with the tab gradient baked in (one per scheme) and are not re-tinted by the system")
    func selectedIconsAreColoredOriginals() {
        for tab in AppTab.allCases {
            #expect(tab.tabBarSelectedIconAsset == tab.tabBarIconAsset + "Selected")
            for style in [UIUserInterfaceStyle.light, .dark] {
                let image = UIImage(named: tab.tabBarSelectedIconAsset, in: nil, compatibleWith: UITraitCollection(userInterfaceStyle: style))
                #expect(image != nil, "missing asset \(tab.tabBarSelectedIconAsset) (\(style.rawValue))")
                #expect(image?.renderingMode == .alwaysOriginal, "\(tab.tabBarSelectedIconAsset) must render in its original colours")
            }
        }
    }

    @Test("the system tab bar receives the colour original for the selected item and templates for the rest")
    func systemTabBarReceivesColoredSelectedIcon() async throws {
        let appState = AppState(seedDemoData: true)
        appState.selectedTab = .providers
        let (window, host) = try await present(appState)
        defer { dismiss(window) }

        let tabBar = try #require(descendants(of: host.view, as: UITabBar.self).first { isEffectivelyVisible($0) })
        let items = try #require(tabBar.items)
        #expect(items.count == AppTab.allCases.count)
        for (index, tab) in AppTab.allCases.enumerated() where index < items.count {
            let mode = items[index].image?.renderingMode
            if tab == appState.selectedTab {
                #expect(mode == .alwaysOriginal, "the selected \(tab) should get the colour original, got \(String(describing: mode))")
            } else {
                #expect(mode != .alwaysOriginal, "the unselected \(tab) should be a monochrome template")
            }
        }
    }

    @Test("no custom tab bar background from iOS 26 (it would defeat the liquid glass adaptation); earlier systems keep the solid fill")
    func customBackgroundOnlyBeforeIOS26() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Oriveo/Features/App/AppRootView.swift"),
            encoding: .utf8
        )
        let legacy = try #require(source.slice(from: "private struct LegacyTabBarBackground", to: "#Preview"))
        let modern = try #require(legacy.slice(from: "if #available(iOS 26, *) {", to: "} else {"))
        #expect(!modern.contains("toolbarBackground"), "the iOS 26 branch must not set a tab bar background")
        #expect(legacy.contains(".toolbarBackground(OriveoTheme.Palette.tabBar, for: .tabBar)"))
        #expect(!source.contains(".toolbar(.hidden, for: .tabBar)"), "the system tab bar must not be hidden")
    }

    @Test("the system tab bar is present and all three pages clear it at the bottom")
    func systemTabBarVisibleAndContentClearsIt() async throws {
        let appState = AppState(seedDemoData: true)
        let (window, host) = try await present(appState)
        defer { dismiss(window) }

        for tab in AppTab.allCases {
            appState.selectedTab = tab
            try await Task.sleep(for: .milliseconds(600))

            let tabBars = descendants(of: host.view, as: UITabBar.self).filter { isEffectivelyVisible($0) }
            #expect(tabBars.count == 1, "\(tab) shows \(tabBars.count) visible system tab bars")
            guard let tabBar = tabBars.first else { continue }
            let barTop = tabBar.convert(tabBar.bounds, to: window).minY

            let pages = descendants(of: host.view, as: UIScrollView.self)
                .filter { !($0 is UITextView) && isEffectivelyVisible($0) && $0.bounds.height > 400 }
            #expect(!pages.isEmpty, "\(tab) has no visible main scroll view")
            for scrollView in pages {
                let pageBottom = scrollView.convert(scrollView.bounds, to: window).maxY
                let covered = pageBottom - barTop
                #expect(
                    scrollView.adjustedContentInset.bottom >= covered - 1,
                    "\(tab)'s bottom inset \(scrollView.adjustedContentInset.bottom) does not cover the \(covered) taken by the tab bar"
                )
            }
        }
    }

    @Test("tapping the system tab bar writes selectedTab back, and changing selectedTab updates the system selection")
    func tabBarBindsBothWays() async throws {
        let appState = AppState(seedDemoData: true)
        appState.selectedTab = .home
        let (window, host) = try await present(appState)
        defer { dismiss(window) }

        // Bar → state: activate the Providers button on the system tab bar through the accessibility tree
        // (the same action path as a VoiceOver double tap)
        let providersItem = try #require(
            accessibilityElement(labeled: AppTab.providers.title, traits: .button, in: host.view),
            "the system tab bar has no \(AppTab.providers.title) button"
        )
        // The iOS 26 system tab buttons do not implement accessibilityActivate (VoiceOver taps the activation
        // point instead), so fall back to a UIControl tap
        if !providersItem.accessibilityActivate(), let control = providersItem as? UIControl {
            control.sendActions(for: .touchUpInside)
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(appState.selectedTab == .providers)

        // State → bar: an external switch to Settings (a deep link, for example) moves the system selection
        appState.selectedTab = .settings
        try await Task.sleep(for: .milliseconds(500))
        let settingsItem = try #require(accessibilityElement(labeled: AppTab.settings.title, traits: .button, in: host.view))
        let homeItem = try #require(accessibilityElement(labeled: AppTab.home.title, traits: .button, in: host.view))
        #expect(settingsItem.accessibilityTraits.contains(.selected))
        #expect(!homeItem.accessibilityTraits.contains(.selected))
    }

    @Test("switching tabs and back keeps the Home scroll position (TabView keeps pages alive)")
    func switchingTabsPreservesHomeState() async throws {
        let appState = AppState(seedDemoData: true)
        appState.conversations = (0..<30).map { index in
            TestFactories.makeConversation(
                title: "Conversation \(index)",
                previewText: "Preview \(index)",
                updatedAt: Date().addingTimeInterval(-Double(index) * 600)
            )
        }
        appState.conversationManager.handleConversationsDidChange(now: Date())
        appState.selectedTab = .home
        let (window, host) = try await present(appState)
        defer { dismiss(window) }

        // Only Home has been loaded at this point, so take the scroll view with the tallest content
        let homeScroll = try #require(
            descendants(of: host.view, as: UIScrollView.self)
                .filter { !($0 is UITextView) && $0.window != nil }
                .max { $0.contentSize.height < $1.contentSize.height }
        )
        let targetOffset = CGPoint(x: 0, y: 320)
        homeScroll.setContentOffset(targetOffset, animated: false)
        try await Task.sleep(for: .milliseconds(300))

        appState.selectedTab = .providers
        try await Task.sleep(for: .milliseconds(600))
        appState.selectedTab = .home
        try await Task.sleep(for: .milliseconds(600))

        let onScreen = descendants(of: host.view, as: UIScrollView.self)
            .filter { !($0 is UITextView) && isEffectivelyVisible($0) }
        #expect(onScreen.contains { $0 === homeScroll }, "the original scroll view is not in the visible hierarchy after returning to Home")
        #expect(abs(homeScroll.contentOffset.y - targetOffset.y) < 1, "the Home scroll position was lost: \(homeScroll.contentOffset.y)")
    }

    // MARK: - Helpers

    private func present(_ appState: AppState) async throws -> (UIWindow, UIViewController) {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has no window scene"
        )
        let host = UIHostingController(rootView: AppRootView(appState: appState))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.windowLevel = .alert + 1
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(1))
        return (window, host)
    }

    private func dismiss(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func descendants<T: UIView>(of view: UIView, as type: T.Type) -> [T] {
        var found: [T] = []
        if let hit = view as? T { found.append(hit) }
        for subview in view.subviews { found.append(contentsOf: descendants(of: subview, as: type)) }
        return found
    }

    /// Neither the view nor any ancestor is hidden or fully transparent, and the view lies within the window bounds
    private func isEffectivelyVisible(_ view: UIView) -> Bool {
        guard let window = view.window else { return false }
        var current: UIView? = view
        while let node = current {
            if node.isHidden || node.alpha < 0.01 { return false }
            current = node.superview
        }
        let frame = view.convert(view.bounds, to: window)
        return frame.intersects(window.bounds) && frame.width > 0 && frame.height > 0
    }

    private func accessibilityElement(labeled label: String, traits: UIAccessibilityTraits, in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func search(_ node: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
            if node.isAccessibilityElement, node.accessibilityLabel == label, node.accessibilityTraits.contains(traits) {
                return node
            }
            var children: [NSObject] = []
            if let elements = node.accessibilityElements as? [NSObject] {
                children.append(contentsOf: elements)
            } else {
                let count = node.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in 0..<count {
                        if let child = node.accessibilityElement(at: index) as? NSObject { children.append(child) }
                    }
                }
            }
            if let view = node as? UIView { children.append(contentsOf: view.subviews) }
            for child in children {
                if let hit = search(child) { return hit }
            }
            return nil
        }
        return search(root)
    }
}

private extension String {
    func slice(from startMarker: String, to endMarker: String) -> String? {
        guard let start = range(of: startMarker),
              let end = range(of: endMarker, range: start.upperBound..<endIndex) else {
            return nil
        }
        return String(self[start.lowerBound..<end.lowerBound])
    }
}
