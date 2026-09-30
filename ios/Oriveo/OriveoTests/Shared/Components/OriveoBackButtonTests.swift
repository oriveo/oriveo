import SwiftUI
import Testing
import UIKit
@testable import Oriveo

@Suite("OriveoBackButton", .serialized)
@MainActor
struct OriveoBackButtonTests {

    @Test("chevron scales the design's 24-grid path into the 22pt icon box")
    func chevronMatchesDesignPath() {
        let size = OriveoBackButton.iconSize
        let bounds = OriveoBackChevron().path(in: CGRect(x: 0, y: 0, width: size, height: size)).boundingRect
        let scale = size / 24
        #expect(abs(bounds.minX - 8 * scale) < 0.001)
        #expect(abs(bounds.maxX - 14.5 * scale) < 0.001)
        #expect(abs(bounds.minY - 5.5 * scale) < 0.001)
        #expect(abs(bounds.maxY - 18.5 * scale) < 0.001)
    }

    @Test("close × scales the design's 24-grid path and uses the same 44×44 target")
    func closeGlyphMatchesDesignPath() {
        let size = OriveoBackButton.iconSize
        let bounds = OriveoCloseGlyph().path(in: CGRect(x: 0, y: 0, width: size, height: size)).boundingRect
        let scale = size / 24
        #expect(abs(bounds.minX - 7 * scale) < 0.001)
        #expect(abs(bounds.maxX - 17 * scale) < 0.001)
        #expect(abs(bounds.minY - 7 * scale) < 0.001)
        #expect(abs(bounds.maxY - 17 * scale) < 0.001)

        let host = UIHostingController(rootView: OriveoCloseButton(accessibilityLabel: "Close") {})
        #expect(host.sizeThatFits(in: CGSize(width: 400, height: 400)) == CGSize(width: 44, height: 44))
    }

    @Test("44×44 target, 22pt icon box, 11pt margin inset")
    func metrics() {
        #expect(OriveoBackButton.hitSize == 44)
        #expect(OriveoBackButton.iconSize == 22)
        #expect(OriveoBackButton.edgeInset == 11)

        let host = UIHostingController(rootView: OriveoBackButton {})
        let fitted = host.sizeThatFits(in: CGSize(width: 400, height: 400))
        #expect(fitted == CGSize(width: 44, height: 44))
    }

    @Test("VoiceOver reads Back with the button trait, and activating it runs the caller's action")
    func accessibilityAndAction() async throws {
        var tapped = 0
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: OriveoBackButton {
            tapped += 1
        })
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(500))

        let element = try #require(findElement(labeled: L10n.tr("Back"), in: window), "back button not found in the accessibility tree")
        #expect(element.accessibilityTraits.contains(.button))
        #expect(element.accessibilityActivate())
        #expect(tapped == 1)
    }

    /// Page back buttons and sheet close buttons go through the shared components instead of
    /// drawing their own SF Symbols. Scans the sources: these call sites used to draw a custom
    /// chevron or a × on a round fill, and reverting any of them turns this red.
    @Test("chat back, token usage sheet and cross-check sheet use the shared buttons")
    func migratedCallSitesUseSharedButtons() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Shared/Components
            .deletingLastPathComponent()   // Shared
            .deletingLastPathComponent()   // OriveoTests
            .deletingLastPathComponent()   // Oriveo
            .appendingPathComponent("Oriveo")
        let expectations: [(file: String, component: String)] = [
            ("Features/Chat/ChatToolbar.swift", "OriveoBackButton { appState.pop() }"),
            ("Features/Chat/Cells/AssistantMetadataView.swift", "OriveoCloseButton(accessibilityLabel: L10n.tr(\"Close\"))"),
            ("Features/Chat/CrosscheckSheet.swift", "OriveoCloseButton(accessibilityLabel: L10n.tr(\"Close\", table: .notes))"),
        ]
        for (file, component) in expectations {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            #expect(source.contains(component), "\(file) does not use the shared component: \(component)")
        }
        let toolbar = try String(contentsOf: root.appendingPathComponent("Features/Chat/ChatToolbar.swift"), encoding: .utf8)
        #expect(!toolbar.contains("\"chevron.backward\""), "ChatToolbar.swift still draws its own back chevron")
    }

    private func findElement(labeled label: String, in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func search(_ node: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
            if node.isAccessibilityElement, node.accessibilityLabel == label { return node }
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
