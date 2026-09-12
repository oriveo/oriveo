import SwiftUI
import Testing
import UIKit
@testable import Oriveo

@Suite("ConversationRow", .serialized)
@MainActor
struct ConversationRowTests {
    private func withOpenAIMetadata<Result>(
        displayName: String = "GPT-4o Latest",
        _ operation: () async throws -> Result
    ) async throws -> Result {
        await MetadataClient.shared.resetForTesting()

        do {
            try await MetadataClient.shared.loadForTesting(json: """
            {
              "version": 1,
              "updatedAt": "2026-04-10T00:00:00Z",
              "providers": {
                "openAI": {
                  "displayName": "OpenAI",
                  "defaultModelId": "gpt-4o",
                  "resolveMap": {
                    "gpt-4o": "gpt-4o",
                    "gpt-4o-2024-08-06": "gpt-4o"
                  },
                  "models": {
                    "gpt-4o": {
                      "canonicalModelId": "gpt-4o",
                      "displayName": "\(displayName)"
                    }
                  }
                }
              }
            }
            """)

            let result = try await operation()
            await MetadataClient.shared.resetForTesting()
            return result
        } catch {
            await MetadataClient.shared.resetForTesting()
            throw error
        }
    }

    @Test("Resolved Model Name Avoids Catalog Projection")
    func resolvedModelNameAvoidsCatalogProjection() async throws {
        try await withOpenAIMetadata {
            let provider = TestFactories.makeProvider(
                kind: .openAI,
                models: [
                    TestFactories.makeModel(
                        id: "gpt-4o",
                        name: "GPT-4o Local",
                        canonicalModelId: "gpt-4o"
                    )
                ]
            )
            let conversation = TestFactories.makeConversation(
                providerID: provider.id,
                modelID: "gpt-4o-2024-08-06"
            )

            ProviderCatalogResolver.debugResolveCallCount = 0
            let resolvedModelName = ConversationRow.resolveModelName(
                for: conversation,
                provider: provider,
                metadata: MetadataClient.shared
            )

            #expect(resolvedModelName == "GPT-4o Latest")
            #expect(ProviderCatalogResolver.debugResolveCallCount == 0)
        }
    }

    @Test("the row preview renders one truncated line inside the row width, and the row is 90pt tall")
    func previewRendersSingleTruncatedLineWithinRow() async throws {
        let rowWidth: CGFloat = 353
        let provider = TestFactories.makeProvider(kind: .anthropic)
        let conversation = TestFactories.makeConversation(
            title: "Explain how trigonometry works",
            providerID: provider.id,
            providerKind: .anthropic,
            previewText: String(repeating: "Trigonometry studies angles and side lengths in triangles. ", count: 6),
            estimatedCost: 0.01
        )
        let row = ConversationRow(
            conversation: conversation,
            provider: provider,
            resolvedModelName: "Claude Sonnet 4.5",
            grouped: true
        )
        let host = UIHostingController(rootView: row.frame(width: rowWidth))
        // Measure the row alone: keep the window safe area (status bar / home indicator) out of the host's sizeThatFits
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()

        let label = try #require(firstDescendant(of: host.view, as: UILabel.self), "the preview should be rendered by NativeTextLabel (a UILabel)")
        #expect(label.numberOfLines == ConversationRow.previewLineLimit)
        #expect(label.numberOfLines == 1)
        #expect(label.lineBreakMode == .byTruncatingTail, "a single line needs an ellipsis")

        // Text column width = row width - 16 on each side - avatar 30 - spacing 12
        let textColumnWidth = rowWidth - 16 - 16 - ConversationRow.avatarSize - 12
        #expect(label.bounds.width <= textColumnWidth + 0.5, "the preview pushed the row out at its natural width: \(label.bounds.width) > \(textColumnWidth)")

        // 15 + title 20 + 4 + preview 18 + 4 + bottom row 14 + 15
        let height = host.sizeThatFits(in: CGSize(width: rowWidth, height: 1000)).height
        #expect(abs(height - 90) <= 2, "row height \(height) deviates from the 90 in the design")
    }

