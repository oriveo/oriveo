package ai.oriveo.community.feature.chat

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.provider.ModelDisplayLookup
import ai.oriveo.community.core.voice.realtime.RealtimeDrafts
import ai.oriveo.community.feature.chat.components.MessageBubble
import ai.oriveo.community.feature.chat.voice.RealtimeMessageAttribution
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.flow.StateFlow

/**
 * The realtime session's live bubbles for the chat list: its drafts flow, who its stored turns are attributed to and
 * the ids of the messages it stored.
 */
@Immutable
internal data class RealtimeLiveBubbleSource(
    val drafts: StateFlow<RealtimeDrafts>,
    val attribution: RealtimeMessageAttribution,
    val callMessageIds: StateFlow<Set<String>>,
)

/** A source only for a realtime session (all present); null otherwise. */
internal fun realtimeLiveBubbleSource(
    drafts: StateFlow<RealtimeDrafts>?,
    attribution: RealtimeMessageAttribution?,
    callMessageIds: StateFlow<Set<String>>?,
): RealtimeLiveBubbleSource? = if (drafts != null && attribution != null && callMessageIds != null) {
    RealtimeLiveBubbleSource(drafts, attribution, callMessageIds)
} else {
    null
}

internal const val REALTIME_LIVE_USER_ID = "realtime_live_user"
internal const val REALTIME_LIVE_ASSISTANT_ID = "realtime_live_assistant"

/**
 * Hands a live bubble over to its stored message without a gap. The controller clears a side in the reduce that
 * persists it, but the stored row reaches the list later: a cleared side keeps showing the persisted text while the
 * list holds fewer of the session's own messages of that role (ids in [callMessageIds], the ids the session stored)
 * than the persist count of the drafts. Matched by the stored ids, never by text, so it does not matter whether a
 * message was already listed when the list took the session on (home entry: created, then the page opened).
 */
internal class RealtimeLiveHandover(private val callMessageIds: Set<String>) {

    /** The bubbles after the stored [messages], in the order they will be stored (a barge-in stores the reply first). */
    fun bubbles(
        drafts: RealtimeDrafts,
        messages: List<ChatMessage>,
        attribution: RealtimeMessageAttribution,
    ): List<ChatMessage> {
        var listedUser = 0
        var listedAssistant = 0
        for (message in messages) {
            if (message.id !in callMessageIds) continue
            when (message.role) {
                ChatRole.User -> listedUser++
                ChatRole.Assistant -> listedAssistant++
                else -> Unit
            }
        }
        val userText = side(drafts.user, drafts.userPersistedText, listedUser < drafts.userPersisted)
        val assistantText = side(drafts.assistant, drafts.assistantPersistedText, listedAssistant < drafts.assistantPersisted)
        val user = userText?.let { liveBubble(REALTIME_LIVE_USER_ID, ChatRole.User, it, attribution) }
        val assistant = assistantText?.let { liveBubble(REALTIME_LIVE_ASSISTANT_ID, ChatRole.Assistant, it, attribution) }
        return if (drafts.userAfterAssistant) listOfNotNull(assistant, user) else listOfNotNull(user, assistant)
    }

    /** Live text while it has any; else the persisted text until its stored message is listed; else nothing. */
    private fun side(draft: String?, persisted: String?, awaitingStored: Boolean): String? = when {
        !draft.isNullOrBlank() -> draft
        awaitingStored -> persisted?.takeIf { it.isNotBlank() }
        else -> null
    }
}

/** Same attribution as the stored row (RepositoryRealtimeTranscriptSink), so the header does not change on handover. */
private fun liveBubble(id: String, role: ChatRole, text: String, attribution: RealtimeMessageAttribution) = ChatMessage(
    id = id,
    role = role,
    text = text,
    providerID = attribution.providerID,
    providerKind = attribution.providerKind,
    providerName = attribution.providerName,
    modelID = attribution.model,
    modelName = attribution.model,
    state = ChatMessageState.Delivered,
)

/**
 * One list item holding the live bubbles: the drafts are collected here, so their updates (≤ 10 per second while
 * the reply plays) recompose only this cell. Same bubble styles and header as stored messages, without any actions.
 */
@Composable
internal fun RealtimeLiveBubbles(
    source: RealtimeLiveBubbleSource,
    messages: List<ChatMessage>,
    displayLookup: ModelDisplayLookup,
) {
    val drafts by source.drafts.collectAsStateWithLifecycle()
    val callMessageIds by source.callMessageIds.collectAsStateWithLifecycle()
    val bubbles = RealtimeLiveHandover(callMessageIds).bubbles(drafts, messages, source.attribution)
    if (bubbles.isEmpty()) return
    Column(modifier = Modifier.fillMaxWidth()) {
        bubbles.forEachIndexed { index, bubble ->
            val before = if (index == 0) messages.lastOrNull()?.role else bubbles[index - 1].role
            val top = if (before == bubble.role) OriveoTheme.spacing.sm else OriveoTheme.spacing.lg
            val metadata = resolveMessageDisplayMetadata(bubble, displayLookup)
            MessageBubble(
                message = bubble,
                // Same rule as the stored list: a user row always, an assistant row unless an assistant follows.
                showMetadata = bubble.role == ChatRole.User || bubbles.getOrNull(index + 1)?.role != ChatRole.Assistant,
                providerNameOverride = metadata.providerName,
                modelNameOverride = metadata.modelName,
                modifier = Modifier.padding(top = top),
            )
        }
    }
}
