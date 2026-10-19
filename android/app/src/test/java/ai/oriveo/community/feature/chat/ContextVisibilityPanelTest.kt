package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.context.ContextBasis
import ai.oriveo.community.core.context.ContextCompactionBreaker
import ai.oriveo.community.core.context.ContextCompactionEvent
import ai.oriveo.community.core.context.ContextManifest
import ai.oriveo.community.core.context.ContextManifestSegment
import ai.oriveo.community.core.context.ContextSegmentKind
import ai.oriveo.community.core.context.RequestPurpose
import ai.oriveo.community.core.context.StopReason
import java.io.File
import java.util.Locale
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/** Context panel button / circuit breaker / legend values and the values of the settings usage row. */
class ContextVisibilityPanelTest {

    private val checkpoint = ContextUsageCheckpoint(count = 2, latestCreatedAt = 500, latestSummaryTokens = 1_000)

    @Test
    fun panel_buttons_follow_checkpoint() {
        val llm = ContextCompactionBreaker().mode
        val without = ContextUsagePanel.buttons(observedSummary(null), llm, compacting = false, sending = false)
        assertEquals(ContextUsagePanelButtons(true, showClear = false, showNewChatWithSummary = false, showRetry = false), without)

        val with = ContextUsagePanel.buttons(observedSummary(checkpoint), llm, compacting = false, sending = false)
        assertEquals(ContextUsagePanelButtons(true, showClear = true, showNewChatWithSummary = true, showRetry = false), with)

        // [Condense context] is always shown: also present with no usage (none), and disabled while condensing or sending.
        assertTrue(ContextUsagePanel.buttons(ContextUsageSummary.NONE, llm, false, false).compactEnabled)
        assertFalse(ContextUsagePanel.buttons(observedSummary(checkpoint), llm, compacting = true, sending = false).compactEnabled)
        assertFalse(ContextUsagePanel.buttons(observedSummary(checkpoint), llm, compacting = false, sending = true).compactEnabled)
    }

    @Test
    fun panel_breaker_retry_shown_when_fallback_only() {
        val tripped = ContextCompactionBreaker()
            .apply(ContextCompactionEvent.LLM_FAILURE)
            .apply(ContextCompactionEvent.LLM_FAILURE)
        val paused = ContextUsagePanel.buttons(observedSummary(null), tripped.mode, false, false)
        assertTrue(paused.showRetry)
        val recovered = tripped.apply(ContextCompactionEvent.RETRY)
        assertFalse(ContextUsagePanel.buttons(observedSummary(null), recovered.mode, false, false).showRetry)
    }

