import SwiftUI

struct ChatBubble: View, Equatable {
    let message: ChatMessage
    var displayText: String?
    var maxBubbleWidth: CGFloat = 320
    var showMetadata: Bool = true
    var resolvedProviderName: String?
    var resolvedModelName: String?
    var relayKind: RelayKind?
    var retryCapabilitySelection: ChatCapabilitySelection?
    var renderHint: MarkdownRenderHint?
    var onContentHeightDidChange: ((CGFloat) -> Void)?
    var onRetry: (() -> Void)?
    var onEdit: (() -> Void)?

    static func == (lhs: ChatBubble, rhs: ChatBubble) -> Bool {
        lhs.message == rhs.message &&
            lhs.displayText == rhs.displayText &&
            lhs.maxBubbleWidth == rhs.maxBubbleWidth &&
            lhs.showMetadata == rhs.showMetadata &&
            lhs.resolvedProviderName == rhs.resolvedProviderName &&
            lhs.resolvedModelName == rhs.resolvedModelName &&
            lhs.retryCapabilitySelection == rhs.retryCapabilitySelection &&
            lhs.renderHint == rhs.renderHint &&
            (lhs.onRetry != nil) == (rhs.onRetry != nil) &&
            (lhs.onEdit != nil) == (rhs.onEdit != nil)
    }

    var body: some View {
        if message.role == .user {
            UserMessageBubble(
                message: message,
                maxBubbleWidth: maxBubbleWidth,
                showMetadata: showMetadata,
                onEdit: onEdit
            )
        } else {
            AssistantMessageView(
                message: message,
                displayText: displayText,
                showMetadata: showMetadata,
                resolvedProviderName: resolvedProviderName,
                resolvedModelName: resolvedModelName,
                relayKind: relayKind,
                renderHint: renderHint,
                onContentHeightDidChange: onContentHeightDidChange,
                onRetry: onRetry
            )
        }
    }
}
