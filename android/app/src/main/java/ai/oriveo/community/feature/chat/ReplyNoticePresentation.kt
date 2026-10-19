package ai.oriveo.community.feature.chat

import ai.oriveo.community.R
import ai.oriveo.community.core.context.StopReason

/** Reply-incomplete notice kinds (stop-reason.v1 `ui.*.notice`); [wire] matches the fixture value. */
enum class ReplyNotice(val wire: String) {
    INCOMPLETE_OUTPUT_LIMIT("incomplete_output_limit"),
    INCOMPLETE_CONNECTION("incomplete_connection"),
    FILTERED("filtered"),
    CONTEXT_OVERFLOW("context_overflow"),
    ;

    val textRes: Int
        get() = when (this) {
            INCOMPLETE_OUTPUT_LIMIT -> R.string.reply_incomplete_output_limit
            INCOMPLETE_CONNECTION -> R.string.reply_incomplete_connection
            FILTERED -> R.string.reply_filtered
            CONTEXT_OVERFLOW -> R.string.reply_context_overflow
        }
}

data class ReplyNoticeModel(val notice: ReplyNotice, val showContinue: Boolean)

/** P4·U4 contract item 6: whether an assistant reply shows the incomplete / filtered notice and [Continue]. */
object ReplyNoticePresentation {

    /** Label of the [Continue] action; matches iOS / Web "Continue Generating". */
    val continueLabelRes: Int = R.string.continue_generating

    fun resolve(
        stopReason: StopReason?,
        isLastAssistant: Boolean,
        isStreaming: Boolean,
        hasRecoveryCard: Boolean,
        isSending: Boolean,
    ): ReplyNoticeModel? {
        if (isStreaming || hasRecoveryCard) return null
        val (notice, continueAction) = when (stopReason) {
            StopReason.LENGTH -> ReplyNotice.INCOMPLETE_OUTPUT_LIMIT to true
            StopReason.INCOMPLETE -> ReplyNotice.INCOMPLETE_CONNECTION to true
            StopReason.CONTENT_FILTER -> ReplyNotice.FILTERED to false
            StopReason.CONTEXT_WINDOW_EXCEEDED -> ReplyNotice.CONTEXT_OVERFLOW to false
            StopReason.STOP, StopReason.TOOL, StopReason.INTERRUPTED, StopReason.ERROR, StopReason.UNKNOWN, null ->
                return null
        }
        return ReplyNoticeModel(notice, showContinue = continueAction && isLastAssistant && !isSending)
    }
}
