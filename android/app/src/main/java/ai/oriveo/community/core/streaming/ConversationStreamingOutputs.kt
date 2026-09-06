package ai.oriveo.community.core.streaming

import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Where a running stream writes what it has produced so far.
 *
 * The streaming manager owns one of these per conversation and hands it to the send call, so the
 * screen can observe tokens as they arrive without the send call knowing anything about the UI,
 * and so a stream survives navigating away and back.
 */
data class ConversationStreamingOutputs(
    val streamingText: MutableStateFlow<String>,
    val streamingMessageId: MutableStateFlow<String?>,
    val streamingReasoning: MutableStateFlow<String> = MutableStateFlow(""),
    /**
     * When reasoning actually started, set on the first non-empty reasoning chunk rather than on
     * the first reasoning event: some providers open with an empty `reasoning_content`, and
     * timing from that shows a thinking indicator for a model that never thought.
     */
    val reasoningStartedAtMs: MutableStateFlow<Long?> = MutableStateFlow(null),
    /**
     * When the first visible token arrived, which is what ends the reasoning phase.
     *
     * [NOT_SET] stands in for "no token yet": an epoch-millisecond stamp is never 0, and an
     * [AtomicLong] compares by value, so the set-once compare-and-set below is exact.
     */
    val reasoningEndedAtMs: AtomicLong = AtomicLong(NOT_SET),
) {
    companion object {
        /** Sentinel for [reasoningEndedAtMs]: no visible token has arrived yet. */
        const val NOT_SET = 0L
    }
}
