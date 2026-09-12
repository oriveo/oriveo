import SwiftUI

struct ConversationRow: View, Equatable {
    let conversation: Conversation
    var provider: Provider?
    var resolvedModelName: String?
    var folderName: String?
    var skillIcon: String?
    var grouped: Bool = false
    var isEditing: Bool = false
    var isStreaming: Bool = false
    var isPinned: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    private static let previewCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 300
        return cache
    }()

    static func == (lhs: ConversationRow, rhs: ConversationRow) -> Bool {
        let coreEqual = lhs.conversation.id == rhs.conversation.id &&
            lhs.conversation.title == rhs.conversation.title &&
            lhs.conversation.previewText == rhs.conversation.previewText &&
            lhs.conversation.updatedAt == rhs.conversation.updatedAt &&
            lhs.conversation.isDraft == rhs.conversation.isDraft &&
            lhs.conversation.providerKind == rhs.conversation.providerKind
        guard coreEqual else { return false }

        let metaEqual = lhs.conversation.displayMessageCount == rhs.conversation.displayMessageCount &&
            lhs.conversation.estimatedCost == rhs.conversation.estimatedCost &&
            lhs.conversation.modelID == rhs.conversation.modelID &&
            lhs.resolvedModelName == rhs.resolvedModelName
        guard metaEqual else { return false }

        let providerEqual = lhs.provider?.id == rhs.provider?.id &&
            lhs.provider?.displayName == rhs.provider?.displayName &&
            lhs.provider?.kind == rhs.provider?.kind
        guard providerEqual else { return false }

        let displayEqual = lhs.folderName == rhs.folderName &&
            lhs.skillIcon == rhs.skillIcon &&
            lhs.grouped == rhs.grouped &&
            lhs.isEditing == rhs.isEditing &&
            lhs.isStreaming == rhs.isStreaming
        guard displayEqual else { return false }

        return lhs.isPinned == rhs.isPinned
    }

    nonisolated static func resolveModelName(
        for conversation: Conversation,
        provider: Provider?,
        lookup: ModelDisplayLookup? = nil,
        metadata: MetadataClient = .shared
    ) -> String? {
        guard let provider else { return nil }

        let resolvedLookup = lookup ?? ModelDisplayLookup(
            providers: [provider],
            metadata: metadata
        )
        if let modelName = resolvedLookup.modelDisplayName(
            providerID: provider.id,
            modelID: conversation.modelID
        ) {
            return modelName
        }

        return ModelResolver.matchingModel(
            modelID: conversation.modelID,
            in: ProviderSelectionSnapshot.enabledModels(in: provider),
            providerKind: provider.kind
        )?.name
    }

    // MARK: - Body

    /// Avatar 30pt, vertically centred on the whole row
    static let avatarSize: CGFloat = 30
    /// The preview keeps a single line (the data is still the full previewText; only the rendering changes)
    static let previewLineLimit = 1

    var body: some View {
        let content = rowContent
            .padding(.leading, isEditing ? 0 : OriveoTheme.V2.Sp.s16)
            .padding(.trailing, OriveoTheme.V2.Sp.s16)
            .padding(.vertical, 15)

        if grouped {
            content
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(OriveoTheme.V2.Colors.surfaceDefault)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(OriveoTheme.V2.Colors.borderDefault, lineWidth: 1)
                )
                .cardShine()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 12) {
            conversationAvatar

            VStack(alignment: .leading, spacing: 4) {
                // Title row: pin (vertically centred) + title (flexible) + cost on the right, only 6 between title and
                // cost; line height 20. A Spacer must not sit inside a spacing-6 HStack: the spacing lands on both
                // sides of it, the minimum gap becomes 16, a title that would fit gets truncated further, and 10
                // is wasted when there is no cost.
                HStack(alignment: .center, spacing: 6) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(AuroraTheme.Colors.textTertiary)
                            .accessibilityLabel(L10n.tr("Pinned", table: .home))
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if let skillIcon {
                                Text(skillIcon)
                                    .font(.system(size: 13))
                            }
                            Text(conversation.title)
                                .font(.system(size: 15, weight: .semibold))
                                .tracking(-0.2)
                                .foregroundStyle(AuroraTheme.Colors.textPrimary)
                                .lineLimit(1)

                            if conversation.isDraft {
                                StatusPill(title: L10n.tr("Draft"), tone: .primary)
                            }
                        }

                        Spacer(minLength: 0)

                        if conversation.estimatedCost > 0 {
                            Text(conversation.estimatedCostText)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(AuroraTheme.Colors.accent)
                                .fixedSize()
                                .padding(.leading, 6)
                        }
                    }
                }
                .frame(minHeight: 20)

                // Preview: 13pt, one truncated line, line height 18
                NativeTextLabel(
                    text: conversationPreviewText,
                    fontSize: 13,
                    textColor: AuroraTheme.Colors.textSecondary,
                    numberOfLines: Self.previewLineLimit,
                    lineBreakMode: .byTruncatingTail
                )
                .frame(minHeight: 18)

                // Bottom row: model name (left) + streaming dot / message count · relative time (right), 11pt tertiary,
                // line height 14; at least 8 between the two halves
                HStack(spacing: 0) {
                    if let modelName = resolvedModelName {
                        Text(modelName)
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        if isStreaming {
                            StreamingPulseDot()
                        }
                        if conversation.displayMessageCount > 0 {
                            // The icon carries "Messages" so VoiceOver reads "Messages, 6" instead of a bare number
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 10))
                                .accessibilityLabel(L10n.tr("Messages", table: .backup))
                            Text("\(conversation.displayMessageCount)")
                                .font(.system(size: 11))
                            Text(verbatim: "·")
                                .font(.system(size: 11))
                                .opacity(0.6)
                                .padding(.horizontal, 2)
                                .accessibilityHidden(true)
                        }
                        Text(RelativeTimeFormatter.text(from: conversation.updatedAt))
                            .font(.system(size: 11))
                    }
                    .fixedSize()
                }
                .foregroundStyle(AuroraTheme.Colors.textTertiary)
                .frame(minHeight: 14)
            }
        }
    }


    @ViewBuilder
    private var conversationAvatar: some View {
        ProviderBadgeIcon(
            kind: conversation.providerKind,
            size: Self.avatarSize,
            relayKind: provider?.relayKind
        )
    }

    // MARK: - Preview Text

    private var conversationPreviewText: String {
        if !conversation.previewText.isEmpty {
            return Self.cachedPreviewText(for: conversation.previewText)
        }
        if let lastMessage = conversation.messages.last,
           let attachments = lastMessage.attachments, !attachments.isEmpty {
            let hasImage = attachments.contains { $0.kind == .image }
            let hasVideo = attachments.contains { $0.kind == .video }
            let hasFile = attachments.contains { $0.kind == .file }
            if hasImage && hasVideo || hasImage && hasFile || hasVideo && hasFile {
                var parts: [String] = []
                if hasImage { parts.append("📷 \(L10n.tr("Photo"))") }
                if hasVideo { parts.append("🎬 \(L10n.tr("Video"))") }
                if hasFile { parts.append("📎 \(L10n.tr("File"))") }
                return parts.joined(separator: "  ")
            } else if hasImage && hasFile {
                return "📷 \(L10n.tr("Photo"))  📎 \(L10n.tr("File"))"
            } else if hasImage {
                return "📷 \(L10n.tr("Photo"))"
            } else if hasVideo {
                return "🎬 \(L10n.tr("Video"))"
            } else {
                return "📎 \(L10n.tr("File"))"
            }
        }
        return L10n.tr("Ready to start a new conversation")
    }

    private static func cachedPreviewText(for text: String) -> String {
        let prefix = String(text.prefix(200))
        let cacheKey = NSString(string: prefix)
        if let cached = previewCache.object(forKey: cacheKey) {
            return cached as String
        }
        let preview = stripMarkdownForPreview(prefix)
        previewCache.setObject(NSString(string: preview), forKey: cacheKey)
        return preview
    }

    private static func stripMarkdownForPreview(_ text: String) -> String {
        var result = text
        result = String(result.unicodeScalars.filter { scalar in
            scalar != "\u{FFFD}" && scalar != "\u{FFFC}" &&
            !(scalar.value < 0x20 && scalar != "\n" && scalar != "\r" && scalar != "\t") &&
            scalar.value != 0x7F
        })
        result = result.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "!\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "__(.+?)__", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?<![\\*\\s])\\*([^\\*]+)\\*(?!\\*)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?<!_)_([^_]+)_(?!_)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^#{1,6}\\s+", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^>\\s?", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^[\\-\\*]\\s+", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^\\d+\\.\\s+", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - StreamingPulseDot

private struct StreamingPulseDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(OriveoTheme.V2.Colors.primary)
            .frame(width: 6, height: 6)
            .opacity(reduceMotion ? 1.0 : (pulse ? 1.0 : 0.45))
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: pulse
            )
            .onAppear {
                if !reduceMotion {
                    pulse = true
                }
            }
            .accessibilityLabel(L10n.tr("Generating"))
    }
}
