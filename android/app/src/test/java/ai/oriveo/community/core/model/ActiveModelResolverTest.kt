package ai.oriveo.community.core.model

import ai.oriveo.community.core.provider.MetadataTestFixtures
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
            status = ProviderConnectionState.Issue.missingCredential(ProviderAuthMode.ApiKey),
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

    // ── resolveProviderIssue scenarios ──

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

    @Test
    fun `resolveSkillModel skips a retired suggested or capability-matched model`() {
        MetadataTestFixtures.applyRaw("""{"version":1,"contractVersion":1,"providers":{"openAI":{"defaultModelId":"gpt-next","retiredModels":[{"id":"gpt-mini-old","displayName":"GPT Mini Old","retiredAt":"2026-07-24T00:00:00Z","routedTo":"gpt-next"}],"resolveMap":{},"models":{"gpt-next":{"canonicalModelId":"gpt-next","displayName":"GPT Next"}}}}}""")
        try {
            val provider = makeProvider(
                id = "openai",
                models = listOf(
                    AIModel(id = "gpt-mini-old", name = "GPT Mini Old"),
                    AIModel(id = "gpt-next", name = "GPT Next"),
                ),
            )

            val suggested = resolveSkillModel(
                Skill(id = "s1", name = "S1", systemPrompt = "", suggestedProviderId = "openai", suggestedModelId = "gpt-mini-old"),
                listOf(provider),
                lastUsedModelRef = null,
            )
            val fast = resolveSkillModel(
                Skill(id = "s2", name = "S2", systemPrompt = "", modelCapabilityHint = "fast"),
                listOf(provider),
                lastUsedModelRef = null,
            )

            assertEquals("gpt-next", suggested?.model?.id)
            assertEquals("gpt-next", fast?.model?.id)
        } finally {
            MetadataTestFixtures.clear()
        }
    }

    @Test
    fun `resolveActiveModel moves past a connection with no usable model and returns null when none is usable`() {
        MetadataTestFixtures.applyRaw("""{"version":1,"contractVersion":1,"providers":{"openAI":{"defaultModelId":"gpt-next","retiredModels":[{"id":"gpt-old","displayName":"GPT Old","retiredAt":"2026-07-24T00:00:00Z","routedTo":"gpt-next"}],"resolveMap":{},"models":{"gpt-next":{"canonicalModelId":"gpt-next","displayName":"GPT Next"}}}}}""")
        try {
            val dead = makeProvider(id = "dead", models = listOf(AIModel(id = "gpt-old", name = "GPT Old")))
            val alive = makeProvider(id = "alive", models = listOf(AIModel(id = "gpt-next", name = "GPT Next")))

            val moved = resolveActiveModel(listOf(dead, alive), lastUsedModelRef = null)

            assertEquals("alive", moved?.provider?.id)
            assertEquals("gpt-next", moved?.model?.id)
            assertNull(resolveActiveModel(listOf(dead), LastUsedModelRef("dead", "gpt-old")))
        } finally {
            MetadataTestFixtures.clear()
        }
    }

    @Test
    fun `resolveActiveModel keeps an errored connection and skips missing-credential ones`() {
        val errored = makeProvider(
            id = "errored",
            status = ProviderConnectionState.Issue("Invalid API Key"),
            models = listOf(AIModel(id = "gpt-4o", name = "GPT-4o", isDefault = true)),
        )
        val noKey = makeProvider(
            id = "no-key",
            status = ProviderConnectionState.Issue.missingCredential(ProviderAuthMode.ApiKey),
            models = listOf(AIModel(id = "claude", name = "Claude", isDefault = true)),
        )
        val signedOut = makeProvider(
            id = "signed-out",
            status = ProviderConnectionState.Issue.missingCredential(ProviderAuthMode.Subscription),
            models = listOf(AIModel(id = "grok", name = "Grok", isDefault = true)),
        )

        val errorFirst = resolveActiveModel(listOf(errored, noKey), lastUsedModelRef = null)
        val missingOnly = resolveActiveModel(listOf(noKey, signedOut), lastUsedModelRef = null)
        val skill = resolveSkillModel(
            Skill(id = "s", name = "S", systemPrompt = ""),
            listOf(noKey, signedOut, errored),
            lastUsedModelRef = null,
        )

        assertEquals("errored", errorFirst?.provider?.id)
        assertNull(missingOnly)
        assertEquals("errored", skill?.provider?.id)
        assertEquals(false, errored.isMissingCredentialForNewChat())
        assertEquals(true, noKey.isMissingCredentialForNewChat())
        assertEquals(true, signedOut.isMissingCredentialForNewChat())
        // Only the typed reason counts: an error with the same text is not a missing credential, and the text is still mapped from the reason.
        val sameTextError = makeProvider(
            id = "same-text",
            status = ProviderConnectionState.Issue("API Key required"),
            models = listOf(AIModel(id = "x", name = "X")),
        )
        assertEquals(false, sameTextError.isMissingCredentialForNewChat())
        assertEquals("API Key required", (noKey.status as ProviderConnectionState.Issue).message)
        assertEquals("Sign in required", (signedOut.status as ProviderConnectionState.Issue).message)
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
