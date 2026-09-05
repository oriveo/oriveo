import Combine
import Testing
import UIKit
@testable import Oriveo

/// Regression suite for a recovery-card layout collapse.
///
/// Symptom: the failure card of the last assistant message overlapped the avatar and model-name
/// header row, the previous user bubble showed through beneath it, and the card's action button was
/// pushed out of the cell.
///
/// Cause: embedding the card with `contentStack.insertArrangedSubview(card, at:)` into a
/// UIStackView that had already been laid out. In that situation the stack view only builds the
/// "next item top == new item bottom + spacing" half of the constraint chain; the new item never
/// gets a top constraint of its own. Two consequences follow:
/// - the cell's natural height does not include the card at all, so the layout keeps the old height;
/// - the card is positioned from its bottom only, so its top lands at a negative y and the whole
///   card slides up over the header row and the preceding bubble.
/// Going from generating to failed reconfigures an existing cell, so the bug always reproduces
/// there, while leaving and re-entering the conversation reloads fresh cells and looks fine.
///
/// Fix: the card lives in a permanent arranged slot (`recoveryCardHost`) that is collapsed with
/// `isHidden`, so the chain is complete from the first layout pass and never changes afterwards;
/// embedding and removing the card each notify the cell to remeasure its content.
@Suite("Recovery card layout collapse")
@MainActor
struct RecoveryCardLayoutCollapseTests {
    private static let width: CGFloat = 393

    // MARK: - Fixtures

