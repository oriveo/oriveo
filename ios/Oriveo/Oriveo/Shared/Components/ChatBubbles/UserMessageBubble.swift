import SwiftUI

struct UserMessageBubble: View {
    let message: ChatMessage
    var maxBubbleWidth: CGFloat = 320
    var showMetadata: Bool = true
    var onEdit: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    /// Bubble body text color: on top of the brand gradient, white in light mode and the current palette onPrimary in dark mode (a dynamic UIColor handed straight to the UITextView).
    static let textUIColor = OriveoTheme.Palette.onPrimaryUIColor

    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 20,
            bottomLeadingRadius: 20,
            bottomTrailingRadius: 6,
            topTrailingRadius: 20,
            style: .continuous
        )
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: OriveoTheme.Spacing.xs) {
            HStack(alignment: .center, spacing: OriveoTheme.Spacing.sm) {
                Spacer(minLength: 0)

                bubbleContent
                    .frame(maxWidth: maxBubbleWidth, alignment: .trailing)

                UserAvatarView(size: 36)
            }

        }
    }

    private var bubbleContent: some View {
        VStack(alignment: .trailing, spacing: OriveoTheme.Spacing.sm) {
            if let attachments = message.attachments, !attachments.isEmpty {
                UserAttachmentsGroup(attachments: attachments)
            }

            if !message.text.isEmpty {
                SelectableTextLabel(
                    text: message.text,
                    fontSize: 16,
                    textColor: Self.textUIColor,
                    tintColor: Self.textUIColor
                )
            }
        }
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.vertical, 14)
        .background(
            bubbleShape
                .fill(OriveoTheme.Palette.primaryGradient)
                .overlay(
                    bubbleShape
                        .stroke(OriveoTheme.Palette.hairline.opacity(0.9), lineWidth: 1)
                )
                .shadow(
                    color: OriveoTheme.Palette.primaryGlow,
                    radius: colorScheme == .dark ? 16 : 10,
                    y: colorScheme == .dark ? 10 : 6
                )
        )
        .clipShape(bubbleShape)
    }
}
