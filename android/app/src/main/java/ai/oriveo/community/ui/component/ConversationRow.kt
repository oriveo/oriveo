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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material3.Icon
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
import androidx.compose.ui.text.font.FontWeight
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
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
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
            .padding(start = if (isEditing) 0.dp else 16.dp, end = 16.dp, top = 14.dp, bottom = 14.dp),
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
            verticalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            // Row 1: [skillIcon] Title [DraftPill] ... Cost
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(
                    modifier = Modifier.weight(1f),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.xs),
                ) {
                    if (isPinned) {
                        Icon(
                            imageVector = Icons.Filled.PushPin,
                            contentDescription = null,
                            tint = colors.textSecondary,
                            modifier = Modifier.size(11.dp),
                        )
                    }
                    if (skillIcon != null) {
                        Text(
                            text = skillIcon,
                            fontSize = 13.sp,
                        )
                    }
                    Text(
                        text = conversation.title,
                        style = OriveoTheme.typography.title3.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    if (conversation.isDraft) {
                        StatusPill(text = stringResource(R.string.draft), tone = StatusTone.Primary)
                    }
                    if (isStreaming) {
                        Spacer(modifier = Modifier.width(6.dp))
                        StreamingPulseDot()
                    }
                }

                Spacer(modifier = Modifier.width(4.dp))

                if (conversation.estimatedCost > 0) {
                    Text(
                        text = CostFormatter.format(conversation.estimatedCost),
                        style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.Medium),
                        color = colors.primary,
                    )
                }
            }

            Text(
                text = previewText,
                style = OriveoTheme.typography.caption,
                color = colors.textSecondary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )

            // HomeScreen \u4e00\u5c4f ~10 \u884c \u00d7 \u6d41\u5f0f token 30 Hz = 300+ \u6b21/\u79d2 \u91cd\u7ec4\uff0cmetaStyle / timeText /
            // chatIconInline \u5fc5\u987b remember \u7f13\u5b58\uff08\u539f\u4ee3\u7801\u6bcf\u6b21\u91cd\u7ec4\u90fd alloc TextStyle / String / Map+InlineTextContent\uff09\u3002
            val footnote = OriveoTheme.typography.footnote
            val metaStyle = remember(footnote) { footnote.copy(fontSize = 11.sp) }
            val messageCount = conversation.messageCount
            val timeText = remember(conversation.updatedAt) { formatRelativeTime(conversation.updatedAt) }
            val rightText = remember(messageCount, timeText) {
                buildAnnotatedString {
                    if (messageCount > 0) {
                        appendInlineContent("chatIcon")
                        append("\u2009$messageCount  ") // thin space + count + 2 spaces
                    }
                    append(timeText)
                }
            }
            val textTertiary = colors.textTertiary
            val chatIconInline = remember(textTertiary) {
                mapOf(
                    "chatIcon" to InlineTextContent(
                        Placeholder(9.sp, 9.sp, PlaceholderVerticalAlign.TextCenter),
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
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = modelName,
                    style = metaStyle,
                    color = colors.textTertiary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    text = rightText,
                    style = metaStyle,
                    color = colors.textTertiary,
                    inlineContent = chatIconInline,
                )
            }
        }
    }
}

@Composable
private fun ProviderLogoAvatar(
    providerKind: ProviderKind?,
    relayKind: RelayKind?,
    isDark: Boolean,
) {
    if (providerKind != null) {
        ProviderBadgeIcon(
            kind = providerKind,
            size = 32.dp,
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
