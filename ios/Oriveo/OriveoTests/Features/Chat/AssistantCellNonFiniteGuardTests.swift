import Testing
import UIKit
@testable import Oriveo

/// Guards: the self-size entry and image height normalize non-finite input.
@Suite("Assistant cell self-sizing - non-finite input guards")
@MainActor
struct AssistantCellNonFiniteGuardTests {
    @Test("the target width only lets finite positive values through")
    func fittingWidth() {
        #expect(AssistantMessageCell.sanitizedFittingWidth(proposed: 393, fallbacks: []) == 393)
        #expect(AssistantMessageCell.sanitizedFittingWidth(proposed: .infinity, fallbacks: [402]) == 402)
        #expect(AssistantMessageCell.sanitizedFittingWidth(proposed: .nan, fallbacks: [.nan, 320]) == 320)
        #expect(AssistantMessageCell.sanitizedFittingWidth(proposed: .greatestFiniteMagnitude, fallbacks: [])
            == AssistantMessageCell.maxFittingWidth)
        #expect(AssistantMessageCell.sanitizedFittingWidth(proposed: -.infinity, fallbacks: [.infinity, -5]) == 1)
        #expect(AssistantMessageCell.sanitizedFittingWidth(proposed: 0, fallbacks: [0]) == 1)
    }

    @Test("a non-finite measured height falls back to the previous height")
    func fittedHeight() {
        #expect(AssistantMessageCell.sanitizedFittedHeight(120.2, fallback: 80) == 121)
        #expect(AssistantMessageCell.sanitizedFittedHeight(.infinity, fallback: 80) == 80)
        #expect(AssistantMessageCell.sanitizedFittedHeight(.nan, fallback: .nan) == 1)
        #expect(AssistantMessageCell.sanitizedFittedHeight(-3, fallback: 80) == 1)
    }

    @Test("image container height: a zero or non-finite ratio yields nothing, extreme ratios clamp to the cap")
    func imageContainerHeight() {
        #expect(UIKitAssistantImageView.containerHeight(width: 392, ratio: 0) == nil)
        #expect(UIKitAssistantImageView.containerHeight(width: 392, ratio: .nan) == nil)
        #expect(UIKitAssistantImageView.containerHeight(width: 392, ratio: .infinity) == nil)
        #expect(UIKitAssistantImageView.containerHeight(width: .infinity, ratio: 1) == nil)
        #expect(UIKitAssistantImageView.containerHeight(width: 0, ratio: 1) == nil)
        #expect(UIKitAssistantImageView.containerHeight(width: 392, ratio: 2) == 196)
        #expect(UIKitAssistantImageView.containerHeight(width: 392, ratio: 1e-300) == UIKitAssistantImageView.maxContainerHeight)
        #expect(UIKitAssistantImageView.containerHeight(width: 392, ratio: 1e6) == 1)
    }

    @Test("a cell with a memory bar still self-sizes to a finite height when layout proposes a non-positive or huge width", arguments: [
        // inf / NaN cannot get in: UICollectionViewLayoutAttributes.setSize rejects non-finite sizes itself.
        0, -10, CGFloat.greatestFiniteMagnitude,
    ])
    func nonFiniteAttributesWidth(width: CGFloat) throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 900))
        window.isHidden = false
        let message = ChatMessage(
            id: UUID(), role: .assistant, text: String(repeating: "Body text goes here, ", count: 40),
            reasoningText: nil,
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            estimatedCost: 0.01, state: .delivered, attachments: nil, citations: nil
        )
        let bar = MemorySuggestionBar(messageID: message.id, content: "The user prefers replies in Simplified Chinese")
        let rows = ChatCollectionProjectionBuilder.makeRows(from: [message], metadata: .empty, memorySuggestion: bar)
        let plan = ChatCollectionProjectionBuilder.makeSnapshotPlan(from: rows, providerMetadataVersion: 0)
        let model = try #require(plan.renderModelsByID[message.id])
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 440, height: 100))
        cell.configure(model: model, parentViewController: UIViewController(),
                       onContentHeightDidChange: nil, onRetry: nil, onContinue: nil)
        window.addSubview(cell)
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.size = CGSize(width: width, height: 120)
        let preferred = cell.preferredLayoutAttributesFitting(attributes)
        #expect(preferred.size.width.isFinite && preferred.size.width > 0)
        #expect(preferred.size.height.isFinite && preferred.size.height > 0)
        window.isHidden = true
    }

    @Test("the memory bar and directive bar button titles are single-line and do not wrap with the width", arguments: [440, 120, 1] as [CGFloat])
    func barButtonTitlesAreSingleLine(width: CGFloat) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 900))
        window.isHidden = false
        let memoryBar = MemorySuggestionBarView()
        memoryBar.apply(MemorySuggestionBar(messageID: UUID(), content: "The user prefers replies in Simplified Chinese"))
        let directiveBar = DirectiveSuggestionBarView()
        for bar in [memoryBar, directiveBar] as [UIView] {
            bar.frame = CGRect(x: 0, y: 0, width: width, height: 200)
            window.addSubview(bar)
            bar.layoutIfNeeded()
            let buttons = Self.descendants(of: bar).compactMap { $0 as? UIButton }
            #expect(buttons.count >= 2)
            for button in buttons {
                #expect(button.configuration?.titleLineBreakMode == .byTruncatingTail)
                #expect(button.titleLabel?.numberOfLines == 1, "\(button.accessibilityIdentifier ?? "?") title can wrap")
            }
        }
        window.isHidden = true
    }

    @Test("every titled configuration button in the chat cell self-sizing subtree truncates to a single line")
    func cellSubtreeTitledButtonsAreSingleLine() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 900))
        window.isHidden = false
        let recovery = UIKitRecoveryCard(config: .init(
            title: "Something went wrong", message: "The request failed, please try again.", primaryTitle: "Regenerate answer",
            secondaryTitle: "Switch model", tertiaryTitle: "View details", tone: .warning, technicalDetail: "detail",
            actionsEnabled: true, primaryAction: {}, secondaryAction: {}, tertiaryAction: {}, onDismiss: nil
        ))
        let searchError = UIKitSearchErrorCard()
        _ = searchError.apply(SearchErrorCardPresentation(
            titleKey: "chatError.serviceError", serviceName: "Tavily",
            primary: .init(titleKey: "action.retry", titleArgument: nil, action: .retry, external: false),
            secondary: .init(titleKey: "action.viewSetupGuide", titleArgument: nil, action: .viewSetupGuide, external: true)
        ))
        let roots: [UIView] = [
            recovery,
            searchError,
            UIKitCodeBlockCard(language: "swift", content: "let x = 1\nprint(x)", parentViewController: nil),
            UIKitToolStepsView(),
            AssistantMetadataView(frame: .zero),
            UserMessageCell(frame: CGRect(x: 0, y: 0, width: 440, height: 100)),
            AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 440, height: 100)),
        ]
        var titled = 0
        for root in roots {
            root.frame = CGRect(x: 0, y: 0, width: 120, height: 400)
            window.addSubview(root)
            root.layoutIfNeeded()
            for button in Self.descendants(of: root).compactMap({ $0 as? UIButton }) {
                guard let config = button.configuration,
                      config.title != nil || config.attributedTitle != nil else { continue }
                titled += 1
                let name = "\(type(of: root)) / \(button.accessibilityIdentifier ?? config.title ?? "?")"
                #expect(config.titleLineBreakMode == .byTruncatingTail, "\(name) title can wrap")
                if let label = button.titleLabel {
                    #expect(label.numberOfLines == 1, "\(name) numberOfLines=\(label.numberOfLines)")
                }
            }
        }
        // Guard against scanning no button at all after a construction change, which would make the assertions vacuous.
        #expect(titled >= 8)
        window.isHidden = true
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