    @Test
    fun panel_legend_lists_positive_segments() {
        // No memory, no summary: the legend omits those two segments; conversation and free space are always listed.
        val summary = ContextUsagePresentation.summary(
            listOf(
                manifest(
                    observed = 40_000,
                    segments = listOf(
                        ContextManifestSegment(ContextSegmentKind.INSTRUCTIONS, 600),
                        ContextManifestSegment(ContextSegmentKind.NOTES, 2_000, omitted = 3),
                    ),
                ),
            ),
            null,
        )
        assertEquals(ContextUsageDisplay.PERCENT, summary.display)
        assertEquals(
            listOf(
                ContextUsageLegendItem(ContextUsageLegendKind.CONVERSATION, 37_400),
                ContextUsageLegendItem(ContextUsageLegendKind.LIBRARY, 2_000),
                ContextUsageLegendItem(ContextUsageLegendKind.INSTRUCTIONS, 600),
                ContextUsageLegendItem(ContextUsageLegendKind.FREE, 60_000),
            ),
            ContextUsagePanel.legend(summary),
        )
        assertTrue(ContextUsagePanel.showsSegmentedRing(summary))
        assertEquals(listOf(ContextUsageOmittedLine(ContextUsageOmittedKind.NOTES, 3)), ContextUsagePanel.omittedLines(summary))

        // Over the limit: free space 0 is still listed, and so is conversation 0.
        val full = ContextUsagePresentation.summary(
            listOf(manifest(observed = 120_000, segments = listOf(ContextManifestSegment(ContextSegmentKind.MEMORY, 120_000)))),
            null,
        )
        assertEquals(
            listOf(
                ContextUsageLegendItem(ContextUsageLegendKind.CONVERSATION, 0),
                ContextUsageLegendItem(ContextUsageLegendKind.MEMORY, 120_000),
                ContextUsageLegendItem(ContextUsageLegendKind.FREE, 0),
            ),
            ContextUsagePanel.legend(full),
        )

        // Window unknown / no ledger: dashed ring + hint, no legend.
        val unknown = ContextUsagePresentation.summary(listOf(manifest(observed = 40_000, b = null)), null)
        assertFalse(ContextUsagePanel.showsSegmentedRing(unknown))
        assertEquals(emptyList<ContextUsageLegendItem>(), ContextUsagePanel.legend(unknown))
        assertEquals(ai.oriveo.community.R.string.context_usage_hint_window_unknown, ContextUsagePanel.hintRes(unknown))
        // After condensing is cleared (the latest manifest carries a checkpointId and no valid checkpoint is left): the hint says usage is shown after a message is sent.
        val cleared = ContextUsagePresentation.summary(listOf(manifest(observed = 40_000).copy(checkpointId = "c1")), null)
        assertEquals(ai.oriveo.community.R.string.context_usage_hint_empty, ContextUsagePanel.hintRes(cleared))
        // With no manifest there is no dedicated empty-state hint any more; the same hint still shows while the summary has not been read yet.
        assertNull(ContextUsagePanel.hintRes(ContextUsageSummary.NONE))
        assertEquals(ai.oriveo.community.R.string.context_usage_hint_empty, ContextUsagePanel.hintRes(null))
        val compacted = ContextUsagePresentation.summary(listOf(manifest(observed = 40_000)), checkpoint.copy(latestCreatedAt = 5_000))
        assertEquals(ai.oriveo.community.R.string.context_usage_hint_compacted, ContextUsagePanel.hintRes(compacted))
    }

    @Test
    fun settings_usage_value_text() {
        assertEquals(ContextUsageValueText.Percent(40), ContextUsagePanel.settingsValue(observedSummary(null)))
        // Never measured -> "about N%".
        val estimated = ContextUsagePresentation.summary(listOf(manifest(observed = null, estimated = 30_000)), null)
        assertEquals(ContextUsageReason.NEVER_OBSERVED, estimated.reason)
        assertEquals(ContextUsageValueText.AboutPercent(estimated.estimatedPercent!!), ContextUsagePanel.settingsValue(estimated))
        assertEquals(ContextUsageValueText.Unavailable, ContextUsagePanel.settingsValue(ContextUsageSummary.NONE))
        assertEquals(ContextUsageValueText.Unavailable, ContextUsagePanel.settingsValue(null))
        val unknown = ContextUsagePresentation.summary(listOf(manifest(observed = 40_000, b = null)), null)
        assertEquals(ContextUsageValueText.Unavailable, ContextUsagePanel.settingsValue(unknown))
    }

    @Test
    fun settings_usage_value_plain_percent() {
        val saved = Locale.getDefault()
        try {
            // Not rewritten by locale into "40 %" / "٤٠٪": the settings row and the ring both write "N%".
            for (locale in listOf(Locale.FRANCE, Locale.forLanguageTag("ar"), Locale.GERMANY, Locale.US)) {
                Locale.setDefault(locale)
                assertEquals("40%", ContextUsagePanel.percentText(40))
            }
        } finally {
            Locale.setDefault(saved)
        }
    }

    @Test
    fun compacted_count_singular_formats() {
        val (_, plurals) = parse(File("src/main/res/values/strings.xml"))
        val items = plurals.getValue("context_usage_compacted_count")
        assertEquals("Condensed 1 time · 1.2K", String.format(Locale.US, items.getValue("one"), 1, "1.2K"))
        assertEquals("Condensed 3 times · 1.2K", String.format(Locale.US, items.getValue("other"), 3, "1.2K"))
    }

