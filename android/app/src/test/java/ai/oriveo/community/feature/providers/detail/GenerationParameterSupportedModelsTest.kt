package ai.oriveo.community.feature.providers.detail

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.GenerationAccess
import ai.oriveo.community.core.provider.GenerationParameterEntryScope
import ai.oriveo.community.core.provider.GenerationParameterPanelPresentation
import ai.oriveo.community.core.provider.MetadataTestFixtures
import java.io.File
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A control that is "not adjustable" should still be actionable: it gets grayed out, but it
 * must also expose a primary action ("view models that support this parameter") -- otherwise
 * the user is stuck. Being told "this is fixed by the model and won't take effect if changed"
 * immediately raises the question "which model should I use instead?", and the previous
 * version never answered that.
 *
 * `GenerationParameterSupportPresentation` already carries `primaryActionRes` in its table
 * (the `NotAdjustable` case always sets it), but the panel never rendered it -- present in
 * the table, missing from the UI.
 *
 * The secondary page must also be pushed inside the same container rather than opening
 * another modal layer (stacking two overlays reads as unfinished).
 */
class GenerationParameterSupportedModelsTest {

    private val sheetSource: String by lazy {
        File("src/main/java/ai/oriveo/community/feature/providers/detail/GenerationParameterDefaultsSheet.kt")
            .readText()
    }

    @Test
    fun `not adjustable rows render the primary action from the shared table`() {
        assertTrue(
            "not-adjustable rows must render the shared table's primaryActionRes, otherwise there's no way forward",
            sheetSource.contains("supportPresentation.primaryActionRes"),
        )
        assertTrue(
            // The secondary page is a `GenerationParameterPage` sealed class rather than a plain
            // `String?`, since the same container now hosts three sub-pages: parameter
            // candidates, custom fields, and custom-field candidates.
            "the primary action must actually navigate into the secondary page, not just render text",
            sheetSource.contains("page = GenerationParameterPage.SupportedModels(id)"),
        )
    }

    @Test
    fun `the supported models page is pushed inside the same container`() {
        assertTrue(
            "the secondary page must switch within the same container (pushed in place, not opened as another modal)",
            sheetSource.contains("AnimatedContent("),
        )
        // Opening another ModalBottomSheet would stack two overlays, which is disallowed.
        assertFalse(
            "the secondary page must not open another ModalBottomSheet",
            sheetSource.lines()
                .filterNot { it.trimStart().startsWith("//") || it.trimStart().startsWith("*") }
                .any { it.contains("ModalBottomSheet(") },
        )
        assertTrue(
            "the secondary page must offer a way back",
            sheetSource.contains("R.string.back"),
        )
    }

    @Test
    fun `the candidate query reuses the row predicate instead of writing a second one`() {
        assertTrue(
            "the candidate query must reuse the shared projection and the same presentation table, not re-implement the support predicate in the UI",
            sheetSource.contains("GenerationParameterPanelPresentation.modelsAcceptingParameter("),
        )
    }

    @After
    fun tearDown() = MetadataTestFixtures.clear()

    /**
     * A behavioral assertion, not a structural one: the candidate list must include only
     * models where this parameter is actually adjustable.
     *
     * If a model with a fixed value showed up in the list, tapping into it would just show
     * the same grayed-out control again -- worse than not offering the path at all, since the
     * list implied it would work.
     */
    @Test
    fun `only models whose row is actually editable become candidates`() {
        MetadataTestFixtures.applyRaw(metadataWith(
            "adjustable-model" to "supported",
            "fixed-model" to "fixed",
            "unsupported-model" to "unsupported",
        ))
        val provider = Provider(
            id = "11111111-1111-1111-1111-111111111111",
            kind = ProviderKind.OpenAI,
            models = listOf(
                AIModel(id = "adjustable-model", name = "adjustable-model"),
                AIModel(id = "fixed-model", name = "fixed-model"),
                AIModel(id = "unsupported-model", name = "unsupported-model"),
            ),
        )
        assertEquals(
            listOf("adjustable-model"),
            GenerationParameterPanelPresentation.modelsAcceptingParameter(
                provider = provider,
                parameterId = "temperature",
                scope = GenerationParameterEntryScope.ConnectionDefaults,
                access = GenerationAccess(canManageRuntime = true),
            ).map { it.id },
        )
    }

    /**
     * When there are no candidates, report an honest empty list -- the UI renders its own
     * empty state from that, so this must never fake a count or fall back to the full list.
     */
    @Test
    fun `an empty candidate list is reported honestly`() {
        MetadataTestFixtures.applyRaw(metadataWith("fixed-model" to "fixed"))
        val provider = Provider(
            id = "11111111-1111-1111-1111-111111111111",
            kind = ProviderKind.OpenAI,
            models = listOf(AIModel(id = "fixed-model", name = "fixed-model")),
        )
        assertTrue(
            GenerationParameterPanelPresentation.modelsAcceptingParameter(
                provider = provider,
                parameterId = "temperature",
                scope = GenerationParameterEntryScope.ConnectionDefaults,
                access = GenerationAccess(canManageRuntime = true),
            ).isEmpty(),
        )
    }

    /** The profile is resolved the same way production does (from a published response), so the test never hand-writes a `GenerationProfileRef`. */
    private fun metadataWith(vararg models: Pair<String, String>): String = buildJsonObject {
        put("version", 1)
        put("profiles", buildJsonObject {
            put("generation", buildJsonObject {
                put("parameters", buildJsonObject {
                    put("temperature", buildJsonObject { put("valueSchema", "number") })
                })
                put("templates", buildJsonObject {
                    put("openai_chat_completions", buildJsonObject {
                        put("transport", "openai_chat")
                        put("wire", buildJsonObject { put("temperature", "temperature") })
                    })
                })
            })
        })
        put("providers", buildJsonObject {
            put("openAI", buildJsonObject {
                put("resolveMap", buildJsonObject { models.forEach { (id, _) -> put(id, id) } })
                put("models", buildJsonObject {
                    models.forEach { (id, support) ->
                        put(id, buildJsonObject {
                            put("canonicalModelId", id)
                            put("transport", "openai_chat")
                            put("profiles", buildJsonObject {
                                put("generation", buildJsonObject {
                                    put("template", "openai_chat_completions")
                                    put("parameters", buildJsonArray {
                                        add(buildJsonObject {
                                            put("id", "temperature")
                                            put("support", support)
                                            put("source", "authoritative_metadata")
                                        })
                                    })
                                })
                            })
                        })
                    }
                })
            })
        })
    }.toString()
}
