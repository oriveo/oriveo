package ai.oriveo.community.ui.component

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.ProviderBadgeColors
import ai.oriveo.community.ui.util.formatRelativeTime

/**
 * Conversation list row (matches iOS ConversationRow).
 *
 * A 30dp provider logo avatar on the left (vertically centered on the whole row) and three lines on the right:
 *  - title line (line height 20): pin + skill emoji + 15/semibold single-line title + Draft, with the cost in
 *    12 mono accent on the right (6 between title and cost);
 *  - preview: 13sp with an 18 line height, truncated to a **single** line;
 *  - bottom line (line height 14): model name on the left, streaming dot / bubble + message count · relative time
 *    on the right, 11sp tertiary, at least 8 between the two.
 * The row only owns its content and padding (15 vertical, 16 horizontal, 0 on the left in edit mode); the card
 * face comes from the caller.
 */
@Composable
fun ConversationRow(
    conversation: Conversation,
    providerKind: ProviderKind?,
    providerName: String,
    modelName: String,
    folderName: String? = null,
    skillIcon: String? = null,
    isEditing: Boolean = false,
    relayKind: RelayKind? = null,
    isStreaming: Boolean = false,
    isPinned: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val isDark = OriveoTheme.isDark
    val textPrimary = if (isDark) CONVERSATION_ROW_T1_DARK else CONVERSATION_ROW_T1_LIGHT
    val textSecondary = if (isDark) CONVERSATION_ROW_T2_DARK else CONVERSATION_ROW_T2_LIGHT
    val textTertiary = if (isDark) CONVERSATION_ROW_T3_DARK else CONVERSATION_ROW_T3_LIGHT
    val accent = if (isDark) CONVERSATION_ROW_ACCENT_DARK else CONVERSATION_ROW_ACCENT_LIGHT
    val photoLabel = stringResource(R.string.attachment_photo)
    val fileLabel = stringResource(R.string.file)
    val emptyPreviewText = stringResource(R.string.ready_to_start_conversation)
    val lastMessage = conversation.messages.lastOrNull()

    val previewText = remember(
        conversation.previewText,
        lastMessage?.id,
        lastMessage?.attachments?.size,
        photoLabel,
        fileLabel,
        emptyPreviewText,
    ) {
        when {
            conversation.previewText.isNotEmpty() -> stripMarkdown(conversation.previewText)
            else -> {
                val attachments = lastMessage?.attachments
                if (!attachments.isNullOrEmpty()) {
                    val hasImage = attachments.any { it.kind == AttachmentKind.Image }
                    val hasVideo = attachments.any { it.kind == AttachmentKind.Video }
                    val hasFile = attachments.any { it.kind == AttachmentKind.File }
                    when {
                        hasImage && hasVideo || hasImage && hasFile || hasVideo && hasFile -> listOfNotNull(
                            if (hasImage) "📷 $photoLabel" else null,
                            if (hasVideo) "🎬 Video" else null,
                            if (hasFile) "📎 $fileLabel" else null,
                        ).joinToString("  ")
                        hasImage -> "📷 $photoLabel"
                        hasVideo -> "🎬 Video"
                        else -> "📎 $fileLabel"
                    }
                } else {
                    emptyPreviewText
                }
            }
        }
    }

    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(start = if (isEditing) 0.dp else 16.dp, end = 16.dp, top = 15.dp, bottom = 15.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        ProviderLogoAvatar(
            providerKind = providerKind,
            relayKind = relayKind,
            isDark = isDark,
        )

        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            // Title line: pin (vertically centered) + title (flexible, Draft right after it) + cost on the right; without a cost the title takes the full width
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 20.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (isPinned) {
                    Icon(
                        imageVector = Icons.Filled.PushPin,
                        contentDescription = stringResource(R.string.pinned_section),
                        tint = textTertiary,
                        // The Material PushPin glyph fills about 20 of the 24 grid: an 11dp box ≈ the visible height of the iOS 10pt pin.fill
                        modifier = Modifier
                            .padding(end = 6.dp)
                            .size(11.dp),
                    )
                }
                Row(
                    modifier = Modifier.weight(1f),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    if (skillIcon != null) {
                        Text(
                            text = skillIcon,
                            fontSize = 13.sp,
                            lineHeight = 16.sp,
                        )
                    }
                    Text(
                        text = conversation.title,
                        fontSize = 15.sp,
                        lineHeight = 20.sp,
                        fontWeight = FontWeight.SemiBold,
                        letterSpacing = (-0.2).sp,
                        color = textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    if (conversation.isDraft) {
                        StatusPill(text = stringResource(R.string.draft), tone = StatusTone.Primary)
                    }
                }
                if (conversation.estimatedCost > 0) {
                    Text(
                        text = CostFormatter.format(conversation.estimatedCost),
                        fontSize = 12.sp,
                        lineHeight = 15.sp,
                        fontWeight = FontWeight.Medium,
                        fontFamily = FontFamily.Monospace,
                        color = accent,
                        maxLines = 1,
                        softWrap = false,
                        modifier = Modifier.padding(start = 6.dp),
                    )
                }
            }

            // Preview: 13sp, single line, 18 line height (the data is still the full previewText; only the rendering changes)
            Text(
                text = previewText,
                fontSize = 13.sp,
                lineHeight = 18.sp,
                color = textSecondary,
                maxLines = CONVERSATION_ROW_PREVIEW_MAX_LINES,
                overflow = TextOverflow.Ellipsis,
            )

            // Bottom line: model name (left) + streaming dot / message count · relative time (right), 11sp tertiary, line height 14
            // ~10 rows on screen × streaming tokens at 30 Hz = 300+ recompositions per second, so timeText and the inline icon must be remembered
            val messageCount = conversation.messageCount
            val timeText = remember(conversation.updatedAt) { formatRelativeTime(conversation.updatedAt) }
            val messagesLabel = stringResource(R.string.messages)
            val rightText = remember(messageCount, timeText, messagesLabel) {
                buildAnnotatedString {
                    if (messageCount > 0) {
                        // alternateText makes TalkBack read "Messages 6" instead of a bare number
                        appendInlineContent(CHAT_ICON_ID, alternateText = messagesLabel)
                        append(" $messageCount")
                        withStyle(SpanStyle(color = textTertiary.copy(alpha = textTertiary.alpha * 0.6f))) {
                            append("  ·  ")
                        }
                    }
                    append(timeText)
                }
            }
            val chatIconInline = remember(textTertiary) {
                mapOf(
                    CHAT_ICON_ID to InlineTextContent(
                        Placeholder(10.sp, 10.sp, PlaceholderVerticalAlign.TextCenter),
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.Forum,
                            contentDescription = null,
                            modifier = Modifier.fillMaxSize(),
                            tint = textTertiary,
                        )
                    },
                )
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // The model name takes the remaining width and truncates; the trailing cluster hugs the right with at least 8 between them
                Text(
                    text = modelName,
                    fontSize = 11.sp,
                    lineHeight = 14.sp,
                    color = textTertiary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier
                        .weight(1f)
                        .padding(end = 8.dp),
                )
                if (isStreaming) {
                    StreamingPulseDot(modifier = Modifier.padding(end = 4.dp))
                }
                Text(
                    text = rightText,
                    fontSize = 11.sp,
                    lineHeight = 14.sp,
                    color = textTertiary,
                    maxLines = 1,
                    softWrap = false,
                    inlineContent = chatIconInline,
                )
            }
        }
    }
}

