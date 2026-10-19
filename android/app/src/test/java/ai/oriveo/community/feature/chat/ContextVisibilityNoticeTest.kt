package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.context.ContextContractFixture
import ai.oriveo.community.core.context.ContextContractFixture.bool
import ai.oriveo.community.core.context.ContextContractFixture.stringOrNull
import ai.oriveo.community.core.context.StopReason
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/** Incomplete / filtered answer notice and the [Continue generating] button. */
class ContextVisibilityNoticeTest {

    @Test
    fun reply_notice_follows_stop_reason_fixture() {
        val ui = ContextContractFixture.load("stop-reason.v1.json")["ui"]!!.jsonObject
        // Every value of the closed set needs an entry in the fixture ui (null means no notice)
        assertEquals(StopReason.entries.map { it.wire }.toSet(), ui.keys)
        for (reason in StopReason.entries) {
            val expected = ui[reason.wire]!!
            val actual = present(reason)
            if (expected is JsonNull) {
                assertNull(reason.wire, actual)
            } else {
                val obj = expected.jsonObject
                assertNotNull(reason.wire, actual)
                assertEquals(reason.wire, obj.stringOrNull("notice"), actual!!.notice.wire)
                assertEquals(reason.wire, obj.bool("continueAction"), actual.showContinue)
            }
        }
        assertNull(present(null))
    }

    @Test
    fun reply_continue_only_on_last_assistant() {
        val last = present(StopReason.LENGTH, isLastAssistant = true)!!
        assertTrue(last.showContinue)
        // Not the last message: the notice is still shown, the button is not
        val earlier = present(StopReason.LENGTH, isLastAssistant = false)!!
        assertEquals(ReplyNotice.INCOMPLETE_OUTPUT_LIMIT, earlier.notice)
        assertFalse(earlier.showContinue)
        // The conversation is generating: no button
        assertFalse(present(StopReason.INCOMPLETE, isSending = true)!!.showContinue)
        // Filtering and context overflow never carry a button
        assertFalse(present(StopReason.CONTENT_FILTER)!!.showContinue)
        assertFalse(present(StopReason.CONTEXT_WINDOW_EXCEEDED)!!.showContinue)
    }

    /** The incomplete-reply footer button label matches iOS / Web: "Continue generating" rather than "Continue". */
    @Test
    fun reply_notice_continue_label_is_continue_generating() {
        assertEquals(ai.oriveo.community.R.string.continue_generating, ReplyNoticePresentation.continueLabelRes)
    }

    @Test
    fun reply_notice_hidden_when_recovery_card_or_streaming() {
        for (reason in listOf(StopReason.LENGTH, StopReason.INCOMPLETE, StopReason.CONTENT_FILTER, StopReason.CONTEXT_WINDOW_EXCEEDED)) {
            assertNull(reason.wire, present(reason, isStreaming = true))
            assertNull(reason.wire, present(reason, hasRecoveryCard = true))
        }
    }

    @Test
    fun reply_strings_present_in_16_locales() {
        val failures = mutableListOf<String>()
        for (locale in LOCALES) {
            val strings = parse(File("src/main/res/$locale/strings.xml"))
            for (key in KEYS) {
                if (strings[key].isNullOrBlank()) failures += "$locale $key missing"
            }
        }
        // Every notice maps to a declared string
        val declared = parse(File("src/main/res/values/strings.xml")).keys
        ReplyNotice.entries.forEach { notice ->
            if ("reply_${notice.wire}" !in declared) failures += "reply_${notice.wire} undeclared"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    private fun present(
        reason: StopReason?,
        isLastAssistant: Boolean = true,
        isStreaming: Boolean = false,
        hasRecoveryCard: Boolean = false,
        isSending: Boolean = false,
    ): ReplyNoticeModel? = ReplyNoticePresentation.resolve(
        stopReason = reason,
        isLastAssistant = isLastAssistant,
        isStreaming = isStreaming,
        hasRecoveryCard = hasRecoveryCard,
        isSending = isSending,
    )

    private fun parse(file: File): Map<String, String> {
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
        val nodes = doc.getElementsByTagName("string")
        return (0 until nodes.length).associate { i ->
            val el = nodes.item(i) as Element
            el.getAttribute("name") to el.textContent
        }
    }

    private companion object {
        val LOCALES = listOf(
            "values", "values-zh-rCN", "values-zh-rTW", "values-ja", "values-ko", "values-de", "values-fr",
            "values-es", "values-pt-rBR", "values-ru", "values-tr", "values-ar", "values-hi", "values-vi",
            "values-in", "values-th",
        )
        val KEYS = listOf(
            "reply_incomplete_output_limit", "reply_incomplete_connection", "reply_filtered",
            "reply_context_overflow", "continue_generating",
        )
    }
}