    @Test
    fun panel_strings_present_in_16_locales() {
        val failures = mutableListOf<String>()
        for (locale in LOCALES) {
            val (strings, plurals) = parse(File("src/main/res/$locale/strings.xml"))
            for (key in PLAIN_KEYS) {
                val value = strings[key]
                if (value.isNullOrBlank()) failures += "$locale $key missing"
            }
            for ((key, args) in FORMATTED_KEYS) {
                val value = strings[key]
                if (value.isNullOrBlank() || args.any { !value.contains(it) }) failures += "$locale $key: $value"
            }
            for ((key, args) in PLURAL_KEYS) {
                val items = plurals[key]
                if (items.isNullOrEmpty() || !items.containsKey("other")) {
                    failures += "$locale $key plurals missing"
                    continue
                }
                items.forEach { (quantity, text) ->
                    if (args.any { !text.contains(it) }) failures += "$locale $key[$quantity]: $text"
                }
            }
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    private fun observedSummary(checkpoint: ContextUsageCheckpoint?): ContextUsageSummary =
        ContextUsagePresentation.summary(listOf(manifest(observed = 40_000)), checkpoint).also {
            assertEquals(ContextUsageDisplay.PERCENT, it.display)
        }

    private fun manifest(
        observed: Int?,
        estimated: Int = observed ?: 0,
        b: Int? = 100_000,
        segments: List<ContextManifestSegment> = emptyList(),
    ) = ContextManifest(
        requestId = "r1",
        conversationId = "c1",
        purpose = RequestPurpose.CHAT,
        transport = "anthropic",
        model = "m1",
        W = 128_000,
        O = 8192,
        B = b,
        basis = ContextBasis.UNKNOWN,
        estimatedInput = estimated,
        observedInput = observed,
        segments = segments,
        unansweredMerged = 0,
        reminder = false,
        stopReason = StopReason.fromStored(null),
        createdAt = 1_000,
    )

    private fun parse(file: File): Pair<Map<String, String>, Map<String, Map<String, String>>> {
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
        val strings = mutableMapOf<String, String>()
        val stringNodes = doc.getElementsByTagName("string")
        for (i in 0 until stringNodes.length) {
            val el = stringNodes.item(i) as Element
            strings[el.getAttribute("name")] = el.textContent
        }
        val plurals = mutableMapOf<String, Map<String, String>>()
        val pluralNodes = doc.getElementsByTagName("plurals")
        for (i in 0 until pluralNodes.length) {
            val el = pluralNodes.item(i) as Element
            val items = el.getElementsByTagName("item")
            plurals[el.getAttribute("name")] = (0 until items.length).associate { j ->
                val item = items.item(j) as Element
                item.getAttribute("quantity") to item.textContent
            }
        }
        return strings to plurals
    }

    private companion object {
        val LOCALES = listOf(
            "values", "values-zh-rCN", "values-zh-rTW", "values-ja", "values-ko", "values-de", "values-fr",
            "values-es", "values-pt-rBR", "values-ru", "values-tr", "values-ar", "values-hi", "values-vi",
            "values-in", "values-th",
        )
        val PLAIN_KEYS = listOf(
            "context_usage_title", "context_usage_measured", "context_usage_estimated",
            "context_usage_segment_conversation", "context_usage_segment_library", "context_usage_segment_summary",
            "context_usage_segment_instructions", "context_usage_segment_memory", "context_usage_segment_free",
            "context_usage_unavailable", "context_usage_hint_window_unknown", "context_usage_hint_compacted",
            "context_usage_hint_empty", "context_usage_breaker_paused", "context_usage_retry",
        )
        val FORMATTED_KEYS = mapOf(
            "context_usage_about_percent" to listOf("%1\$d"),
        )
        val PLURAL_KEYS = mapOf(
            "context_usage_compacted_count" to listOf("%1\$d", "%2\$s"),
            "context_usage_omitted_notes" to listOf("%1\$d"),
            "context_usage_omitted_knowledge" to listOf("%1\$d"),
            "context_usage_omitted_memory" to listOf("%1\$d"),
        )
    }
}