/** The preview keeps one line (the data is still the full previewText; only the rendering changes). */
internal const val CONVERSATION_ROW_PREVIEW_MAX_LINES = 1

/** 30dp avatar, vertically centered on the whole row. */
internal val CONVERSATION_ROW_AVATAR_SIZE = 30.dp

private const val CHAT_ICON_ID = "chatIcon"

// Row text colors share the home Aurora palette (t1 / t2 / t3 / accent); FolderDetail reusing this row gets them too
private val CONVERSATION_ROW_T1_LIGHT = Color(0xFF0A0612)
private val CONVERSATION_ROW_T1_DARK = Color(0xFFFAFAFB)
private val CONVERSATION_ROW_T2_LIGHT = Color(0xFF6B6378)
private val CONVERSATION_ROW_T2_DARK = Color(0xFFC4BFD3)
private val CONVERSATION_ROW_T3_LIGHT = Color(0xFF9C95AA)
private val CONVERSATION_ROW_T3_DARK = Color(0xFF8C8499)
private val CONVERSATION_ROW_ACCENT_LIGHT = Color(0xFF8B5CF6)
private val CONVERSATION_ROW_ACCENT_DARK = Color(0xFFA78BFA)

/**
 * Provider logo avatar (matches iOS conversationAvatar)
 *
 * Official providers: the brand logo.
 * Relay: the logo of the upstream selected by relayKind (OpenAI / Anthropic / Gemini); Custom / null shows the purple-orange Relay logo
 */
