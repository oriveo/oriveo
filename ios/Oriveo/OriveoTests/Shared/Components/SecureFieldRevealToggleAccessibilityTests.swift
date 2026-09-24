import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// The eye button beside password and API key fields must have a localized accessibility label that follows its state.
///
/// These two components put only `Image(systemName: "eye" / "eye.slash")` in the button, so VoiceOver read the SF Symbol's
/// system name (English "Show" in all 16 app languages), ignoring the in-app language and never saying what it reveals.
/// This walks the accessibility tree of the real rendered views, reads the button label in each of the 16 languages, and
/// activates the button through accessibility (the same path as a VoiceOver double tap) to confirm the label follows the state.
@MainActor
@Suite("Secure field reveal toggle accessibility", .serialized)
struct SecureFieldRevealToggleAccessibilityTests {
    private static var retainedWindows: [UIWindow] = []

    private static let showKey = "Show characters"
    private static let hideKey = "Hide characters"

    enum Subject: CaseIterable {
        case labeledField
        case relayInlineRow

        @MainActor @ViewBuilder
        var view: some View {
            switch self {
            case .labeledField:
                OriveoLabeledField(
                    title: "API Key",
                    text: .constant("sk-test-secret"),
                    placeholder: "",
                    isSecure: true
                )
            case .relayInlineRow:
                RelayInlineTextRow(
                    title: "Token",
                    text: .constant("sk-test-secret"),
                    placeholder: "",
                    isSecure: true
                )
            }
        }
    }

    @Test("The eye button reads a localized Show label in all 16 languages, not a symbol name or English", arguments: Subject.allCases)
    func revealLabelIsLocalizedInEveryLanguage(_ subject: Subject) {
        // .system follows the simulator language and is not deterministic; pin each of the 16 languages instead.
        for language in LanguageOption.allCases where language != .system {
            withLanguage(language) {
                let expected = L10n.tr(Self.showKey)
                #expect(!expected.isEmpty)
                if language != .english {
                    #expect(expected != Self.showKey, "\(language.rawValue) has no translation for \"\(Self.showKey)\" and would read English")
                    #expect(L10n.tr(Self.hideKey) != Self.hideKey, "\(language.rawValue) has no translation for \"\(Self.hideKey)\" and would read English")
                }

                let window = render(subject.view)
                let labels = buttonLabels(in: window)
                #expect(
                    labels.contains(expected),
                    "\(language.rawValue): the eye button label should be \"\(expected)\"; button labels were \(labels)"
                )
                #expect(
                    !labels.contains { ["eye", "eye.slash", "Eye", "Show"].contains($0) },
                    "\(language.rawValue): the eye button still reads a symbol name: \(labels)"
                )
            }
        }
    }

    @Test("Activating switches the label to Hide, and activating again switches it back to Show", arguments: Subject.allCases)
    func labelFollowsRevealState(_ subject: Subject) throws {
        try withLanguage(.chineseSimplified) {
            let show = L10n.tr(Self.showKey)
            let hide = L10n.tr(Self.hideKey)
            #expect(show != hide)

            let window = render(subject.view)
            let showButton = try #require(button(labeled: show, in: window), "no \"\(show)\" button: \(buttonLabels(in: window))")
            #expect(showButton.accessibilityActivate(), "the \"\(show)\" button does not respond to accessibility activation")
            settle(window)

            let hideButton = try #require(
                button(labeled: hide, in: window),
                "after activation the label did not switch to \"\(hide)\": \(buttonLabels(in: window))"
            )
            #expect(button(labeled: show, in: window) == nil, "\"\(show)\" is still present after activation")
            #expect(hideButton.accessibilityActivate())
            settle(window)
            #expect(button(labeled: show, in: window) != nil, "activating again did not switch back to \"\(show)\": \(buttonLabels(in: window))")
        }
    }

    // MARK: - Helpers

    private func withLanguage(_ language: LanguageOption, _ body: () throws -> Void) rethrows {
        var preferences = AppPreferencesStore.load()
        let originalLanguage = preferences.language
        preferences.language = language
        AppPreferencesStore.save(preferences)
        L10n.invalidateCache()
        defer {
            var restored = AppPreferencesStore.load()
            restored.language = originalLanguage
            AppPreferencesStore.save(restored)
            L10n.invalidateCache()
        }
        try body()
    }

    private func render(_ content: some View) -> UIWindow {
        let host = UIHostingController(rootView: content.padding().frame(width: 360))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        settle(window)
        Self.retainedWindows.append(window)
        return window
    }

    private func settle(_ window: UIWindow) {
        for _ in 0..<6 {
            window.rootViewController?.view.setNeedsLayout()
            window.rootViewController?.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }
    }

    private func button(labeled label: String, in root: UIWindow) -> NSObject? {
        accessibilityButtons(in: root).first { $0.accessibilityLabel == label }
    }

    private func buttonLabels(in root: UIWindow) -> [String] {
        accessibilityButtons(in: root).map { $0.accessibilityLabel ?? "<nil>" }
    }

    private func accessibilityButtons(in root: NSObject) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        var found: [NSObject] = []
        func search(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            if node.isAccessibilityElement, node.accessibilityTraits.contains(.button) {
                found.append(node)
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
            children.forEach(search)
        }
        search(root)
        return found
    }
}
