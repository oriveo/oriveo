package ai.oriveo.community.feature.providers

import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.feature.modelpicker.ModelPickerListContent
import ai.oriveo.community.feature.modelpicker.ModelPickerSection
import ai.oriveo.community.feature.modelpicker.buildModelPickerListEntries
import ai.oriveo.community.feature.providers.setup.ProviderSetupCopy
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * OpenAI is an ordinary API-key provider. None of the provider screens may single it out for a
 * restriction meant for no provider at all: hiding its cost behind a "Free" pill, refusing to set
 * a default model, refusing manual models or renames, or folding its models into collapsed vendor
 * groups in the picker.
 */
class ProviderKindGateTest {

    @Test
    fun `every built-in provider shows the auto-fill note and only relay omits it`() {
        ProviderKind.entries.forEach { kind ->
            if (kind == ProviderKind.Relay) {
                assertNull(ProviderSetupCopy.autoFillNote(kind))
            } else {
                assertEquals("auto-fill note for $kind", R.string.auto_fill_note, ProviderSetupCopy.autoFillNote(kind))
            }
        }
    }

    @Test
    fun `model picker lists every OpenAI model flat even when they span vendor groups`() {
        val models = listOf(
            model("gpt-4.1", groupKey = "openai", groupName = "OpenAI"),
            model("o4-mini", groupKey = "openai", groupName = "OpenAI"),
            model("my-fine-tune", groupKey = null, groupName = null),
        )
        val provider = Provider(id = "openai-1", kind = ProviderKind.OpenAI, models = models)

        val entries = buildModelPickerListEntries(
            providerSections = listOf(ModelPickerSection(provider, models)),
            searchText = "",
            expandedProviderIds = emptySet(),
            isSingleProvider = true,
            isHome = false,
        )

        val rows = entries.map { it.content }.filterIsInstance<ModelPickerListContent.ModelRow>()
        assertEquals(models.map { it.id }, rows.map { it.model.id })
    }

    @Test
    fun `provider screens never special-case the OpenAI kind`() {
        listOf(
            "feature/providers/ProviderHeroCard.kt",
            "feature/providers/detail/ProviderDetailEnabledModels.kt",
            "feature/providers/manual/ManualModelEntryViewModel.kt",
            "feature/modelpicker/ModelPickerSheet.kt",
        ).forEach { path ->
            assertFalse(
                "$path must treat OpenAI like any other API-key provider",
                source(path).contains("ProviderKind.OpenAI"),
            )
        }

        val viewModel = source("feature/providers/detail/ProviderDetailViewModel.kt")
        val titleRule = viewModel.substringAfter("fun enabledModelsTitle(").substringBefore("\n    fun ")
        assertFalse("only relay uses the plain models title", titleRule.contains("OpenAI"))

        val screen = source("feature/providers/detail/ProviderDetailScreen.kt")
        assertFalse(
            "every provider can be renamed from the detail header",
            screen.contains("onEditName = if ("),
        )
    }

    private fun source(path: String): String =
        File("src/main/java/ai/oriveo/community/$path").readText()
            .lineSequence()
            .filterNot {
                val trimmed = it.trimStart()
                trimmed.startsWith("//") || trimmed.startsWith("*") || trimmed.startsWith("/*")
            }
            .joinToString("\n")

    private fun model(id: String, groupKey: String?, groupName: String?) = AIModel(
        id = id,
        name = id,
        isAvailable = true,
        groupKey = groupKey,
        groupName = groupName,
    )
}
