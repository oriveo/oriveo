package ai.oriveo.community.feature.modelpicker

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelPickerSheetTest {

    /**
     * Moving the chain to a background thread only works because it is a pure function whose output is
     * decided by its arguments. This recomputes the grouping, counting and filtering steps by hand to
     * show the aggregate function does not change any of the three.
     */
    @Test
    fun `sections result equals the step by step chain`() {
        val providers = pickerFixtureProviders()

        val expectedUnfiltered = buildProviderSections(
            context = ModelPickerContext.Home,
            providers = providers,
            currentProviderId = "openai",
            currentModel = null,
            searchText = "gpt",
        )
        val expected = ModelPickerSectionsResult(
            providerSections = applyModelPickerCapabilityFilter(
                expectedUnfiltered,
                emptySet(),
                toolCallMemoryVerdict = { _, _ -> null },
            ),
            capabilityFilterCounts = modelPickerCapabilityFilterCounts(
                expectedUnfiltered,
                toolCallMemoryVerdict = { _, _ -> null },
            ),
        )

        val actual = buildModelPickerSectionsResult(
            context = ModelPickerContext.Home,
            providers = providers,
            activeProviderId = "openai",
            currentModel = null,
            searchText = "gpt",
            selectedCapabilityFilters = emptySet(),
            toolCallMemoryVerdict = { _, _ -> null },
        )

        assertEquals(expected, actual)
    }

    /**
     * The fix for the long main-thread frame is running this chain on Dispatchers.Default, which is
     * only an equivalent change if switching threads does not switch results. Run the same input on
     * the calling thread and on the default dispatcher and require identical output.
     */
    @Test
    fun `sections result is identical when computed on the default dispatcher`() = runBlocking {
        val providers = pickerFixtureProviders()

        fun compute() = buildModelPickerSectionsResult(
            context = ModelPickerContext.Chat,
            providers = providers,
            activeProviderId = "openai",
            currentModel = null,
            searchText = "",
            selectedCapabilityFilters = emptySet(),
            toolCallMemoryVerdict = { _, _ -> null },
        )

        val onCallerThread = compute()
        val onDefaultDispatcher = withContext(Dispatchers.Default) { compute() }

        assertEquals(onCallerThread, onDefaultDispatcher)
        assertEquals(
            onCallerThread.providerSections.flatMap { section -> section.models.map { it.id } },
            onDefaultDispatcher.providerSections.flatMap { section -> section.models.map { it.id } },
        )
    }

    /**
     * The real regression surface is whether the sheet keeps the chain on the main thread: Compose's
     * `remember {}` is synchronous, so leaving it there puts the whole cost back into one frame. This
     * pins the chain inside `withContext(Dispatchers.Default)` and pins that nothing is drawn for the
     * empty state before the first result arrives, since an empty state would tell the user there are
     * no models when the list is merely not computed yet.
     */
    @Test
    fun `model picker precomputation stays off the main thread`() {
        val source = File("src/main/java/ai/oriveo/community/feature/modelpicker/ModelPickerSheet.kt").readText()
        val sheetSource = source.requiredSlice(
            from = "fun ModelPickerSheet(",
            to = "private fun ColumnScope.ModelPickerContent(",
        )

        assertTrue(sheetSource.contains("produceState<ModelPickerSectionsResult?>("))
        assertTrue(sheetSource.contains("withContext(Dispatchers.Default)"))
        assertTrue(sheetSource.contains("buildModelPickerSectionsResult("))
        // Neither of the two heavy steps may appear in the sheet's synchronous composition again.
        assertFalse(sheetSource.contains("modelPickerCapabilityFilterCounts("))
        assertFalse(sheetSource.contains("applyModelPickerCapabilityFilter("))
        // While computing, draw nothing: no empty state and no fake zero.
        assertTrue(sheetSource.contains("isComputing = sectionsResult == null,"))

        val contentSource = source.requiredSlice(
            from = "private fun ColumnScope.ModelPickerContent(",
            to = "internal fun buildModelPickerListEntries(",
        )
        assertTrue(contentSource.contains("if (isComputing) {"))
        assertTrue(contentSource.contains("capabilityFilterCounts: Map<ModelPickerCapabilityFilterKind, Int>?,"))
    }

    private fun pickerFixtureProviders(): List<Provider> = listOf(
        Provider(
            id = "openai",
            kind = ProviderKind.OpenAI,
            models = listOf(
                AIModel(id = "gpt-4o", name = "GPT-4o", isAvailable = true),
                AIModel(id = "gpt-4o-mini", name = "GPT-4o mini", isAvailable = true),
                AIModel(id = "o3", name = "o3", isAvailable = true),
            ),
        ),
        Provider(
            id = "anthropic",
            kind = ProviderKind.Anthropic,
            models = listOf(
                AIModel(id = "claude-sonnet", name = "Claude Sonnet", isAvailable = true),
            ),
        ),
    )
}

private fun String.requiredSlice(from: String, to: String): String {
    val start = indexOf(from)
    require(start >= 0) { "Missing source marker: $from" }
    val end = indexOf(to, start)
    require(end > start) { "Missing source marker: $to" }
    return substring(start, end)
}
