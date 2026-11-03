package ai.oriveo.community.feature.chat.components

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import ai.oriveo.community.R
import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.core.model.NonUsdCost
import ai.oriveo.community.core.provider.CostSource
import ai.oriveo.community.core.usage.CostPart
import ai.oriveo.community.ui.theme.DarkOriveoColors
import ai.oriveo.community.ui.theme.LightOriveoColors
import ai.oriveo.community.ui.theme.OriveoTheme
import java.io.File
import java.util.Locale
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Rendering contract for the token usage dialog: three states -- a positive
 * number, an explicit zero, and a missing field -- crossed with card
 * visibility and the total.
 *
 * The primary fields (input / output / total) always render; when a value
 * can't be resolved the Composable shows its own missing-state text. Optional
 * fields (cache read / write) render nothing at all when missing -- never a
 * placeholder pretending the value was actually collected.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class MessageTokenUsagePresentationTest {

    @get:Rule
    val composeRule = createComposeRule()

    /** Dark theme lifts the cost and metric cards to the elevated surface; light keeps the inset fill. */
    @Test
    fun dark_cards_elevated() {
        assertEquals(DarkOriveoColors.surfaceElevated, tokenUsageCardFill(DarkOriveoColors, isDark = true))
        assertEquals(LightOriveoColors.surfaceInset, tokenUsageCardFill(LightOriveoColors, isDark = false))
    }

    /** Matches iOS: a trailing close button that dismisses, and the title at least 24dp below the sheet top. */
    @Test
    fun token_sheet_has_close_button_and_top_inset() {
        var dismissed = 0
        composeRule.setContent {
            OriveoTheme(darkTheme = false) {
                MessageTokenUsageDialog(
                    inputTokens = 1200,
                    outputTokens = 300,
                    cacheReadTokens = null,
                    cacheWriteTokens = null,
                    estimatedCost = 0.0,
                    costSource = null,
                    nonUsdCost = null,
                    onDismiss = { dismissed++ },
                )
            }
        }
        composeRule.waitForIdle()
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()

        val sheetTop = composeRule.onNodeWithTag(TOKEN_USAGE_SHEET_TEST_TAG).getBoundsInRoot().top
        val titleTop = composeRule
            .onNodeWithText(context.getString(R.string.chat_token_usage_title))
            .getBoundsInRoot().top
        assertTrue("title top inset ${titleTop - sheetTop} should be >= 24dp", titleTop - sheetTop >= 24.dp)

        val close = composeRule.onNodeWithContentDescription(context.getString(R.string.close))
        close.assertIsDisplayed()
        close.performClick()
        composeRule.waitForIdle()
        assertEquals(1, dismissed)
    }

    private fun rows(
        input: Int? = null,
        output: Int? = null,
        cacheRead: Int? = null,
        cacheWrite: Int? = null,
    ) = resolveTokenUsageRows(
        MessageTokenUsageSnapshot(
            inputTokens = input,
            outputTokens = output,
            cacheReadTokens = cacheRead,
            cacheWriteTokens = cacheWrite,
        ),
    )

    @Test
    fun `positive values render both cache sub-rows inside the input card`() {
        val result = rows(input = 12_480, output = 856, cacheRead = 9_216, cacheWrite = 128)

        assertEquals(12_480, result.inputTokens)
        assertEquals(856, result.outputTokens)
        assertEquals(
            listOf(
                TokenUsageCacheRow(TokenUsageCacheRow.Kind.CacheRead, 9_216),
                TokenUsageCacheRow(TokenUsageCacheRow.Kind.CacheWrite, 128),
            ),
            result.cacheRows,
        )
        // When the input card carries sub-rows its height far exceeds the output card, so side-by-side would look uneven; the layout switches to a single column instead.
        assertTrue(result.singleColumn)
    }

    @Test
    fun `an explicitly reported zero still renders its row`() {
        val result = rows(input = 1_000, output = 20, cacheRead = 0)

        assertEquals(
            listOf(TokenUsageCacheRow(TokenUsageCacheRow.Kind.CacheRead, 0)),
            result.cacheRows,
        )
        // An explicitly reported 0 is real information -- no cache hit this time -- and must show as 0, not disappear.
        assertEquals(0, result.cacheRows.single().value)
    }

    @Test
    fun `absent cache fields render no row at all instead of a placeholder`() {
        val result = rows(input = 1_000, output = 20)

        assertTrue(result.cacheRows.isEmpty())
        // With no cache sub-rows, it falls back to two side-by-side columns for input/output.
        assertFalse(result.singleColumn)
    }

    @Test
    fun `only one observed cache bucket renders only that row`() {
        assertEquals(
            listOf(TokenUsageCacheRow(TokenUsageCacheRow.Kind.CacheWrite, 0)),
            rows(input = 1_000, output = 20, cacheWrite = 0).cacheRows,
        )
        assertEquals(
            listOf(TokenUsageCacheRow(TokenUsageCacheRow.Kind.CacheRead, 512)),
            rows(input = 1_000, output = 20, cacheRead = 512).cacheRows,
        )
    }

    @Test
    fun `total needs both input and output and never double-counts cache`() {
        // The cache breakdown is already included in the input count, so the total only adds input + output.
        assertEquals(13_336, rows(input = 12_480, output = 856, cacheRead = 9_216).total)
        assertEquals(0, rows(input = 0, output = 0).total)
        assertNull(rows(input = 12_480).total)
        assertNull(rows(output = 856).total)
        assertNull(rows().total)
    }

    @Test
    fun `total saturates instead of overflowing`() {
        assertEquals(Int.MAX_VALUE, rows(input = Int.MAX_VALUE, output = Int.MAX_VALUE).total)
    }

    /**
     * Structural layout guard: the dialog must be a BottomSheet (matching the
     * sheet / dialog form used elsewhere), with top breathing room coming
     * from OriveoSheetDragHandle's own spacing, not the bare Material3
     * default handle. This is a deliberate form-factor decision -- reverting
     * to AlertDialog needs a design review first.
     */
    @Test
    fun `token usage dialog is a bottom sheet with the shared drag handle`() {
        val source = File("src/main/java/ai/oriveo/community/feature/chat/components/MessageBubble.kt").readText()
        // Sliced only up to the next private fun, to avoid misreading another component's code in the same file.
        val dialog = source
            .substringAfter("internal fun MessageTokenUsageDialog(")
            .substringBefore("private fun TokenUsageMetric(")

        assertTrue("the dialog should be a ModalBottomSheet", dialog.contains("ModalBottomSheet("))
        // The divider must only be drawn when there are cache sub-rows. Kotlin's trailing-lambda
        // syntax always binds to subRows, which would make it permanently non-null and draw the
        // divider unconditionally -- messages with no cache visibility at all would be left with
        // a dangling line under the input card. subRows = must be passed explicitly.
        assertTrue(
            "the cache sub-rows must be explicitly gated on whether cacheRows is empty, not written as a trailing lambda",
            dialog.contains("subRows = if (rows.cacheRows.isEmpty())"),
        )
        assertTrue("the top spacing should reuse OriveoSheetDragHandle", dialog.contains("OriveoSheetDragHandle()"))
        assertFalse("must no longer be a centered AlertDialog", dialog.contains("AlertDialog("))
        // Cache sub-rows must be drawn inside the input card (TokenUsageMetric's subRows slot), not turned back into an equal-weight side-by-side layout.
        assertTrue("cache rows should render as sub-rows of the input card", dialog.contains("rows.cacheRows.forEach"))
    }

    /**
     * Dark-mode readability guard: every Text inside this dialog must carry
     * an explicit color.
     *
     * This isn't pedantry. Without a color, Material3's `Text` falls back to
     * `LocalContentColor`, which this codebase never provides (`OriveoTheme`
     * only provides LocalOriveoColors / LocalIsDarkTheme / LocalDensity /
     * LocalBrandImageBitmapCache); `ModalBottomSheet`'s own
     * `contentColor = contentColorFor(containerColor)` falls through too,
     * since OriveoColors and the Material3 ColorScheme are two independent
     * palettes and `ColorScheme.contentColorFor` returns Unspecified when no
     * role matches. The sheet renders in its own Dialog window with no
     * Material3 Surface anywhere in its ancestor chain to fall back on, so it
     * ends up with the `compositionLocalOf { Color.Black }` default.
     *
     * The bug only shows up in dark mode: on a real device the title and all
     * three numeric values render pure black against a dark surface, at a
     * contrast ratio too low to read; in light mode black text on a white
     * background looks fine by coincidence, so it can ship undetected.
     * Neither a pure function test nor a layout assertion can see color --
     * only this source-level guard can pin it down.
     */
    @Test
    fun `every text in the token usage sheet carries an explicit color`() {
        val source = File("src/main/java/ai/oriveo/community/feature/chat/components/MessageBubble.kt").readText()
        // Covers both MessageTokenUsageDialog and TokenUsageMetric, stopping at the next unrelated component.
        val sheet = source
            .substringAfter("internal fun MessageTokenUsageDialog(")
            .substringBefore("private fun FooterActionButton(")

        val naked = textCalls(sheet).filterNot { it.contains("color = ") }
        assertTrue(
            "these Text calls have no explicit color and would fall back to M3's default Color.Black in dark mode: $naked",
            naked.isEmpty(),
        )
        // Sanity check that the slice isn't empty (otherwise the assertion above would pass vacuously with zero Text calls).
        assertTrue("the source slice should at least include the title's Text call", textCalls(sheet).size >= 6)
    }

    /** Extracts the full text of every `Text(...)` call in [region] by balancing parentheses. */
    private fun textCalls(region: String): List<String> {
        val calls = mutableListOf<String>()
        Regex("""\bText\(""").findAll(region).forEach { match ->
            var depth = 0
            var i = match.range.last
            while (i < region.length) {
                when (region[i]) {
                    '(' -> depth++
                    ')' -> {
                        depth--
                        if (depth == 0) {
                            calls += region.substring(match.range.first, i + 1)
                            return@forEach
                        }
                    }
                }
                i++
            }
        }
        return calls
    }

    @Test
    fun `menu subtitle shows the compact total and nothing without a total`() {
        // Same as iOS — compact total under the menu item; no total, no subtitle (no placeholder text).
        assertEquals("13.3K", tokenUsageMenuSubtitle(MessageTokenUsageSnapshot(inputTokens = 12_480, outputTokens = 856), "en"))
        assertEquals("999", tokenUsageMenuSubtitle(MessageTokenUsageSnapshot(inputTokens = 900, outputTokens = 99), "en"))
        assertEquals("0", tokenUsageMenuSubtitle(MessageTokenUsageSnapshot(inputTokens = 0, outputTokens = 0), "en"))
        assertNull(tokenUsageMenuSubtitle(MessageTokenUsageSnapshot(inputTokens = 12_480), "en"))
        assertNull(tokenUsageMenuSubtitle(MessageTokenUsageSnapshot(), "en"))
    }

    /**
     * Cost row of the sheet, driven by the shared fixture (same answer on iOS / Android / Web):
     * visibility, the Estimated tag and the value shape, all asserted on the production snapshot.
     */
    @Test
    fun costRowFixtureCases() {
        val root = Json.parseToJsonElement(
            workspaceFile("shared/test-fixtures/provider-pricing/token-usage-cost-row.v1.json").readText(),
        ).jsonObject
        assertEquals(1, root["v"]!!.jsonPrimitive.content.toInt())
        assertEquals(CostFormatter.COST_EPSILON, root["epsilon"]!!.jsonPrimitive.double, 0.0)
        val cases = root["cases"]!!.jsonArray.map { it.jsonObject }
        assertEquals(11, cases.size)
        val noData = "No data"
        val locale = Locale.US

        cases.forEach { case ->
            val id = case["id"]!!.jsonPrimitive.content
            val message = case["message"]!!.jsonObject
            val expect = case["expect"]!!.jsonObject
            val nonUsd = (message["nonUsdCost"] as? JsonObject)?.let {
                NonUsdCost(
                    currencyCode = it["currencyCode"]!!.jsonPrimitive.content,
                    amount = it["amount"]!!.jsonPrimitive.double,
                    costSource = costSourceName(it["costSource"]!!.jsonPrimitive.contentOrNull)!!,
                )
            }
            val snapshot = MessageTokenUsageSnapshot(
                estimatedCost = message["estimatedCost"]!!.jsonPrimitive.double,
                costSource = costSourceName(message["costSource"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.contentOrNull),
                nonUsdCost = nonUsd,
            )
            val text = tokenUsageCostText(snapshot, locale, noData)
            val showsCost = expect["showsCost"]!!.jsonPrimitive.booleanOrNull!!
            assertEquals("$id showsCost", showsCost, snapshot.showsCost)
            if (!showsCost) return@forEach

            assertEquals("$id estimatedTag", expect["estimatedTag"]!!.jsonPrimitive.booleanOrNull!!, snapshot.isCostEstimated)
            val usd = CostFormatter.formatPart(CostPart("USD", snapshot.estimatedCost), locale)
            val nonUsdText = nonUsd?.let { CostFormatter.formatPart(CostPart(it.currencyCode, it.amount), locale) }.orEmpty()
            when (val value = expect["value"]!!.jsonPrimitive.content) {
                "amount" -> {
                    assertTrue("$id amount is not empty", text.isNotEmpty())
                    assertFalse("$id amount has no missing-state label: $text", text.contains(noData))
                    assertFalse("$id never shows a zero amount: $text", text == "$0.00" || text.isBlank())
                    if (usd.isNotEmpty()) assertTrue("$id has the USD part: $text", text.contains(usd))
                    if (nonUsdText.isNotEmpty()) assertTrue("$id has the non-USD part: $text", text.contains(nonUsdText))
                }
                "noData" -> assertEquals("$id noData", noData, text)
                "amountPlusNoData" -> {
                    assertTrue("$id has the USD part", usd.isNotEmpty())
                    assertEquals("$id amountPlusNoData", "$usd + $noData", text)
                }
                else -> throw AssertionError("$id unknown expect.value $value")
            }
        }
    }

    /** Fixture raw values (iOS camelCase) map to [CostSource] names ignoring case and underscores. */
    private fun costSourceName(raw: String?): String? {
        raw ?: return null
        val key = raw.replace("_", "").lowercase()
        return CostSource.entries.single { it.name.replace("_", "").lowercase() == key }.name
    }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("missing $relative")
    }
}
