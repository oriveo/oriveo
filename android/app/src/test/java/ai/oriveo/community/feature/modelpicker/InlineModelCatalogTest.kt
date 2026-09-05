package ai.oriveo.community.feature.modelpicker

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.ResolvedModel
import ai.oriveo.community.core.provider.ResolvedProviderCatalog
import ai.oriveo.community.feature.providers.detail.buildProviderCatalogGroups
import ai.oriveo.community.feature.providers.detail.shouldAutoExpandCatalogGroups
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InlineModelCatalogTest {

    @Test
    fun `whitespace query does not auto expand catalog groups`() {
        assertFalse(shouldAutoExpandCatalogGroups("   "))
        assertTrue(shouldAutoExpandCatalogGroups("gpt"))
    }

    @Test
    fun `search by supplier name keeps the whole supplier group`() {
        val provider = Provider(
            id = "openrouter-provider",
            kind = ProviderKind.OpenRouter,
            models = emptyList(),
            catalogModels = listOf(
                model(
                    id = "openai/gpt-4.1",
                    name = "GPT-4.1",
                    groupKey = "openai",
                    groupName = "OpenAI",
                ),
                model(
                    id = "openai/gpt-4.1-mini",
                    name = "GPT-4.1 Mini",
                    groupKey = "openai",
                    groupName = "OpenAI",
                ),
            ),
        )

        // Explicitly injects resolvedCatalog to bypass the resolver's metadata lookup.
        val resolved = ResolvedProviderCatalog(
            catalog = provider.catalogModels.map { ResolvedModel(model = it, isEnabled = false, isManual = false) },
            enabledModels = emptyList(),
            recommendedModels = emptyList(),
            defaultModel = null,
            availableModelCount = provider.catalogModels.size,
            hasManualModels = false,
        )
        val groups = buildProviderCatalogGroups(
            provider = provider,
            resolvedCatalog = resolved,
            searchQuery = " openai ",
        )

        assertEquals(1, groups.size)
        assertEquals("openai", groups.first().id)
        assertEquals(
            listOf("GPT-4.1", "GPT-4.1 Mini"),
            groups.first().models.map { it.name },
        )
    }

    /**
     * Pins "catalog construction never runs during composition".
     *
     * [buildProviderCatalogGroups]'s `resolvedCatalog` default parameter
     * falls through to `ProviderCatalogResolver.resolve(provider)` -- the
     * one remaining production call site that still does this. A single
     * pass over an OpenRouter-sized catalog is a full normalize plus a
     * cross-group regex comparison; wrapping that in `remember { }` means it
     * runs on the main thread on every composition, once per keystroke while
     * searching. This module has no compose-ui-test / Robolectric setup, so
     * this can only be pinned by asserting against the source text itself.
     */
    @Test
    fun `inline catalog builds groups off the composition thread`() {
        val source = File(
            "src/main/java/ai/oriveo/community/feature/modelpicker/InlineModelCatalog.kt",
        ).readText()
            .lineSequence()
            .filterNot {
                val trimmed = it.trimStart()
                trimmed.startsWith("//") || trimmed.startsWith("*") || trimmed.startsWith("/*")
            }
            .joinToString("\n")

        assertFalse(
            "catalog construction must not go back inside remember { } -- that runs on the composition-time main thread",
            source.contains("remember(provider.kind, provider.models, searchText)"),
        )
        assertTrue(
            "catalog construction must be moved onto Dispatchers.Default",
            source.contains("withContext(Dispatchers.Default)"),
        )
        assertTrue(
            "the one construction call must come after Dispatchers.Default",
            source.indexOf("buildProviderCatalogGroups(provider") >
                source.indexOf("withContext(Dispatchers.Default)"),
        )
        assertEquals(
            "catalog construction may only have one call site -- don't open a second composition-time path",
            1,
            Regex("buildProviderCatalogGroups\\(provider").findAll(source).count(),
        )
        assertTrue(
            "search must be debounced, otherwise every keystroke recomputes the whole catalog",
            source.contains("delay(InlineCatalogSearchDebounceMillis)"),
        )
    }

    private fun model(
        id: String,
        name: String,
        groupKey: String,
        groupName: String,
    ) = AIModel(
        id = id,
        name = name,
        groupKey = groupKey,
        groupName = groupName,
        isAvailable = true,
    )
}
