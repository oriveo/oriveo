package ai.oriveo.community.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderKindTest {

    // ── displayName ──────────────────────────────────────────────

    @Test
    fun `displayName returns correct values for all providers`() {
        assertEquals("OpenAI", ProviderKind.OpenAI.displayName)
        assertEquals("Anthropic", ProviderKind.Anthropic.displayName)
        assertEquals("Gemini", ProviderKind.Gemini.displayName)
        assertEquals("Grok", ProviderKind.Grok.displayName)
        assertEquals("OpenRouter", ProviderKind.OpenRouter.displayName)
        assertEquals("Groq", ProviderKind.Groq.displayName)
        assertEquals("Together AI", ProviderKind.Together.displayName)
        assertEquals("Fireworks AI", ProviderKind.Fireworks.displayName)
        assertEquals("MiniMax", ProviderKind.MiniMax.displayName)
        assertEquals("Z.ai", ProviderKind.Zhipu.displayName)
        assertEquals("Qwen", ProviderKind.Qwen.displayName)
        assertEquals("Mistral", ProviderKind.Mistral.displayName)
        assertEquals("SiliconFlow", ProviderKind.SiliconFlow.displayName)
        assertEquals("Relay", ProviderKind.Relay.displayName)
    }

    @Test
    fun `displayName covers all enum values`() {
        ProviderKind.entries.forEach { kind ->
            assertTrue("displayName should not be empty for $kind", kind.displayName.isNotEmpty())
        }
    }

    // ── shortName ────────────────────────────────────────────────

    @Test
    fun `shortName returns Claude for Anthropic`() {
        assertEquals("Claude", ProviderKind.Anthropic.shortName)
    }

    @Test
    fun `shortName returns Relay for Relay`() {
        assertEquals("Relay", ProviderKind.Relay.shortName)
    }

    @Test
    fun `shortName defaults to displayName for others`() {
        assertEquals("OpenAI", ProviderKind.OpenAI.shortName)
        assertEquals("Gemini", ProviderKind.Gemini.shortName)
    }

    // ── apiKeyPlaceholder ────────────────────────────────────────

    @Test
    fun `apiKeyPlaceholder returns expected formats`() {
        assertEquals("sk-...", ProviderKind.OpenAI.apiKeyPlaceholder)
        assertEquals("sk-ant-...", ProviderKind.Anthropic.apiKeyPlaceholder)
        assertEquals("AIza...", ProviderKind.Gemini.apiKeyPlaceholder)
        assertEquals("sk-or-...", ProviderKind.OpenRouter.apiKeyPlaceholder)
        assertEquals("sk-api-...", ProviderKind.MiniMax.apiKeyPlaceholder)
        assertEquals("sk-...", ProviderKind.SiliconFlow.apiKeyPlaceholder)
        assertEquals("xai-...", ProviderKind.Grok.apiKeyPlaceholder)
    }

    @Test
    fun `inferredFromApiKey recognizes MiniMax sk-api keys`() {
        assertEquals(ProviderKind.MiniMax, ProviderKind.inferredFromApiKey("sk-api-demo"))
    }

    @Test
    fun `inferredFromApiKey recognizes Grok xai keys`() {
        assertEquals(ProviderKind.Grok, ProviderKind.inferredFromApiKey("xai-demo-key"))
        assertEquals(ProviderKind.Grok, ProviderKind.inferredFromApiKey("XAI-upper-case"))
    }

    @Test
    fun `inferredFromApiKey does not classify generic sk keys as OpenAI`() {
        assertNull(ProviderKind.inferredFromApiKey("sk-demo"))
        assertNull(ProviderKind.inferredFromApiKey("sk-live-123"))
    }

    // ── defaultBaseUrl ───────────────────────────────────────────

    @Test
    fun `defaultBaseUrl returns null for Relay`() {
        assertNull(ProviderKind.Relay.defaultBaseUrl)
    }

    @Test
    fun `defaultBaseUrl returns non-null for all persisted providers`() {
        ProviderKind.entries
            .filter { it != ProviderKind.Relay }
            .forEach { kind ->
            assertNotNull("defaultBaseUrl should not be null for $kind", kind.defaultBaseUrl)
        }
    }

    @Test
    fun `defaultBaseUrl returns the official OpenAI endpoint`() {
        assertEquals("api.openai.com/v1", ProviderKind.OpenAI.defaultBaseUrl)
    }

    @Test
    fun `defaultBaseUrl returns siliconflow official endpoint`() {
        assertEquals("api.siliconflow.cn/v1", ProviderKind.SiliconFlow.defaultBaseUrl)
    }

    @Test
    fun `defaultBaseUrl returns xai official endpoint for Grok`() {
        assertEquals("api.x.ai/v1", ProviderKind.Grok.defaultBaseUrl)
    }

    @Test
    fun `Mistral is a direct provider with official endpoint and no key prefix hint`() {
        assertEquals("api.mistral.ai/v1", ProviderKind.Mistral.defaultBaseUrl)
        // Mistral keys have no fixed prefix, so the placeholder stays empty and takes no part in key-prefix inference.
        assertEquals("", ProviderKind.Mistral.apiKeyPlaceholder)
        val support = ProviderKind.Mistral.attachmentSupport
        assertTrue("Mistral supports vision via image_url", support.image)
        assertFalse("Mistral has no Files API", support.nativeFile)
        assertTrue("Mistral relies on inline text attachments", support.textFileInline)
    }

    @Test
    fun `grok rawValue matches server key`() {
        assertEquals("grok", ProviderKind.Grok.rawValue)
        assertEquals(ProviderKind.Grok, ProviderKind.fromRawValue("grok"))
    }

    // ── rawValue golden (the canonical id segment must match across platforms) ──

    @Test
    fun `rawValue golden for all 16 kinds matches canonical id segment`() {
        // Kept aligned, character for character, with the canonical id segment used elsewhere;
        // Android's rawValue is already canonical.
        assertEquals("openAI", ProviderKind.OpenAI.rawValue)
        assertEquals("anthropic", ProviderKind.Anthropic.rawValue)
        assertEquals("gemini", ProviderKind.Gemini.rawValue)
        assertEquals("deepseek", ProviderKind.DeepSeek.rawValue)
        assertEquals("grok", ProviderKind.Grok.rawValue)
        assertEquals("openRouter", ProviderKind.OpenRouter.rawValue)
        assertEquals("groq", ProviderKind.Groq.rawValue)
        assertEquals("together", ProviderKind.Together.rawValue)
        assertEquals("fireworks", ProviderKind.Fireworks.rawValue)
        assertEquals("miniMax", ProviderKind.MiniMax.rawValue)
        assertEquals("zhipu", ProviderKind.Zhipu.rawValue)
        assertEquals("qwen", ProviderKind.Qwen.rawValue)
        assertEquals("moonshot", ProviderKind.Moonshot.rawValue)
        assertEquals("mistral", ProviderKind.Mistral.rawValue)
        assertEquals("siliconFlow", ProviderKind.SiliconFlow.rawValue)
        assertEquals("relay", ProviderKind.Relay.rawValue)
    }

    @Test
    fun `rawValue round-trips through fromRawValue for all kinds`() {
        ProviderKind.entries.forEach { kind ->
            assertEquals(kind, ProviderKind.fromRawValue(kind.rawValue))
        }
    }

    @Test
    fun `grok supports vision and text inline but no native file`() {
        val support = ProviderKind.Grok.attachmentSupport
        assertTrue("Grok supports vision", support.image)
        assertFalse("Grok has no native file API", support.nativeFile)
        assertTrue("Grok inlines text files", support.textFileInline)
    }

    @Test
    fun `MiniMax exposes global and china mainland official endpoints`() {
        val options = ProviderKind.MiniMax.regionOptions
        assertEquals(2, options.size)
        assertEquals("global", options[0].id)
        assertEquals("https://api.minimax.io/v1", options[0].baseURL)
        assertEquals("cn", options[1].id)
        assertEquals("https://api.minimaxi.com/v1", options[1].baseURL)
    }

    @Test
    fun `SiliconFlow exposes china and international official endpoints`() {
        val options = ProviderKind.SiliconFlow.regionOptions
        assertEquals(listOf("cn", "intl"), options.map { it.id })
        assertEquals("https://api.siliconflow.cn/v1", options[0].baseURL)
        assertEquals("https://api.siliconflow.com/v1", options[1].baseURL)
    }

    @Test
    fun `every provider offering regions can store the chosen endpoint`() {
        // The region picker and the base-url write path must agree: a provider that offers a choice
        // and cannot persist it accepts the tap and silently keeps the old endpoint.
        ProviderKind.entries
            .filter { it.regionOptions.isNotEmpty() }
            .forEach { kind ->
                assertTrue(
                    "$kind offers ${kind.regionOptions.size} region options but cannot store one",
                    kind.usesConfigurableBaseUrl,
                )
            }
        assertTrue(ProviderKind.SiliconFlow.usesConfigurableBaseUrl)
    }

    @Test
    fun `providers with one fixed endpoint keep it`() {
        assertTrue(ProviderKind.Relay.usesConfigurableBaseUrl)
        listOf(
            ProviderKind.OpenAI,
            ProviderKind.Anthropic,
            ProviderKind.Gemini,
            ProviderKind.Mistral,
            ProviderKind.Groq,
        ).forEach { kind ->
            assertFalse("$kind has no region options and no editable endpoint", kind.usesConfigurableBaseUrl)
        }
    }

    // ── supportsAutomaticSync ────────────────────────────────────

    @Test
    fun `supportsAutomaticSync is false for Relay and true for other providers`() {
        assertFalse(ProviderKind.Relay.supportsAutomaticSync)
        assertTrue(ProviderKind.OpenAI.supportsAutomaticSync)
        ProviderKind.entries
            .filter { it != ProviderKind.Relay }
            .forEach { kind ->
            assertTrue("$kind should support automatic sync", kind.supportsAutomaticSync)
        }
    }

    @Test
    fun `isAggregatedProvider is true for OpenAI and false for Relay`() {
        assertTrue(ProviderKind.OpenAI.isAggregatedProvider)
        assertFalse(ProviderKind.Relay.isAggregatedProvider)
    }

    @Test
    fun `OpenAI exposes its provider identity and configuration flags`() {
        assertEquals("sk-...", ProviderKind.OpenAI.apiKeyPlaceholder)
        assertEquals("api.openai.com/v1", ProviderKind.OpenAI.defaultBaseUrl)
        assertTrue(ProviderKind.OpenAI.allowsCredentialEditing)
        assertTrue(ProviderKind.OpenAI.allowsManualModelEntry)
        assertTrue(ProviderKind.OpenAI.allowsAdvancedSettings)
        assertTrue(ProviderKind.OpenAI.allowsDeletion)
        assertEquals(ProviderKind.OpenAI, ProviderKind.fromRawValue("openAI"))
    }

    // ── isThirdPartyAggregator ───────────────────────────────────

    @Test
    fun `isThirdPartyAggregator returns true for Groq, Together, Fireworks`() {
        assertTrue(ProviderKind.Groq.isThirdPartyAggregator)
        assertTrue(ProviderKind.Together.isThirdPartyAggregator)
        assertTrue(ProviderKind.Fireworks.isThirdPartyAggregator)
    }

    @Test
    fun `isThirdPartyAggregator returns false for direct providers`() {
        assertFalse(ProviderKind.OpenAI.isThirdPartyAggregator)
        assertFalse(ProviderKind.Anthropic.isThirdPartyAggregator)
        assertFalse(ProviderKind.Gemini.isThirdPartyAggregator)
        assertFalse(ProviderKind.OpenRouter.isThirdPartyAggregator)
        assertFalse(ProviderKind.SiliconFlow.isThirdPartyAggregator)
        assertFalse(ProviderKind.Relay.isThirdPartyAggregator)
    }

    // ── autoFillNote ─────────────────────────────────────────────

    @Test
    fun `autoFillNote returns null for Relay`() {
        assertNull(ProviderKind.Relay.autoFillNote)
    }

    @Test
    fun `autoFillNote returns non-null for all configurable providers`() {
        ProviderKind.entries
            .filter { it != ProviderKind.Relay }
            .forEach { kind ->
            assertNotNull("autoFillNote should not be null for $kind", kind.autoFillNote)
        }
    }

    // ── attachmentSupport ────────────────────────────────────────

    @Test
    fun `direct providers support all attachment types`() {
        listOf(ProviderKind.OpenRouter, ProviderKind.OpenAI, ProviderKind.Gemini, ProviderKind.Anthropic).forEach {
            val support = it.attachmentSupport
            assertTrue("$it should support images", support.image)
            assertTrue("$it should support native files", support.nativeFile)
            assertTrue("$it should support text inline", support.textFileInline)
        }
    }

    @Test
    fun `aggregators do not support native files`() {
        listOf(ProviderKind.Groq, ProviderKind.Together, ProviderKind.Fireworks, ProviderKind.Relay).forEach {
            val support = it.attachmentSupport
            assertTrue("$it should support images", support.image)
            assertFalse("$it should NOT support native files", support.nativeFile)
            assertTrue("$it should support text inline", support.textFileInline)
        }
    }

    @Test
    fun `siliconflow supports image and text inline like other openai-compatible providers`() {
        val support = ProviderKind.SiliconFlow.attachmentSupport
        assertTrue("SiliconFlow hosts vision models, should support image", support.image)
        assertFalse("SiliconFlow has no native file API", support.nativeFile)
        assertTrue("SiliconFlow uses OpenAI-compatible API, should support text inline", support.textFileInline)
    }

    @Test
    fun `all openai-compatible aggregators share image and textFileInline support`() {
        // SiliconFlow / Groq / Together / Fireworks all use the OpenAI-compatible protocol.
        listOf(ProviderKind.Groq, ProviderKind.Together, ProviderKind.Fireworks, ProviderKind.SiliconFlow).forEach {
            val support = it.attachmentSupport
            assertTrue("$it should support images", support.image)
            assertFalse("$it should NOT support native files", support.nativeFile)
            assertTrue("$it should support text inline", support.textFileInline)
        }
    }

    // ── openRouterVendorPrefix ───────────────────────────────────

    @Test
    fun `openRouterVendorPrefix returns correct values`() {
        assertEquals("openai", ProviderKind.OpenAI.openRouterVendorPrefix)
        assertEquals("anthropic", ProviderKind.Anthropic.openRouterVendorPrefix)
        assertEquals("google", ProviderKind.Gemini.openRouterVendorPrefix)
        assertNull(ProviderKind.OpenRouter.openRouterVendorPrefix)
        assertNull(ProviderKind.Groq.openRouterVendorPrefix)
        assertNull(ProviderKind.Relay.openRouterVendorPrefix)
    }

    // ── companion lists ──────────────────────────────────────────

    @Test
    fun `directProviders contains 10 providers and excludes OpenRouter and SiliconFlow`() {
        assertEquals(10, ProviderKind.directProviders.size)
        assertTrue(ProviderKind.directProviders.contains(ProviderKind.OpenAI))
        assertTrue(ProviderKind.directProviders.contains(ProviderKind.Anthropic))
        assertTrue(ProviderKind.directProviders.contains(ProviderKind.Gemini))
        assertTrue(ProviderKind.directProviders.contains(ProviderKind.DeepSeek))
        assertTrue(ProviderKind.directProviders.contains(ProviderKind.Grok))
        assertTrue(ProviderKind.directProviders.contains(ProviderKind.MiniMax))
        assertTrue(ProviderKind.directProviders.contains(ProviderKind.Zhipu))
        assertTrue(ProviderKind.directProviders.contains(ProviderKind.Qwen))
        assertTrue(ProviderKind.directProviders.contains(ProviderKind.Moonshot))
        assertTrue(ProviderKind.directProviders.contains(ProviderKind.Mistral))
        assertFalse(ProviderKind.directProviders.contains(ProviderKind.OpenRouter))
        assertFalse(ProviderKind.directProviders.contains(ProviderKind.SiliconFlow))
    }

    @Test
    fun `aggregators contains 5 providers with OpenRouter first and SiliconFlow included`() {
        assertEquals(5, ProviderKind.aggregators.size)
        assertEquals(ProviderKind.OpenRouter, ProviderKind.aggregators.first())
        assertTrue(ProviderKind.aggregators.contains(ProviderKind.OpenRouter))
        assertTrue(ProviderKind.aggregators.contains(ProviderKind.Groq))
        assertTrue(ProviderKind.aggregators.contains(ProviderKind.Together))
        assertTrue(ProviderKind.aggregators.contains(ProviderKind.Fireworks))
        assertTrue(ProviderKind.aggregators.contains(ProviderKind.SiliconFlow))
    }
}
