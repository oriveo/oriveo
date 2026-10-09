package ai.oriveo.community.feature.providers.detail

import ai.oriveo.community.R
import ai.oriveo.community.core.provider.GenerationParameterSupportPresentation
import ai.oriveo.community.core.provider.LocalEngineGenerationProfiles
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The status caption and parameter-name formatting for every row on the model
 * behavior page.
 *
 * Two things are pinned at once:
 * - In the ordinary case the row stays silent: ten rows of `Supported ·
 *   Source: ...` would drown out the unverified / fixed / unknown rows that
 *   actually need attention.
 * - In the non-ordinary case nothing is dropped: cutting noise must never
 *   become cutting information -- `Source` is the only clue for where a
 *   given verdict came from.
 */
class GenerationParameterRowNoiseTest {

    /**
     * This page used to keep three local functions
     * (`generationParameterSupportKey` / `generationParameterSupportLabelRes` /
     * `generationParameterShowsStatusNote`) that only recognized five values,
     * silently calling `unsupported` / `accepted` / `future_supported` all
     * "unknown". The whole table has since converged on the shared contract
     * projection [GenerationParameterSupportPresentation], whose own semantics
     * are pinned in `GenerationParameterSupportPresentationContractTest`. This
     * test only guards against those three functions growing back here.
     */
    @Test
    fun `the sheet no longer keeps a second support label switch`() {
        val source = File(
            "src/main/java/ai/oriveo/community/feature/providers/detail/GenerationParameterDefaultsSheet.kt",
        ).readText()
        listOf(
            "fun generationParameterSupportKey(",
            "fun generationParameterSupportLabelRes(",
            "fun generationParameterShowsStatusNote(",
        ).forEach { symbol ->
            assertFalse("$symbol has converged into the shared projection and must not come back to life in this file", source.contains(symbol))
        }
        assertTrue(
            "this page must consume the shared contract projection",
            source.contains(".effectiveSupport(parameter.support, decision?.resolution?.support)") &&
                source.contains("GenerationParameterSupportPresentation.entry(supportKey)"),
        )
        // In the ordinary case the row stays silent: the `supported` row renders nothing at all.
        assertFalse(
            GenerationParameterSupportPresentation.entry(
                GenerationParameterSupportPresentation.effectiveSupport("supported", "supported"),
            ).renders,
        )
        // In the non-ordinary case nothing is dropped: the status sentence still carries Source.
        assertTrue(
            GenerationParameterSupportPresentation.entry(
                GenerationParameterSupportPresentation.effectiveSupport("supported", "unsupported"),
            ).renders,
        )
    }

    @Test
    fun `the status sentence never drops Source and never leaves a dangling colon`() {
        assertEquals(
            "Unknown · Source: Official configuration",
            generationParameterStatusText("Unknown", "Source", "Official configuration"),
        )
        assertEquals("Unknown", generationParameterStatusText("Unknown", "Source", null))
        assertEquals("Unknown", generationParameterStatusText("Unknown", "Source", "   "))
    }

    @Test
    fun `parameter titles have a single formatter`() {
        assertEquals(R.string.generation_parameter_name_top_p, generationParameterTitleRes("top_p"))
        assertEquals(R.string.max_tokens, generationParameterTitleRes("max_output_tokens"))
        assertEquals(R.string.generation_parameter_name_other, generationParameterTitleRes("future_wire_id"))

        val productionIds = LocalEngineGenerationProfiles.profile("llamacpp")
            ?.parameters
            .orEmpty()
            .mapNotNull { it.id }
        assertTrue("production profile must exercise the mapping", productionIds.isNotEmpty())
        productionIds.forEach { id ->
            assertNotEquals("production id leaked into the generic fallback: $id", R.string.generation_parameter_name_other, generationParameterTitleRes(id))
        }
        assertEquals(R.string.generation_parameter_source_official, generationParameterSourceTitleRes("authoritative_metadata"))
        assertEquals(R.string.generation_parameter_source_other, generationParameterSourceTitleRes("future_source"))
        assertEquals(R.string.relay_transport_openai_responses, generationTransportTitleRes("responses_api"))
        assertEquals(R.string.generation_parameter_transport_other, generationTransportTitleRes("future_transport"))
    }