    @Test("at least 6 between title and cost and 8 between model name and message count, not the 16 a Spacer would add")
    func rowGapsFollowDesignFlexGaps() async throws {
        let rowWidth: CGFloat = 353
        let provider = TestFactories.makeProvider(kind: .anthropic)
        let title = "How to write key achievements in a quarterly report so every reviewer reads them"
        let modelName = "Claude Sonnet 4.5 Extended Thinking Preview (2026-09-11)"
        var conversation = TestFactories.makeConversation(
            title: title,
            providerID: provider.id,
            providerKind: .anthropic,
            previewText: "Lead with outcomes, quantify where you can.",
            estimatedCost: 0.02
        )
        conversation.messageCountOverride = 6
        let row = ConversationRow(
            conversation: conversation,
            provider: provider,
            resolvedModelName: modelName,
            grouped: true
        )
        let host = UIHostingController(rootView: row.frame(width: rowWidth))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()

        let titleFrame = try #require(accessibilityFrame(of: title, in: host.view), "title element not found")
        let costFrame = try #require(accessibilityFrame(of: conversation.estimatedCostText, in: host.view), "cost element not found")
        let modelFrame = try #require(accessibilityFrame(of: modelName, in: host.view), "model name element not found")
        let messagesFrame = try #require(
            accessibilityFrame(of: L10n.tr("Messages", table: .backup), in: host.view),
            "the message count icon should carry the Messages accessibility label"
        )

        // Truncated text ends on a glyph boundary and leaves a little slack (a CSS ellipsis behaves the same), so
        // the measurement is gap plus slack. The old layout (a Spacer inside spacing 6) bottomed out at 16 plus
        // slack, and the test only requires strictly less than that floor
        let titleGap = costFrame.minX - titleFrame.maxX
        #expect(titleGap >= 5 && titleGap < 16, "title-to-cost gap \(titleGap); the design says 6 (the old layout's floor was 16)")
        let bottomGap = messagesFrame.minX - modelFrame.maxX
        #expect(bottomGap >= 7 && bottomGap < 16, "model-to-count gap \(bottomGap); the design says 8 (the old layout's floor was 16)")
    }

    @Test("without a cost the title does not reserve space: a title that just fits is shown in full")
    func titleWithoutCostUsesFullWidth() async throws {
        let rowWidth: CGFloat = 353
        let textColumnWidth = rowWidth - 16 - 16 - ConversationRow.avatarSize - 12
        let title = "Translate onboarding copy to Japanese"
        let natural = (title as NSString).size(withAttributes: [
            .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
            .kern: -0.2,
        ]).width
        // Fixture precondition: the title is narrower than the text column but wider than what the old layout
        // (another 10pt reserved) left for it
        try #require(natural < textColumnWidth - 1 && natural > textColumnWidth - 10, "fixture title width \(natural) is outside the discriminating range")

        let provider = TestFactories.makeProvider(kind: .qwen)
        let conversation = TestFactories.makeConversation(
            title: title,
            providerID: provider.id,
            providerKind: .qwen,
            previewText: "Preview",
            estimatedCost: 0
        )
        let host = UIHostingController(rootView: ConversationRow(
            conversation: conversation,
            provider: provider,
            resolvedModelName: "Qwen3 235B",
            grouped: true
        ).frame(width: rowWidth))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()

        let titleFrame = try #require(accessibilityFrame(of: title, in: host.view))
        #expect(titleFrame.width >= natural - 1, "the title was truncated: \(titleFrame.width) < natural width \(natural)")
    }

    @Test("a single-line UILabel's sizeThatFits reports the full natural width, so NativeTextLabel must clamp to the proposal itself")
    func singleLineLabelSizeThatFitsIgnoresWidthConstraint() {
        let label = UILabel()
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)
        label.text = String(repeating: "wide ", count: 60)
        let fitted = label.sizeThatFits(CGSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        #expect(fitted.width > 100)
    }

    /// Finds an element by label in the host's accessibility tree and returns its screen frame (SwiftUI Text has no
    /// UIKit view, so this is the only place it can be measured)
    private func accessibilityFrame(of label: String, in root: NSObject) -> CGRect? {
        var visited = Set<ObjectIdentifier>()
        func search(_ node: NSObject) -> CGRect? {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
            if node.isAccessibilityElement, node.accessibilityLabel == label {
                return node.accessibilityFrame
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

    private func firstDescendant<T: UIView>(of view: UIView, as type: T.Type) -> T? {
        if let hit = view as? T { return hit }
        for subview in view.subviews {
            if let hit = firstDescendant(of: subview, as: type) { return hit }
        }
        return nil
    }
}
