package ai.oriveo.community.core.model

import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

class ProviderLogoResolverTest {
    @Before
    fun resetCache() = resetRelayLogoCache()

    // A relay connection no longer infers a brand from the upstream name in its name / model id / relayKind; it only takes
    // aggregator brands from the avatar table and otherwise falls back to Relay (the UI draws an initial letter or the relay icon).
    // The earlier assertions here (Moonshot / Anthropic inference) are obsolete and have been rewritten.

    @Test
    fun `relay connection no longer infers a brand from name host or model ids`() {
        val provider = Provider(
            id = "relay-kimi",
            kind = ProviderKind.Relay,
            customName = "Kimi Gateway",
            baseUrlText = "https://api.moonshot.cn/v1",
            models = listOf(
                AIModel(
                    id = "kimi-k2-0905-preview",
                    name = "Kimi K2",
                    groupKey = "moonshot",
                    groupName = "Kimi",
                ),
            ),
        )

        assertEquals(ProviderKind.Relay, resolveProviderLogoKind(provider))
    }

    @Test
    fun `relay connection no longer falls back to the relay kind protocol logo`() {
        val provider = Provider(
            id = "relay-anthropic",
            kind = ProviderKind.Relay,
            customName = "Work Relay",
            relayKind = RelayKind.AnthropicCompatible,
        )

        assertEquals(ProviderKind.Relay, resolveProviderLogoKind(provider))
    }

    @Test
    fun `relay connection takes the aggregator brand from the shared avatar resolver`() {
        val provider = Provider(
            id = "relay-openrouter",
            kind = ProviderKind.Relay,
            customName = "My backup",
            baseUrlText = "https://openrouter.ai/api/v1",
            relayKind = RelayKind.OpenAICompatible,
        )
        val before = relayLogoScanCount.get()

        assertEquals(ProviderKind.OpenRouter, resolveProviderLogoKind(provider))
        assertEquals("a relay connection no longer scans model hints", 0, relayLogoScanCount.get() - before)
    }

    // ── In-process cache ────────────────────────────────────────────────────
    //
    // The observation surface is the scan counter the production code reports itself
    // (`relayLogoScanCount` only increments on a cache miss), not an event the test synthesised.
    // Assertions use the **delta**, so other tests in the same JVM fork calling the resolver cannot
    // interfere.

    // The cache only serves local connections (local ones still infer by the original rules).
    private fun relayProvider(id: String, name: String, models: List<AIModel>) = Provider(
        id = id,
        kind = ProviderKind.Relay,
        customName = name,
        baseUrlText = "http://192.168.1.20:11434/v1",
        relayRequested = RelayRequestedConfig(engineProfile = "ollama"),
        models = models,
    )

    private val kimiModel = AIModel(id = "kimi-k2-0905-preview", name = "Kimi K2", groupKey = "moonshot", groupName = "Kimi")

    @Test
    fun `same provider instance is scanned once no matter how many call sites ask`() {
        val provider = relayProvider("relay-cache-instance", "Gateway", listOf(kimiModel))

        val before = relayLogoScanCount.get()
        repeat(8) { assertEquals(ProviderKind.Moonshot, resolveProviderLogoKind(provider)) }

        assertEquals("asking the same instance eight times should scan once", 1, relayLogoScanCount.get() - before)
    }

    @Test
    fun `a rebuilt but identical provider reuses the cached result`() {
        val first = relayProvider("relay-cache-content", "Gateway", listOf(kimiModel))
        val rebuilt = relayProvider("relay-cache-content", "Gateway", listOf(kimiModel.copy()))

        val before = relayLogoScanCount.get()
        assertEquals(ProviderKind.Moonshot, resolveProviderLogoKind(first))
        assertEquals(ProviderKind.Moonshot, resolveProviderLogoKind(rebuilt))

        // A database re-emission produces a new but identical instance; it may rebuild the hints,
        // but it must not run the substring scans again.
        assertEquals("identical content must not be rescanned", 1, relayLogoScanCount.get() - before)
    }

    @Test
    fun `changing the model list re-resolves instead of serving a stale logo`() {
        val id = "relay-cache-invalidate"
        val before = relayLogoScanCount.get()
        assertEquals(ProviderKind.Moonshot, resolveProviderLogoKind(relayProvider(id, "Gateway", listOf(kimiModel))))

        val afterSwap = resolveProviderLogoKind(
            relayProvider(id, "Gateway", listOf(AIModel(id = "claude-sonnet-4", name = "Claude Sonnet 4"))),
        )

        assertEquals("a different model list has to be resolved again", ProviderKind.Anthropic, afterSwap)
        assertEquals(2, relayLogoScanCount.get() - before)
    }

    @Test
    fun `official providers never touch the relay cache`() {
        val before = relayLogoScanCount.get()

        assertEquals(
            ProviderKind.OpenAI,
            resolveProviderLogoKind(Provider(id = "official", kind = ProviderKind.OpenAI, customName = "OpenAI")),
        )

        assertEquals(0, relayLogoScanCount.get() - before)
    }
}