    @Test
    fun `accessibility label is assembled from exactly what the screen shows`() {
        val statusNote = generationParameterStatusText("Unknown", "Source", "Connection declaration")
        assertEquals(
            "Top P · Not verified · Unknown · Source: Connection declaration",
            generationParameterAccessibilityLabel("Top P", "Not verified", statusNote),
        )
        // Ordinary case: with no badge and no caption, only the parameter name is read, not a string of empty separators.
        assertEquals("Top P", generationParameterAccessibilityLabel("Top P", null, null))
        assertEquals("Top P", generationParameterAccessibilityLabel("Top P", "", ""))
    }

    /**
     * Structural guard: parameter-name formatting must not go back to being
     * inlined. It used to be written out separately in three places -- the
     * row title, the edit-field label, and the dormant-parameters list --
     * each doing its own `id.replace('_', ' ')`, while a fourth place (the
     * conflict summary) didn't convert it at all, so the same screen could
     * show `top p` up top and `top_p` further down.
     */
    @Test
    fun `the sheet no longer inlines the underscore replacement`() {
        val source = File(
            "src/main/java/ai/oriveo/community/feature/providers/detail/GenerationParameterDefaultsSheet.kt",
        ).readText()
        val codeLines = source.lines().filterNot { line ->
            val trimmed = line.trimStart()
            trimmed.startsWith("//") || trimmed.startsWith("*") || trimmed.startsWith("/*")
        }
        val inlined = codeLines.count { it.contains(".replace('_', ' ')") }
        assertEquals("a wire id must not be shown directly via underscore replacement", 0, inlined)
        assertTrue(source.contains("internal fun generationParameterTitleRes("))
        // The conflict summary must go through the same formatter too (this is the one spot that previously didn't convert at all).
        assertTrue(
            source.contains("localizedConflictTitles += generationParameterTitle(id)"),
        )
    }

    /** This page previously had zero hits for contentDescription / semantics, making it completely unusable with a screen reader. */
    @Test
    fun `the sheet exposes accessibility semantics`() {
        val source = File(
            "src/main/java/ai/oriveo/community/feature/providers/detail/GenerationParameterDefaultsSheet.kt",
        ).readText()
        assertTrue(source.contains("contentDescription = rowLabel"))
        assertTrue(source.contains("contentDescription = parameterTitle"))
        assertTrue(source.contains("mergeDescendants = true"))
        assertTrue(
            "the spoken label must reuse the same formatting as the displayed text, not a separate copy",
            source.contains("generationParameterAccessibilityLabel(parameterTitle, unverifiedBadge, statusNote)"),
        )
        assertFalse("diagnostic parameter must not render a raw wire id", source.contains("Text(entry.parameter"))
        assertFalse("diagnostic transport must not render a raw wire id", source.contains("${'$'}{entry.transport}"))
    }

