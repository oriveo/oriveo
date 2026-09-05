package ai.oriveo.community.core.data.remote

import ai.oriveo.community.core.model.ProviderKind
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlinx.serialization.KSerializer

/**
 * Android-side consumer test for the fixture shared across all three platforms.
 *
 * Reads `shared/test-fixtures/relay/metadata-fixture.json` and injects it into MetadataClient
 * via reflection, verifying that the fixture's hit samples, dated-snapshot aliases, and
 * relayRuntimeConfig fields line up with the Android fallback. Web and iOS have their own
 * equivalent tests.
 */
class MetadataFixtureTest {

    @After
    fun tearDown() {
        clearTable()
    }

    @Test
    fun `fixture covers gpt-5_4 snapshot alias and known official models`() {
        injectFixture()

        val gpt = MetadataClient.resolveCatalogModelAcrossProvidersWithProvider("gpt-5.4")
        assertNotNull(gpt)
        assertEquals(ProviderKind.OpenAI, gpt!!.matchedProviderKind)
        assertEquals("gpt-5.4", gpt.canonicalModelId)

        // dated-snapshot alias (a representative example)
        val gptDated = MetadataClient.resolveCatalogModelAcrossProvidersWithProvider("gpt-5.4-2026-04-01")
        assertNotNull(gptDated)
        assertEquals("gpt-5.4", gptDated!!.canonicalModelId)

        // a standalone image-generation model
        val gptImage = MetadataClient.resolveCatalogModelAcrossProvidersWithProvider("gpt-image-2")
        assertNotNull(gptImage)
        assertEquals(ProviderKind.OpenAI, gptImage!!.matchedProviderKind)
        assertEquals("gpt-image-2", gptImage.canonicalModelId)

        val claude = MetadataClient.resolveCatalogModelAcrossProvidersWithProvider("claude-sonnet-4.5")
        assertNotNull(claude)
        assertEquals(ProviderKind.Anthropic, claude!!.matchedProviderKind)

        val claudeDated = MetadataClient.resolveCatalogModelAcrossProvidersWithProvider("claude-sonnet-4-5-2026-04-01")
        assertNotNull(claudeDated)
        assertEquals("claude-sonnet-4.5", claudeDated!!.canonicalModelId)

        val gemini = MetadataClient.resolveCatalogModelAcrossProvidersWithProvider("gemini-2.5-pro")
        assertNotNull(gemini)
        assertEquals(ProviderKind.Gemini, gemini!!.matchedProviderKind)

        assertNull(MetadataClient.resolveCatalogModelAcrossProvidersWithProvider("my-custom-model"))
    }

    @Test
    fun `fixture generation parameter expansion is consistent - model-level enumValues overrides shared schema, absence falls back to global`() {
        injectFixture()

        // gpt-5.4 declares model-level enumValues (["low", "high"]), which must override the four
        // global values from the shared platform schema -- otherwise the advanced parameter panel
        // would show a level picker with fake levels that were deliberately narrowed away.
        val gpt = MetadataClient.resolveCatalogModel("gpt-5.4", ProviderKind.OpenAI)
        val gptEnum = gpt?.profiles?.generation?.parameters
            ?.firstOrNull { it.id == "reasoning_effort" }
            ?.enumValues?.map { it.toString().trim('"') }
        assertEquals(listOf("low", "high"), gptEnum)

        // claude-sonnet-4.5's reasoning_effort reference declares no model-level enumValues, so it
        // must fall back to the four global values from the shared platform schema (the legacy
        // wire compatibility path).
        val claude = MetadataClient.resolveCatalogModel("claude-sonnet-4.5", ProviderKind.Anthropic)
        val claudeEnum = claude?.profiles?.generation?.parameters
            ?.firstOrNull { it.id == "reasoning_effort" }
            ?.enumValues?.map { it.toString().trim('"') }
        assertEquals(listOf("low", "medium", "high", "xhigh"), claudeEnum)
    }

    @Test
    fun `fixture relayRuntimeConfig aligns with android fallback defaults`() {
        injectFixture()

        val runtime = MetadataClient.relayRuntimeConfig()
        assertEquals("2026-04-23-1", runtime.version)
        assertEquals(
            listOf("openAI", "anthropic", "gemini", "deepseek", "miniMax", "zhipu", "qwen"),
            runtime.officialProviderWhitelist,
        )

        val openaiResponses = runtime.transportEnvelopes["openai_responses"]!!
        assertTrue(openaiResponses.image)
        assertTrue(openaiResponses.nativeFile)
        assertTrue(openaiResponses.webSearch)
        assertTrue(openaiResponses.imageGeneration)
        assertEquals("openAI", runtime.transportRules["openai_responses"]?.providerPriority)
        assertEquals("bearer", runtime.transportRules["openai_responses"]?.defaultAuthMode)
        assertEquals("v1", runtime.transportRules["openai_responses"]?.defaultVersion)
        assertEquals(listOf("v1"), runtime.transportRules["openai_responses"]?.acceptedVersions)
        assertEquals(true, runtime.transportRules["openai_responses"]?.codexIdentityDefault)
        assertEquals("web_search", runtime.transportRules["openai_responses"]?.webSearchToolName)
        assertEquals("inline_responses_tool", runtime.transportRules["openai_responses"]?.imageRoute)
        assertEquals(true, runtime.transportRules["openai_responses"]?.forceStreamForImageGeneration)

        val chat = runtime.transportEnvelopes["openai_chat_completions"]!!
        assertEquals(false, chat.nativeFile)
        assertEquals(false, chat.webSearch)
        assertEquals(false, chat.imageGeneration)
        assertEquals("bearer", runtime.transportRules["openai_chat_completions"]?.defaultAuthMode)
        assertEquals("images_endpoint", runtime.transportRules["openai_chat_completions"]?.imageRoute)

        val anthropic = runtime.transportEnvelopes["anthropic_messages"]!!
        assertEquals(false, anthropic.webSearch)
        assertEquals(false, anthropic.imageGeneration)
        assertEquals("anthropic", runtime.transportRules["anthropic_messages"]?.providerPriority)
        assertEquals("x_api_key", runtime.transportRules["anthropic_messages"]?.defaultAuthMode)

        val gemini = runtime.transportEnvelopes["gemini_generate_content"]!!
        assertTrue(gemini.webSearch)
        assertTrue(gemini.imageGeneration)
        assertEquals("x_goog_api_key", runtime.transportRules["gemini_generate_content"]?.defaultAuthMode)
        assertEquals("v1beta", runtime.transportRules["gemini_generate_content"]?.defaultVersion)

        assertEquals(7, runtime.verificationPolicy.hardFailedExpiryDays)
        assertEquals(60, runtime.verificationPolicy.softFailedRetryAfterSeconds)
        assertEquals(30, runtime.verificationPolicy.verifiedCacheDays)
        assertTrue(runtime.featureGatingPolicy.showActualModelIdHint)
        assertTrue(runtime.featureGatingPolicy.showSoftFailHint)
    }

