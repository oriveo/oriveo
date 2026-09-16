package ai.oriveo.community.core.model

import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

class ProviderLogoResolverTest {
    @Before
    fun resetCache() = resetRelayLogoCache()

    @Test
    fun `relay logo resolves from provider name base url and model hints`() {
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

        assertEquals(ProviderKind.Moonshot, resolveProviderLogoKind(provider))
    }

    @Test
    fun `relay logo falls back to relay kind when hints are unknown`() {
        val provider = Provider(
            id = "relay-anthropic",
            kind = ProviderKind.Relay,
            customName = "Work Relay",
            relayKind = RelayKind.AnthropicCompatible,
        )

        assertEquals(ProviderKind.Anthropic, resolveProviderLogoKind(provider))
    }

    // ── In-process cache ────────────────────────────────────────────────────
    //
    // The observation surface is the scan counter the production code reports itself
    // (`relayLogoScanCount` only increments on a cache miss), not an event the test synthesised.
    // Assertions use the **delta**, so other tests in the same JVM fork calling the resolver cannot
    // interfere.

    private fun relayProvider(id: String, name: String, models: List<AIModel>) = Provider(
        id = id,
        kind = ProviderKind.Relay,
        customName = name,
        baseUrlText = "https://relay.example.com/v1",
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
