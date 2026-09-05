import SwiftUI

private struct AssistantMessageContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct AssistantMessageView: View {
    let message: ChatMessage
    var displayText: String?
    var showMetadata: Bool = true
    var resolvedProviderName: String?
    var resolvedModelName: String?
    var relayKind: RelayKind?
    var renderHint: MarkdownRenderHint?
    var onContentHeightDidChange: ((CGFloat) -> Void)?
    var onRetry: (() -> Void)?

    @State private var lastReportedContentHeight: CGFloat?

    private var effectiveText: String {
        displayText ?? message.text
    }

    private var effectiveProviderName: String {
        resolvedProviderName ?? message.providerName
    }

    private var effectiveModelName: String {
        resolvedModelName ?? message.modelName
    }

    var body: some View {
        HStack(alignment: .top, spacing: OriveoTheme.Spacing.md) {
            ProviderBadgeIcon(
                kind: message.providerKind,
                size: 28,
                relayKind: relayKind
            )

            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) {
                HStack(spacing: OriveoTheme.Spacing.sm) {
                    Text(effectiveModelName)
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .frame(height: 28, alignment: .leading)

                    if message.state == .generating {
                        StatusPill(title: L10n.tr("Generating"), tone: .primary)
                    }
                }

                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
                    Group {
                        if message.state == .generating && effectiveText.isEmpty {
                            TypingIndicator()
                        } else {
                            MarkdownMessageView(
                                text: effectiveText,
                                isStreaming: message.state == .generating,
                                renderHint: renderHint
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let attachments = message.attachments, !attachments.isEmpty {
                        let imageAttachments = attachments.filter { $0.kind == .image }
                        if !imageAttachments.isEmpty {
                            ForEach(imageAttachments) { att in
                                AssistantImageAttachment(attachment: att)
                            }
                        }
                    }
                }
                .padding(.bottom, OriveoTheme.Spacing.xs)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: AssistantMessageContentHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                }
                .onPreferenceChange(AssistantMessageContentHeightPreferenceKey.self) { newHeight in
                    guard let onContentHeightDidChange, newHeight.isFinite else { return }
                    if let lastReportedContentHeight,
                       abs(lastReportedContentHeight - newHeight) < 4 {
                        return
                    }
                    lastReportedContentHeight = newHeight
                    onContentHeightDidChange(newHeight)
                }

                if showMetadata {
                    HStack(spacing: 6) {
                        Text(effectiveProviderName)
                        Text("•")
                        Text(effectiveModelName)

                        if message.estimatedCost > 0 && message.state == .delivered {
                            Text("•")
                            Text(message.estimatedCostText)
                        }

                        if message.state == .delivered, let onRetry {
                            Button(action: onRetry) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                            }
                        }
                    }
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .padding(.leading, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
