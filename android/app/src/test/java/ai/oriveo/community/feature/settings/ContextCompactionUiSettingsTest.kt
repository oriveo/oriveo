package ai.oriveo.community.feature.settings

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.entity.PreferenceEntity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/** Settings › Context single choice, and all 34 copy keys present in the 16 languages. */
@OptIn(ExperimentalCoroutinesApi::class)
class ContextCompactionUiSettingsTest {

    private val dispatcher = UnconfinedTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun settings_mode_roundtrip() = runTest(dispatcher) {
        val repository = AppPreferencesRepository(FakePreferenceDao())
        val viewModel = ContextSettingsViewModel(repository)
        val collector = launch { viewModel.aiSummaryEnabled.collect {} }

        // Default false = keep only the user's own words
        assertFalse(viewModel.aiSummaryEnabled.value)
        assertFalse(repository.getContextAISummaryEnabled())

        viewModel.setAISummaryEnabled(true)
        advanceUntilIdle()
        assertTrue(repository.getContextAISummaryEnabled())
        assertTrue(viewModel.aiSummaryEnabled.value)

        viewModel.setAISummaryEnabled(false)
        advanceUntilIdle()
        assertFalse(repository.getContextAISummaryEnabled())
        assertFalse(viewModel.aiSummaryEnabled.value)
        collector.cancel()
    }

    @Test
    fun strings_present_in_16_locales() {
        val dirs = listOf(
            "values", "values-ar", "values-de", "values-es", "values-fr", "values-hi", "values-in",
            "values-ja", "values-ko", "values-pt-rBR", "values-ru", "values-th", "values-tr",
            "values-vi", "values-zh-rCN", "values-zh-rTW",
        )
        assertEquals(16, dirs.size)
        val missing = mutableListOf<String>()
        dirs.forEach { dir ->
            val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder()
                .parse(File("src/main/res/$dir/strings.xml"))
            val strings = doc.namedNonBlank("string")
            val plurals = doc.namedNonBlank("plurals", requireOther = true)
            STRING_KEYS.filterNot { it in strings }.forEach { missing += "$dir:$it" }
            PLURAL_KEYS.filterNot { it in plurals }.forEach { missing += "$dir:$it(plurals)" }
        }
        assertEquals(34, STRING_KEYS.size + PLURAL_KEYS.size)
        assertEquals(emptyList<String>(), missing)
    }

    private fun org.w3c.dom.Document.namedNonBlank(tag: String, requireOther: Boolean = false): Set<String> {
        val nodes = getElementsByTagName(tag)
        return (0 until nodes.length).map { nodes.item(it) as Element }
            .filter { el ->
                if (!requireOther) {
                    el.textContent.isNotBlank()
                } else {
                    val items = el.getElementsByTagName("item")
                    (0 until items.length).map { items.item(it) as Element }
                        .any { it.getAttribute("quantity") == "other" && it.textContent.isNotBlank() }
                }
            }
            .map { it.getAttribute("name") }
            .toSet()
    }

    private class FakePreferenceDao : PreferenceDao {
        private val values = linkedMapOf<String, MutableStateFlow<String?>>()

        override fun observe(key: String): Flow<String?> =
            values.getOrPut(key) { MutableStateFlow(null) }

        override suspend fun get(key: String): String? = values[key]?.value

        override suspend fun set(entity: PreferenceEntity) {
            values.getOrPut(entity.key) { MutableStateFlow(null) }.value = entity.value
        }

        override suspend fun delete(key: String) {
            values.getOrPut(key) { MutableStateFlow(null) }.value = null
        }
    }

    private companion object {
        val PLURAL_KEYS = listOf(
            "context_compaction_summary_line1",
            "context_compaction_fallback_line1",
            "context_compaction_fallback_line2",
            "context_compaction_detail_kept",
        )
        val STRING_KEYS = listOf(
            "context_compaction_summary_line2",
            "context_compaction_detail_title",
            "context_compaction_detail_summary",
            "context_compaction_detail_fallback_note",
            "context_compaction_detail_model",
            "context_compaction_detail_cost",
            "context_compaction_detail_cost_unavailable",
            "context_compaction_detail_no_extra_cost",
            "context_compaction_detail_time",
            "context_compaction_action_compact",
            "context_compaction_action_recompact",
            "context_compaction_action_clear",
            "context_compaction_action_new_chat_with_summary",
            "context_compaction_toast_noop",
            "context_compaction_toast_fallback",
            "context_compaction_toast_cleared",
            "context_compaction_in_progress",
            "context_compaction_cancel",
            "context_compaction_third_hint",
            "context_compaction_third_hint_new_chat",
            "context_compaction_third_hint_dismiss",
            "context_compaction_quote_label",
            "settings_context_title",
            "settings_context_overflow_header",
            "settings_context_mode_fallback",
            "settings_context_mode_fallback_hint",
            "settings_context_mode_ai",
            "settings_context_mode_ai_hint",
            "settings_context_overflow_footer",
            "settings_context_row_value_fallback",
        )
    }
}