    /**
     * Both call sites of this sheet hang it directly under a
     * `ModalBottomSheet`, and a dozen-plus parameters each with an input
     * field will always overflow one screen -- without scrolling, the bottom
     * half is neither visible nor tappable, worse than the overflow on the
     * model control sheet.
     *
     * This also pins the model-selection row: it must be horizontal and
     * lazy, since `provider.models` can reach the hundreds.
     */
    @Test
    fun `the generation parameter sheet scrolls without nesting a lazy list`() {
        val source = File(
            "src/main/java/ai/oriveo/community/feature/providers/detail/GenerationParameterDefaultsSheet.kt",
        ).readText()
        // `substringAfter` returns the whole source unchanged when the anchor is missing,
        // which would make the assertion trivially true. A prior refactor once silently
        // turned this into a no-op assertion, so the anchor is checked before the content.
        val anchor = "Column(\n                modifier = Modifier"
        assertTrue("the root Column's anchor is stale, this assertion no longer catches anything", source.contains(anchor))
        val root = source.substringAfter(anchor).substringBefore("verticalArrangement")
        assertTrue("the root Column must be scrollable", root.contains("verticalScroll(rememberScrollState())"))
        // This component is a public API and callers can place it inside any container: a Lazy
        // list crashes outright inside a scrollable parent, while verticalScroll just silently
        // stops working. Swapping the parameter area for a Lazy list is forbidden here unless
        // every call site is updated at the same time.
        // Only code lines are checked -- the source comment right there explains why a
        // LazyColumn isn't used.
        val codeLines = source.lines().filterNot { line ->
            val trimmed = line.trimStart()
            trimmed.startsWith("//") || trimmed.startsWith("*") || trimmed.startsWith("/*")
        }
        // Only vertical Lazy lists are forbidden: the crash condition is a Lazy list sharing an
        // axis with an unbounded parent. LazyRow's main axis is horizontal and always bounded,
        // so it's deliberately left off this list -- the model-selection row depends on it.
        assertFalse(
            "must not nest a vertical Lazy list inside a scrollable root container",
            codeLines.any { it.contains("LazyColumn") || it.contains("LazyVerticalGrid") },
        )
        // A single connection can have dozens or hundreds of models, so the model-selection row
        // must scroll horizontally, otherwise anything past the first few gets clipped and can
        // never be selected; and since `provider.models` can reach the hundreds, a non-lazy Row
        // would compose every chip at once.
        val modelPickerAnchor = "items(items = provider.models, key = { it.id })"
        assertTrue("the model-selection row's anchor is stale, this assertion no longer catches anything", source.contains(modelPickerAnchor))
        assertTrue(
            "the model-selection row must be a horizontal lazy list",
            source.substringBefore(modelPickerAnchor).takeLast(400).contains("LazyRow("),
        )
        assertTrue(
            "if the anchor goes stale this test no longer catches anything",
            source.substringAfter(modelPickerAnchor).contains("FilterChip("),
        )
    }

    /** These localized strings must be complete across all 16 locale files, not left with only the English default. */
    @Test
    fun `new model control strings have complete locale parity`() {
        val keys = listOf(
            // A few older strings were retired as this panel's editing UI and status messaging
            // evolved, replaced either by shorter shared banners or by per-cause recovery
            // actions instead of a single generic message.
            "model_control_context_unavailable",
            "model_control_choose_connection",
            "model_control_choose_other_model",
            "generation_parameter_source_official",
            "generation_parameter_source_connection",
            "generation_parameter_source_runtime",
            "generation_parameter_source_preference",
            "generation_parameter_source_override",
            "generation_parameter_source_legacy",
            "generation_parameter_source_other",
            "generation_parameter_transport_other",
            "generation_parameter_name_frequency_penalty",
            "generation_parameter_name_presence_penalty",
            "generation_parameter_name_repeat_penalty",
            "generation_parameter_name_seed",
            "generation_parameter_name_response_format",
            "generation_parameter_name_verbosity",
            "generation_parameter_name_log_probabilities",
            "generation_parameter_name_top_log_probabilities",
            "generation_parameter_name_reasoning_effort",
            "generation_parameter_name_reasoning_budget",
            "generation_parameter_name_reasoning_mode",
            "generation_parameter_name_route_require_parameters",
            "generation_parameter_name_other",
        )
        val resourceRoot = File("src/main/res")
        val default = strings(File(resourceRoot, "values/strings.xml"))
        keys.forEach { key -> assertTrue("default value missing: $key", !default[key].isNullOrBlank()) }

        val localeDirs = resourceRoot.listFiles()
            .orEmpty()
            .filter { it.isDirectory && it.name.startsWith("values-") && File(it, "strings.xml").exists() }
        assertEquals("15 locale directories + the default values = 16 total", 15, localeDirs.size)
        localeDirs.forEach { dir ->
            val table = strings(File(dir, "strings.xml"))
            keys.forEach { key ->
                val value = table[key]
                assertTrue("${dir.name} is missing $key", !value.isNullOrBlank())
                assertNotEquals(
                    "${dir.name}'s $key is still the English default value",
                    default[key],
                    value,
                )
            }
        }
    }

    private fun strings(file: File): Map<String, String> {
        val text = file.readText()
        return Regex("""<string name="([^"]+)"[^>]*>(.*?)</string>""", RegexOption.DOT_MATCHES_ALL)
            .findAll(text)
            .associate { it.groupValues[1] to it.groupValues[2] }
    }
}
