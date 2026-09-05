package ai.oriveo.community.core.model

import ai.oriveo.community.core.provider.MetadataTestFixtures
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

class ProviderTest {

    @Before
    fun setUp() {
        MetadataTestFixtures.clear()
    }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    private fun model(id: String, isDefault: Boolean = false, isAvailable: Boolean = true) =
        AIModel(id = id, name = id, isDefault = isDefault, isAvailable = isAvailable)

    // ── displayName ──────────────────────────────────────────────

    @Test
    fun `displayName returns kind displayName for non-Relay`() {
        val provider = Provider(id = "1", kind = ProviderKind.OpenAI)
        assertEquals("OpenAI", provider.displayName)
    }

    @Test
    fun `displayName returns customName for non-Relay provider instances`() {
        val provider = Provider(id = "1", kind = ProviderKind.OpenRouter, customName = "OpenRouter 2")
        assertEquals("OpenRouter 2", provider.displayName)
    }

    @Test
    fun `displayName returns customName for Relay`() {
        val provider = Provider(id = "1", kind = ProviderKind.Relay, customName = "My Proxy")
        assertEquals("My Proxy", provider.displayName)
    }

    @Test
    fun `displayName returns Relay when customName is null`() {
        val provider = Provider(id = "1", kind = ProviderKind.Relay, customName = null)
        assertEquals("Relay", provider.displayName)
    }

    // ── enabledModelCount ────────────────────────────────────────

    @Test
    fun `enabledModelCount returns models size`() {
        val provider = Provider(
            id = "1", kind = ProviderKind.OpenAI,
            models = listOf(model("a"), model("b"), model("c")),
        )
        assertEquals(3, provider.enabledModelCount)
    }

    @Test
    fun `enabledModelCount returns 0 for empty models`() {
        val provider = Provider(id = "1", kind = ProviderKind.OpenAI)
        assertEquals(0, provider.enabledModelCount)
    }

    // ── allModels ────────────────────────────────────────────────

    @Test
    fun `allModels returns catalogModels when available`() {
        val catalog = listOf(model("c1"), model("c2"))
        val models = listOf(model("m1"))
        val provider = Provider(
            id = "1", kind = ProviderKind.OpenAI,
            models = models, catalogModels = catalog,
        )
        assertEquals(catalog, provider.allModels)
    }

    @Test
    fun `allModels returns models when catalogModels is empty`() {
        val models = listOf(model("m1"))
        val provider = Provider(
            id = "1", kind = ProviderKind.OpenAI,
            models = models, catalogModels = emptyList(),
        )
        assertEquals(models, provider.allModels)
    }

    // ── availableModelCount ──────────────────────────────────────

    @Test
    fun `availableModelCount counts only available models`() {
        val provider = Provider(
            id = "1", kind = ProviderKind.OpenAI,
            models = listOf(
                model("a", isAvailable = true),
                model("b", isAvailable = false),
                model("c", isAvailable = true),
            ),
        )
        assertEquals(2, provider.availableModelCount)
    }

    // ── defaultModel ─────────────────────────────────────────────

    @Test
    fun `defaultModel returns model marked as default`() {
        val provider = Provider(
            id = "1", kind = ProviderKind.OpenAI,
            models = listOf(model("a"), model("b", isDefault = true)),
        )
        assertEquals("b", provider.defaultModel?.id)
    }

    @Test
    fun `defaultModel falls back to first model when no default`() {
        val provider = Provider(
            id = "1", kind = ProviderKind.OpenAI,
            models = listOf(model("a"), model("b")),
        )
        assertEquals("a", provider.defaultModel?.id)
    }

    @Test
    fun `defaultModel falls back to catalogModels when models empty`() {
        val provider = Provider(
            id = "1", kind = ProviderKind.OpenAI,
            models = emptyList(),
            catalogModels = listOf(model("c1", isDefault = true)),
        )
        assertEquals("c1", provider.defaultModel?.id)
    }

    @Test
    fun `defaultModel returns null when everything empty`() {
        val provider = Provider(id = "1", kind = ProviderKind.OpenAI)
        assertNull(provider.defaultModel)
    }

    // ── updatedAt ────────────────────────────────────────────────

    @Test
    fun `updatedAt defaults to 0`() {
        val provider = Provider(id = "1", kind = ProviderKind.OpenAI)
        assertEquals(0L, provider.updatedAt)
    }

    @Test
    fun `updatedAt can be set`() {
        val ts = 1700000000000L
        val provider = Provider(id = "1", kind = ProviderKind.OpenAI, updatedAt = ts)
        assertEquals(ts, provider.updatedAt)
    }
}
