package ai.oriveo.community.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class ActiveModelResolverTest {

    @Test
    fun `resolveActiveModel prefers last used model when available`() {
        val modelA = AIModel(id = "gpt-4o", name = "GPT-4o", isDefault = true)
        val modelB = AIModel(id = "gpt-4o-mini", name = "GPT-4o mini")
        val provider = makeProvider(
            id = "openai",
            models = listOf(modelA, modelB),
        )

        val resolved = resolveActiveModel(
            providers = listOf(provider),
            lastUsedModelRef = LastUsedModelRef(
                providerID = "openai",
                modelID = "gpt-4o-mini",
            ),
        )

        assertEquals("openai", resolved?.provider?.id)
        assertEquals("gpt-4o-mini", resolved?.model?.id)
    }

    @Test
    fun `resolveActiveModel falls back to connected provider default model`() {
        val disconnected = makeProvider(
            id = "anthropic",
            status = ProviderConnectionState.Issue("API key required"),
            models = listOf(AIModel(id = "claude", name = "Claude", isDefault = true)),
        )
        val connected = makeProvider(
            id = "openrouter",
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "gemini", name = "Gemini", isDefault = true)),
        )

        val resolved = resolveActiveModel(
            providers = listOf(disconnected, connected),
            lastUsedModelRef = LastUsedModelRef(providerID = "missing", modelID = "missing"),
        )

        assertEquals("openrouter", resolved?.provider?.id)
        assertEquals("gemini", resolved?.model?.id)
    }

    @Test
    fun `resolveLastUsedModelRef preserves explicit selection while provider catalog is unresolved`() {
        val provider = makeProvider(
            id = "fireworks",
            models = listOf(AIModel(id = "deepseek", name = "DeepSeek", isDefault = true)),
        )

        val resolved = resolveLastUsedModelRef(
            providers = listOf(provider),
            lastUsedModelRef = LastUsedModelRef(providerID = "missing", modelID = "missing"),
        )

        assertEquals(LastUsedModelRef(providerID = "missing", modelID = "missing"), resolved)
    }

    @Test
    fun `resolveActiveModelProviderIssue returns null when no providers exist`() {
        assertNull(
            resolveActiveModelProviderIssue(
                providers = emptyList(),
                lastUsedModelRef = null,
            ),
        )
    }

    @Test
    fun `resolveProviderIssue returns null when no providers`() {
        assertNull(resolveProviderIssue(emptyList(), null))
    }

    @Test
    fun `resolveProviderIssue returns null when activeModel resolved and provider is connected`() {
        val provider = makeProvider(
            id = "openai",
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "gpt-4o", name = "GPT-4o", isDefault = true)),
        )
        assertNull(
            resolveProviderIssue(
                listOf(provider),
                LastUsedModelRef(providerID = "openai", modelID = "gpt-4o"),
            ),
        )
    }

    @Test
    fun `resolveProviderIssue returns issue when activeModel resolved and provider has issue`() {
        val provider = makeProvider(
            id = "openai",
            status = ProviderConnectionState.Issue("Invalid API Key"),
            models = listOf(AIModel(id = "gpt-4o", name = "GPT-4o", isDefault = true)),
        )
        val result = resolveProviderIssue(
            listOf(provider),
            LastUsedModelRef(providerID = "openai", modelID = "gpt-4o"),
        )
        assertNotNull(result)
        assertEquals("openai", result!!.providerID)
        assertEquals("Invalid API Key", result.message)
    }

    @Test
    fun `resolveProviderIssue fallback to lastUsedModelRef when activeModel unresolvable`() {

        val provider = makeProvider(
            id = "openrouter",
            status = ProviderConnectionState.Issue("API Key required"),
            models = emptyList(),
        )
        val result = resolveProviderIssue(
            listOf(provider),
            LastUsedModelRef(providerID = "openrouter", modelID = "gpt-4o"),
        )
        assertNotNull(result)
        assertEquals("openrouter", result!!.providerID)
        assertEquals("API Key required", result.message)
    }

    @Test
    fun `resolveProviderIssue returns null when lastUsedRef provider is connected but has no models`() {
        val provider = makeProvider(
            id = "openai",
            status = ProviderConnectionState.Connected,
            models = emptyList(),
        )
        assertNull(
            resolveProviderIssue(
                listOf(provider),
                LastUsedModelRef(providerID = "openai", modelID = "gpt-4o"),
            ),
        )
    }

    @Test
    fun `resolveProviderIssue fallback to first issue provider when lastUsedRef is null`() {
        val provider = makeProvider(
            id = "openrouter",
            status = ProviderConnectionState.Issue("API Key required"),
            models = emptyList(),
        )
        val result = resolveProviderIssue(listOf(provider), null)
        assertNotNull(result)
        assertEquals("openrouter", result!!.providerID)
        assertEquals("API Key required", result.message)
    }

    @Test
    fun `resolveProviderIssue ignores unrelated issue providers and uses lastUsedRef`() {

        val gemini = makeProvider(
            id = "gemini",
            status = ProviderConnectionState.Issue("API Key required"),
            models = emptyList(),
        )
        val openrouter = makeProvider(
            id = "openrouter",
            status = ProviderConnectionState.Issue("API Key required"),
            models = emptyList(),
        )
        val result = resolveProviderIssue(
            listOf(gemini, openrouter),
            LastUsedModelRef(providerID = "openrouter", modelID = "gpt-4o"),
        )
        assertNotNull(result)
        assertEquals("openrouter", result!!.providerID)
    }

    private fun makeProvider(
        id: String,
        status: ProviderConnectionState = ProviderConnectionState.Connected,
        models: List<AIModel>,
    ) = Provider(
        id = id,
        kind = ProviderKind.OpenAI,
        status = status,
        models = models,
        catalogModels = models,
        apiKey = "sk-test",
        apiKeyPreview = "sk-...test",
    )
}