    private static func failedModel(
        errorDetail: String? = "HTTP 429 rate limited",
        messageID: UUID = UUID()
    ) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        let msg = ChatMessage(
            id: messageID, role: .assistant, text: "",
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            state: .failed,
            errorTitle: "Send Failed",
            errorDetail: errorDetail
        )
        return renderModel(for: msg, isStreaming: false)
    }

    private static func generatingModel(messageID: UUID) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        let msg = ChatMessage(
            id: messageID, role: .assistant, text: "",
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            state: .generating
        )
        return renderModel(for: msg, isStreaming: true)
    }

    private static func renderModel(
        for msg: ChatMessage,
        isStreaming: Bool
    ) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: msg.id, message: msg, presentationKind: .assistant,
            showMetadata: true, resolvedProviderName: "OpenAI", resolvedModelName: "GPT-4o",
            relayKind: nil, renderHint: nil, topPadding: 16,
            displayText: "", textHash: 0, isStreaming: isStreaming,
            providerMetadataVersion: 0, isLastInConversation: true
        )
    }

    private static func makeCardConfig(
        title: String,
        message: String,
        technicalDetail: String?,
        expanded: Bool
    ) -> UIKitRecoveryCard.Config {
        UIKitRecoveryCard.Config(
            title: title,
            message: message,
            primaryTitle: L10n.tr("Retry"),
            secondaryTitle: nil,
            tertiaryTitle: nil,
            tone: .danger,
            technicalDetail: technicalDetail,
            actionsEnabled: true,
            primaryAction: {},
            secondaryAction: nil,
            tertiaryAction: nil,
            onDismiss: {},
            showsTechnicalDetail: expanded
        )
    }

    private static func recoveryConfig(
        for model: ChatCollectionProjectionBuilder.MessageRenderModel,
        expanded: Bool = false
    ) -> UIKitRecoveryCard.Config? {
        AssistantMessageRecoveryBuilder.makeConfig(
            for: model, isSendingMessage: false, isDismissed: false,
            isTechnicalDetailExpanded: expanded,
            onRetry: {}, onContinue: {}, onRegenerate: {}, onEditMessage: {},
            onSwitchModelRequested: {}, onDismiss: {},
            onTechnicalDetailVisibilityChanged: { _ in }
        )
    }

    /// The cell's natural height, measured with the collection view's required
    /// `UIView-Encapsulated-Layout-Height` constraint disabled - otherwise the measurement always
    /// equals the current frame height and says nothing about how much room the content needs.
    private static func naturalHeight(of cell: AssistantMessageCell) -> CGFloat {
        let encapsulated = cell.contentView.constraints.filter {
            ($0.identifier ?? "").contains("Encapsulated-Layout-Height")
        }
        encapsulated.forEach { $0.isActive = false }
        defer { encapsulated.forEach { $0.isActive = true } }
        return cell.contentView.systemLayoutSizeFitting(
            CGSize(width: cell.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    /// Required height versus actual frame height for every visible label in the card, used to
    /// detect clipped or squeezed text.
    private static func clippedLabels(in root: UIView) -> [(String, CGFloat, CGFloat)] {
        var result: [(String, CGFloat, CGFloat)] = []
        func walk(_ v: UIView) {
            if v.isHidden || v.alpha == 0 { return }
            if let label = v as? UILabel, let text = label.text, !text.isEmpty, label.bounds.width > 0 {
                let needed = label.sizeThatFits(
                    CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)
                ).height
                if needed - label.bounds.height > 0.5 {
                    result.append((String(text.prefix(24)), needed, label.bounds.height))
                }
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return result
    }

    // MARK: - Insertion timing matrix

    /// The card must count toward the cell's natural height for all three insertion timings:
    /// a brand new cell, a cell that has already been laid out, and the two-phase
    /// generating-then-failed path. The broken implementation left the card out of the natural
    /// height entirely in the last two cases, which is what caused the overlap.
    @Test("the card counts toward cell height for every insertion timing")
    func cardCountsTowardCellHeightForEveryInsertTiming() throws {
        for (label, preLayout, twoPhase) in [
            ("fresh cell", false, false),
            ("already laid out cell", true, false),
            ("generating then failed", true, true),
        ] {
            let id = UUID()
            let model = Self.failedModel(messageID: id)
            let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: Self.width, height: 100))
            let parent = UIViewController()
            if twoPhase {
                cell.configure(
                    model: Self.generatingModel(messageID: id), parentViewController: parent,
                    onContentHeightDidChange: nil, onRetry: nil, onContinue: nil
                )
                cell.setNeedsLayout()
                cell.layoutIfNeeded()
            }
            cell.configure(
                model: model, parentViewController: parent,
                onContentHeightDidChange: nil, onRetry: nil, onContinue: nil
            )
            if preLayout {
                cell.setNeedsLayout()
                cell.layoutIfNeeded()
            }
            cell.embedRecoveryCard(try #require(Self.recoveryConfig(for: model)))

            let card = try #require(cell.recoveryCard)
            let natural = Self.naturalHeight(of: cell)
            let cardHeight = card.systemLayoutSizeFitting(
                CGSize(width: Self.width - 48, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
            #expect(
                natural >= cardHeight,
                Comment(rawValue: "\(label): natural height \(natural) < card height \(cardHeight), the card is missing from the constraint chain")
            )

            // Once laid out at its natural height the card must sit entirely inside the cell; a
            // negative y is the direct evidence of the card riding up over the header row.
            cell.frame = CGRect(x: 0, y: 0, width: Self.width, height: natural)
            cell.setNeedsLayout()
            cell.layoutIfNeeded()
            let frameInCell = card.convert(card.bounds, to: cell)
            #expect(frameInCell.minY >= 0, Comment(rawValue: "\(label): card minY=\(frameInCell.minY) is negative, it now covers the header row"))
            #expect(
                frameInCell.maxY <= natural + 0.5,
                Comment(rawValue: "\(label): card maxY=\(frameInCell.maxY) overflows the cell height \(natural)")
            )
        }
    }

    // MARK: - End to end through the real view controller

    private func spin(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    @Test("after generating turns into failed the card overlaps neither header nor metadata")
    func realControllerGeneratingToFailedHasNoOverlap() throws {
        let vc = ChatListViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: 844))
        window.rootViewController = vc
        window.makeKeyAndVisible()
        vc._testCompleteInitialAppearance()
        vc.view.layoutIfNeeded()
        defer { window.isHidden = true }

        let convID = UUID()
        let question = ChatMessage(
            id: UUID(), role: .user, text: "Rewrite this snippet so it is concurrency safe",
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            state: .delivered
        )
        let answerID = UUID()

        func drive(_ assistant: ChatMessage, streamingID: UUID?, revision: UInt) {
            let vm = ChatCollectionViewModel(
                conversationID: convID, messageRevision: revision,
                rows: ChatCollectionProjectionBuilder.makeRows(from: [question, assistant], metadata: .empty),
                isSendingMessage: streamingID != nil, streamingMessageID: streamingID, streamingText: "",
                pendingAnchorUserMessageID: nil, pendingSearchScrollTarget: nil,
                isBootstrappingPersistedConversation: false,
                retryCapabilitySelection: ChatCapabilitySelection())
            vc.update(
                viewModel: vm, providerMetadataVersion: 0,
                streamingPublisher: Empty<Void, Never>().eraseToAnyPublisher(),
                streamingReasoningPublisher: Empty<ReasoningStreamDelta, Never>().eraseToAnyPublisher(),
                streamingTextProvider: { "" }, streamingReasoningSnapshotProvider: { nil },
                onRetry: { _ in }, onContinue: { _ in }, onRegenerate: { _ in },
                onEditMessage: { _ in }, onSwitchModel: {},
                onAnchorUserMessageConsumed: { _ in })
            vc.view.layoutIfNeeded()
        }

        drive(Self.generatingModel(messageID: answerID).message, streamingID: answerID, revision: 2)
        spin(0.2)
        drive(Self.failedModel(messageID: answerID).message, streamingID: nil, revision: 3)
        spin(0.5)

        let cell = try #require(vc._testCellForMessage(answerID) as? AssistantMessageCell)
        let card = try #require(cell.recoveryCard, "a failed last message must carry a recovery card")
        let natural = Self.naturalHeight(of: cell)
        #expect(
            cell.frame.height >= natural - 1,
            Comment(rawValue: "cell height \(cell.frame.height) did not follow the natural content height \(natural), so the layout never remeasured and the card is squeezed")
        )

        let cardFrame = card.convert(card.bounds, to: cell)
        let headerFrame = cell.headerStack.convert(cell.headerStack.bounds, to: cell)
        let metaFrame = cell.metadataView.convert(cell.metadataView.bounds, to: cell)
        #expect(cardFrame.minY >= 0, Comment(rawValue: "card minY=\(cardFrame.minY) is negative, the card rode up over the header row and the preceding user bubble"))
        #expect(
            cardFrame.minY >= headerFrame.maxY,
            Comment(rawValue: "card (\(cardFrame.minY)) overlaps the header row (\(headerFrame.maxY))")
        )
        #expect(
            metaFrame.minY + 0.5 >= cardFrame.maxY,
            Comment(rawValue: "metadata row (\(metaFrame.minY)) overlaps the bottom of the card (\(cardFrame.maxY))")
        )
        #expect(
            Self.clippedLabels(in: card).isEmpty,
            Comment(rawValue: "text inside the card is squeezed: \(Self.clippedLabels(in: card))")
        )
    }

    // MARK: - Body length, expansion state and colour scheme

    /// One line, two lines (the length that collapsed) and four lines (German- or Russian-sized
    /// copy) of body text, times technical detail expanded or collapsed, times light and dark:
    /// the card must always fit inside the cell without squeezing or clipping its text.
    @Test("body length, technical detail state and colour scheme never collapse the card")
    func bodyLengthsAndDetailStatesNeverCollapse() throws {
        let bodies: [(String, String)] = [
            ("one line", "The request was rejected."),
            ("two lines", "This model is not available on the current key. Pick another model to continue, "
                + "or update the key for this provider."),
            ("four lines", "Die wöchentlichen Freikontingente decken dieses Modell nicht ab. "
                + "Laden Sie Ihr KI-Guthaben auf, um fortzufahren, oder wählen Sie ein Modell, "
                + "das im wöchentlichen Freikontingent enthalten ist."),
        ]
        for (bodyLabel, body) in bodies {
            for expanded in [false, true] {
                for style in [UIUserInterfaceStyle.light, .dark] {
                    let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: Self.width, height: 100))
                    cell.overrideUserInterfaceStyle = style
                    let parent = UIViewController()
                    let id = UUID()
                    cell.configure(
                        model: Self.generatingModel(messageID: id), parentViewController: parent,
                        onContentHeightDidChange: nil, onRetry: nil, onContinue: nil
                    )
                    cell.setNeedsLayout()
                    cell.layoutIfNeeded()
                    cell.configure(
                        model: Self.failedModel(messageID: id),
                        parentViewController: parent,
                        onContentHeightDidChange: nil, onRetry: nil, onContinue: nil
                    )
                    cell.setNeedsLayout()
                    cell.layoutIfNeeded()
                    cell.embedRecoveryCard(Self.makeCardConfig(
                        title: L10n.tr("Send Failed"),
                        message: body,
                        technicalDetail: "HTTP 429 rate limited request=abc123",
                        expanded: expanded
                    ))

                    let card = try #require(cell.recoveryCard)
                    let natural = Self.naturalHeight(of: cell)
                    cell.frame = CGRect(x: 0, y: 0, width: Self.width, height: natural)
                    cell.setNeedsLayout()
                    cell.layoutIfNeeded()

                    let ctx = "\(bodyLabel) expanded=\(expanded) style=\(style.rawValue)"
                    let cardFrame = card.convert(card.bounds, to: cell)
                    let metaFrame = cell.metadataView.convert(cell.metadataView.bounds, to: cell)
                    #expect(cardFrame.minY >= 0, Comment(rawValue: "\(ctx): card minY=\(cardFrame.minY) is negative"))
                    #expect(
                        cardFrame.maxY <= natural + 0.5,
                        Comment(rawValue: "\(ctx): card maxY=\(cardFrame.maxY) overflows the cell height \(natural)")
                    )
                    #expect(
                        metaFrame.minY + 0.5 >= cardFrame.maxY,
                        Comment(rawValue: "\(ctx): the metadata row overlaps the bottom of the card")
                    )
                    let clipped = Self.clippedLabels(in: card)
                    #expect(clipped.isEmpty, Comment(rawValue: "\(ctx): text is squeezed or clipped \(clipped)"))
                    if expanded {
                        let detail = Self.allLabels(in: card).first { ($0.text ?? "").hasPrefix("HTTP 429") }
                        #expect(detail?.isHidden == false, Comment(rawValue: "\(ctx): the expanded technical detail must be visible"))
                    }
                }
            }
        }
    }

    /// While the cell frame lags behind the natural height, the only place allowed to absorb the
    /// difference is the low-priority bottom constraint of the outer stack. The card's own labels
    /// must never be compressed to make room.
    @Test("card labels are not compressed while the cell frame lags behind the natural height")
    func cardLabelsNotCompressedWhenCellFrameLagsBehindNaturalHeight() throws {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: Self.width, height: 400))
        let parent = UIViewController()
        let model = Self.failedModel()
        cell.configure(
            model: model, parentViewController: parent,
            onContentHeightDidChange: nil, onRetry: nil, onContinue: nil
        )
        cell.embedRecoveryCard(try #require(Self.recoveryConfig(for: model)))
        let card = try #require(cell.recoveryCard)
        let natural = Self.naturalHeight(of: cell)
        cell.frame = CGRect(x: 0, y: 0, width: Self.width, height: natural)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        let needed = Self.allLabels(in: card)
            .filter { !$0.isHidden && ($0.text?.isEmpty == false) }
            .map { ($0, $0.bounds.height) }

        // Simulate the lag window: a frame far smaller than the natural content height, which is
        // what a stale encapsulated layout height looks like for one frame.
        cell.frame = CGRect(x: 0, y: 0, width: Self.width, height: 90)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        for (label, settled) in needed {
            #expect(
                label.bounds.height >= settled - 1.0,
                Comment(rawValue: "\"\(label.text?.prefix(16) ?? "")\" was squeezed from \(settled) to \(label.bounds.height)")
            )
        }
    }

    /// The citations block shares the root cause: it also arrives only at the end of an answer and
    /// is therefore inserted into a cell that has already been laid out. With the broken chain it
    /// landed at a negative y and covered the answer body.
    @Test("a citations block added after layout counts toward the height and does not cover the body")
    func citationsBlockCountsTowardCellHeightAfterLayout() throws {
        let msg = ChatMessage(
            id: UUID(), role: .assistant, text: "An answer body with web search citations.",
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            state: .delivered
        )
        let model = Self.renderModel(for: msg, isStreaming: false)
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: Self.width, height: 200))
        let parent = UIViewController()
        cell.configure(
            model: model, parentViewController: parent,
            onContentHeightDidChange: nil, onRetry: nil, onContinue: nil
        )
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        let before = Self.naturalHeight(of: cell)

        cell.configureCitations(
            [
                Citation(url: "https://example.com/a", title: "First source"),
                Citation(url: "https://example.com/b", title: "Second source"),
            ],
            parentViewController: parent
        )
        let after = Self.naturalHeight(of: cell)
        let block = try #require(cell.citationsBlock)
        let blockHeight = block.systemLayoutSizeFitting(
            CGSize(width: Self.width - 48, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        #expect(blockHeight > 0)
        #expect(
            after >= before + blockHeight - 1,
            Comment(rawValue: "the citations block did not count toward the natural height (\(before) -> \(after), block height \(blockHeight))")
        )

        cell.frame = CGRect(x: 0, y: 0, width: Self.width, height: after)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        let blockFrame = block.convert(block.bounds, to: cell)
        let bodyFrame = cell.bodyStack.convert(cell.bodyStack.bounds, to: cell)
        #expect(blockFrame.minY >= 0, Comment(rawValue: "citations block minY=\(blockFrame.minY) is negative"))
        #expect(
            blockFrame.minY + 0.5 >= bodyFrame.maxY,
            Comment(rawValue: "the citations block (\(blockFrame.minY)) covers the answer body (\(bodyFrame.maxY))")
        )
    }

    private static func allLabels(in root: UIView) -> [UILabel] {
        var labels: [UILabel] = []
        if let label = root as? UILabel { labels.append(label) }
        root.subviews.forEach { labels.append(contentsOf: allLabels(in: $0)) }
        return labels
    }
}