    @Test
    fun `empty officialProviderWhitelist falls back to defaults`() {
        injectJson(
            """
            {
                "version": 1,
                "contractVersion": 1,
                "providers": {},
                "relayRuntimeConfig": {
                    "version": "2026-04-23-x",
                    "officialProviderWhitelist": [],
                    "transportEnvelopes": {},
                    "verificationPolicy": {
                        "hardFailedExpiryDays": 7,
                        "softFailedRetryAfterSeconds": 60,
                        "verifiedCacheDays": 30
                    },
                    "featureGatingPolicy": {
                        "showActualModelIdHint": true,
                        "showSoftFailHint": true
                    }
                }
            }
            """.trimIndent()
        )

        val runtime = MetadataClient.relayRuntimeConfig()
        // FALLBACK_RELAY_RUNTIME_CONFIG includes openAI / anthropic / gemini / deepseek / miniMax / zhipu / qwen / moonshot
        assertEquals(8, runtime.officialProviderWhitelist.size)
        assertTrue(runtime.officialProviderWhitelist.contains("openAI"))
        assertTrue(runtime.officialProviderWhitelist.contains("anthropic"))
        assertTrue(runtime.officialProviderWhitelist.contains("moonshot"))
    }

    @Test
    fun `empty transportEnvelopes falls back to defaults for all four transports`() {
        injectJson(
            """
            {
                "version": 1,
                "contractVersion": 1,
                "providers": {},
                "relayRuntimeConfig": {
                    "version": "2026-04-23-x",
                    "officialProviderWhitelist": ["openAI"],
                    "transportEnvelopes": {},
                    "verificationPolicy": {
                        "hardFailedExpiryDays": 7,
                        "softFailedRetryAfterSeconds": 60,
                        "verifiedCacheDays": 30
                    },
                    "featureGatingPolicy": {
                        "showActualModelIdHint": true,
                        "showSoftFailHint": true
                    }
                }
            }
            """.trimIndent()
        )

        val runtime = MetadataClient.relayRuntimeConfig()
        assertEquals(true, runtime.transportEnvelopes["openai_responses"]?.webSearch)
        assertEquals(false, runtime.transportEnvelopes["openai_chat_completions"]?.webSearch)
        assertEquals(false, runtime.transportEnvelopes["anthropic_messages"]?.imageGeneration)
        assertEquals(true, runtime.transportEnvelopes["gemini_generate_content"]?.webSearch)
    }

    private fun injectFixture() {
        // The gradle test task's cwd is the app module directory.
        //   .../android/app/
        //   -> parentFile walks back up to the repo root
        val moduleDir = File(System.getProperty("user.dir") ?: ".").absoluteFile
        val repoRoot = moduleDir.parentFile!!.parentFile!!
        val fixturePath = File(repoRoot, "shared/test-fixtures/relay/metadata-fixture.json")
        require(fixturePath.exists()) { "fixture not found at: ${fixturePath.absolutePath}" }
        injectJson(fixturePath.readText(Charsets.UTF_8))
    }

    private fun injectJson(rawJson: String) {
        val clientClass = MetadataClient::class.java

        val jsonField = clientClass.getDeclaredField("json")
        jsonField.isAccessible = true
        val internalJson = jsonField.get(MetadataClient.instance) as Json

        val responseClass = clientClass.declaredClasses.first { it.simpleName == "MetadataResponse" }
        val companionField = responseClass.getDeclaredField("Companion")
        companionField.isAccessible = true
        val companion = companionField.get(null)
        val serializerMethod = companion.javaClass.getDeclaredMethod("serializer")
        serializerMethod.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val serializer = serializerMethod.invoke(companion) as KSerializer<Any>

        val decoded = internalJson.decodeFromString(serializer, rawJson)

        val tableField = clientClass.getDeclaredField("table")
        tableField.isAccessible = true
        tableField.set(MetadataClient.instance, decoded)
    }

    private fun clearTable() {
        val tableField = MetadataClient::class.java.getDeclaredField("table")
        tableField.isAccessible = true
        tableField.set(MetadataClient.instance, null)
    }
}