@Composable
private fun ProviderLogoAvatar(
    providerKind: ProviderKind?,
    relayKind: RelayKind?,
    isDark: Boolean,
) {
    if (providerKind != null) {
        ProviderBadgeIcon(
            kind = providerKind,
            size = CONVERSATION_ROW_AVATAR_SIZE,
            relayKind = relayKind,
        )
    }
}

private val stripCodeBlockRegex = Regex("```[\\s\\S]*?```")
private val stripInlineCodeRegex = Regex("`([^`]+)`")
private val stripImageRegex = Regex("!\\[([^\\]]*)\\]\\([^)]*\\)")
private val stripLinkRegex = Regex("\\[([^\\]]*)\\]\\([^)]*\\)")
private val stripBoldStarRegex = Regex("\\*\\*(.+?)\\*\\*")
private val stripBoldUnderscoreRegex = Regex("__(.+?)__")
private val stripItalicStarRegex = Regex("(^|\\s)\\*([^*]+)\\*(?=\\s|$|[.,!?;:])")
private val stripItalicUnderscoreRegex = Regex("(^|\\s)_([^_]+)_(?=\\s|$|[.,!?;:])")
private val stripStrikethroughRegex = Regex("~~(.+?)~~")
private val stripHeadingRegex = Regex("(?m)^#{1,6}\\s+")
private val stripQuoteRegex = Regex("(?m)^>\\s?")
private val stripBulletRegex = Regex("(?m)^[-*]\\s+")
private val stripOrderedListRegex = Regex("(?m)^\\d+\\.\\s+")
private val stripWhitespaceRegex = Regex("\\s+")

internal fun stripMarkdown(text: String): String {

    val cleaned = text.filter { ch ->
        ch != '\uFFFD' && ch != '\uFFFC' &&
            !(ch.code < 0x20 && ch != '\n' && ch != '\r' && ch != '\t') &&
            ch.code != 0x7F
    }
    return cleaned

        .replace(stripCodeBlockRegex, " ")

        .replace(stripInlineCodeRegex, "$1")

        .replace(stripImageRegex, "$1")

        .replace(stripLinkRegex, "$1")

        .replace(stripBoldStarRegex, "$1")
        .replace(stripBoldUnderscoreRegex, "$1")

        .replace(stripItalicStarRegex, "$1$2")
        .replace(stripItalicUnderscoreRegex, "$1$2")

        .replace(stripStrikethroughRegex, "$1")

        .replace(stripHeadingRegex, "")

        .replace(stripQuoteRegex, "")

        .replace(stripBulletRegex, "")

        .replace(stripOrderedListRegex, "")

        .replace(stripWhitespaceRegex, " ")
        .trim()
}
