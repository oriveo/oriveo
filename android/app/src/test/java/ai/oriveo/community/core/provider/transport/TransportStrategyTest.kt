package ai.oriveo.community.core.provider.transport

import ai.oriveo.community.core.model.Citation
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for TransportStrategy: the five strategies that can parse citations, plus the
 * registry fallback logic and the citation de-duplication rules.
 */
class TransportStrategyTest {

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val registry = TransportRegistry(json)

    // Registry fallback.

    @Test
    fun `registry returns strategy for known transport kind`() {
        val strategy = registry.strategyForWireValue("openai_responses")
        assertNotNull(strategy)
        assertEquals(TransportKind.OpenAIResponses, strategy?.kind)
    }

    @Test
    fun `registry returns null for unknown transport kind`() {
        val strategy = registry.strategyForWireValue("future_kind_v99")
        assertNull(strategy)
    }

    @Test(expected = UnsupportedTransportException::class)
    fun `requireStrategy throws on unknown kind`() {
        registry.requireStrategy("future_kind_v99")
    }

    @Test
    fun `all 12 transport kinds registered`() {
        TransportKind.entries.forEach { kind ->
            val strategy = registry.strategy(kind)
            assertEquals(kind, strategy.kind)
        }
    }

    // ── Anthropic Messages strategy ──

    @Test
    fun `anthropic strategy parses web_search_tool_result block`() {
        val chunk = """
            {
              "type": "content_block_start",
              "content_block": {
                "type": "web_search_tool_result",
                "content": [
                  { "url": "https://example.com/a", "title": "Title A", "cited_text": "snippet A" },
                  { "url": "https://example.com/b", "title": "Title B", "cited_text": "snippet B" }
                ]
              }
            }
        """.trimIndent()
        val shape = StreamShape(
            citationsBlockType = "web_search_tool_result",
            citationSnippetField = "cited_text",
        )
        val citations = AnthropicMessagesStrategy(json).parseCitations(chunk, shape)
        assertEquals(2, citations.size)
        assertEquals("https://example.com/a", citations[0].url)
        assertEquals("Title A", citations[0].title)
        assertEquals("snippet A", citations[0].snippet)
    }

    // ── Gemini Generate strategy ──

    @Test
    fun `gemini strategy parses groundingChunks with web uri title`() {
        val chunk = """
            {
              "candidates": [{
                "groundingMetadata": {
                  "groundingChunks": [
                    { "web": { "uri": "https://example.com/g", "title": "Gemini Title" } }
                  ]
                }
              }]
            }
        """.trimIndent()
        val shape = StreamShape(
            citationsArrayPath = "candidates.0.groundingMetadata.groundingChunks",
            citationUrlField = "web.uri",
            citationTitleField = "web.title",
        )
        val citations = GeminiGenerateStrategy(json).parseCitations(chunk, shape)
        assertEquals(1, citations.size)
        assertEquals("https://example.com/g", citations[0].url)
        assertEquals("Gemini Title", citations[0].title)
    }

    // ── DashScope Native strategy ──

    @Test
    fun `dashscope strategy parses search_info search_results`() {
        val chunk = """
            {
              "output": {
                "search_info": {
                  "search_results": [
                    { "url": "https://dashscope.example/a", "title": "QA", "index": 1, "icon": "https://favicon.example/a.ico" },
                    { "url": "https://dashscope.example/b", "title": "QB", "index": 2 }
                  ]
                }
              }
            }
        """.trimIndent()
        val shape = StreamShape(
            citationsArrayPath = "output.search_info.search_results",
        )
        val citations = DashScopeNativeStrategy(json).parseCitations(chunk, shape)
        assertEquals(2, citations.size)
        assertEquals(1, citations[0].index)
        assertEquals("https://favicon.example/a.ico", citations[0].faviconUrl)
    }

    // ── OpenAI Responses strategy ──

    @Test
    fun `openai responses strategy collects url_citation annotations`() {
        val chunk = """
            {
              "delta": {
                "annotations": [
                  { "type": "url_citation", "url": "https://oai.example/x", "title": "X", "start_index": 10, "end_index": 30 }
                ]
              }
            }
        """.trimIndent()
        val citations = OpenAIResponsesStrategy(json).parseCitations(chunk, shape = null)
        assertEquals(1, citations.size)
        assertEquals("https://oai.example/x", citations[0].url)
        assertEquals(10, citations[0].startIndex)
        assertEquals(30, citations[0].endIndex)
    }

    // ── OpenAI Chat strategy ──

    @Test
    fun `openai chat strategy parses delta annotations url_citation`() {
        val chunk = """
            {
              "choices": [{
                "delta": {
                  "annotations": [
                    { "type": "url_citation", "url_citation": { "url": "https://chat.example/a", "title": "Chat A" } }
                  ]
                }
              }]
            }
        """.trimIndent()
        val citations = OpenAIChatStrategy(json).parseCitations(chunk, shape = null)
        assertEquals(1, citations.size)
        assertEquals("https://chat.example/a", citations[0].url)
        assertEquals("Chat A", citations[0].title)
    }

    /**
     * The field names published for or_web and oai_web_tool **already include the nested
     * prefix** (`url_citation.url`). An earlier implementation first unwrapped `url_citation`
     * into an inner object and then looked that prefixed path up on the inner object, which
     * could only ever return null; mapNotNull then dropped every citation, so web citations
     * always came back empty here.
     */
    @Test
    fun `openai chat strategy handles nested citation field paths from metadata`() {
        val chunk = """
            {
              "choices": [{
                "delta": {
                  "annotations": [
                    { "type": "url_citation", "url_citation": {
                        "url": "https://chat.example/nested",
                        "title": "Nested Title",
                        "content": "nested snippet"
                    } }
                  ]
                }
              }]
            }
        """.trimIndent()
        val shape = StreamShape(
            citationsArrayPath = "choices.0.delta.annotations",
            citationUrlField = "url_citation.url",
            citationTitleField = "url_citation.title",
            citationSnippetField = "url_citation.content",
        )
        val citations = OpenAIChatStrategy(json).parseCitations(chunk, shape)
        assertEquals(1, citations.size)
        assertEquals("https://chat.example/nested", citations[0].url)
        assertEquals("Nested Title", citations[0].title)
        assertEquals("nested snippet", citations[0].snippet)
    }

    // De-duplication rules.

    @Test
    fun `mergeCitations deduplicates by normalized url`() {
        val existing = listOf(
            Citation(url = "https://example.com/a", title = "A"),
            Citation(url = "https://example.com/b"),
        )
        val incoming = listOf(
            Citation(url = "https://example.com/a/", title = "A (longer title)", snippet = "first snippet"),
            Citation(url = "https://example.com/c", title = "C"),
        )
        val merged = CitationParser.mergeCitations(existing, incoming)
        assertEquals(3, merged.size)
        // Duplicate urls merge, keeping the longer title and the newer snippet.
        assertEquals("A (longer title)", merged[0].title)
        assertEquals("first snippet", merged[0].snippet)
        // Order follows first arrival.
        assertEquals("https://example.com/a", merged[0].url)
        assertEquals("https://example.com/b", merged[1].url)
        assertEquals("https://example.com/c", merged[2].url)
    }

    @Test
    fun `mergeCitations preserves single citation when no duplicate`() {
        val merged = CitationParser.mergeCitations(
            emptyList(),
            listOf(Citation(url = "https://only.example/x")),
        )
        assertEquals(1, merged.size)
    }

    // Tolerant decoding of an unknown transport kind.

    @Test
    fun `TransportKind fromWireValue returns null for unknown`() {
        assertNull(TransportKind.fromWireValue("future_kind_v99"))
        assertNull(TransportKind.fromWireValue(null))
        assertNull(TransportKind.fromWireValue(""))
    }

    @Test
    fun `TransportKind fromWireValue parses all 12 known kinds`() {
        val knownKinds = listOf(
            "openai_chat", "openai_responses", "anthropic_messages", "gemini_generate",
            "dashscope_native", "openai_images", "gemini_image", "qwen_image",
            "grok_image", "zhipu_image", "anthropic_files", "openai_files",
        )
        knownKinds.forEach { wire ->
            assertNotNull("kind $wire should parse", TransportKind.fromWireValue(wire))
        }
    }

    // URL normalisation.

    @Test
    fun `normalizeUrl strips trailing slash and lowercases scheme host`() {
        assertEquals(
            "https://example.com/path",
            CitationParser.normalizeUrl("HTTPS://Example.com/path/"),
        )
        assertEquals(
            "https://example.com/path?q=1",
            CitationParser.normalizeUrl("https://example.com/path?q=1"),
        )
    }
}

/**
 * The three-level priority order in EndpointResolver.
 */
class EndpointResolverTest {

    private fun buildProvider(
        kind: ai.oriveo.community.core.model.ProviderKind,
        baseUrl: String? = null,
    ) = ai.oriveo.community.core.model.Provider(
        id = "test-id",
        kind = kind,
        baseUrlText = baseUrl,
    )

    @Test
    fun `user baseUrl override beats metadata and fallback`() {
        val provider = buildProvider(
            ai.oriveo.community.core.model.ProviderKind.OpenAI,
            baseUrl = "https://my-proxy.example",
        )
        val metadata = ProviderTransportDefinition(
            baseUrl = "https://api.openai.com",
            endpoints = TransportEndpoints(chat = "/v1/chat/completions"),
        )
        val url = EndpointResolver.resolveEndpoint(
            provider,
            EndpointResolver.EndpointKind.CHAT,
            metadata,
        )
        assertTrue("expected to start with user baseUrl: $url", url.startsWith("https://my-proxy.example"))
        assertTrue("expected to include path: $url", url.contains("/v1/chat/completions"))
    }

    @Test
    fun `metadata fills baseUrl when user not set`() {
        val provider = buildProvider(ai.oriveo.community.core.model.ProviderKind.Anthropic)
        val metadata = ProviderTransportDefinition(
            baseUrl = "https://metadata.api.anthropic.com",
            endpoints = TransportEndpoints(chat = "/v1/messages"),
        )
        val url = EndpointResolver.resolveEndpoint(
            provider,
            EndpointResolver.EndpointKind.CHAT,
            metadata,
        )
        assertEquals("https://metadata.api.anthropic.com/v1/messages", url)
    }

    @Test
    fun `fallback used when both user and metadata missing`() {
        val provider = buildProvider(ai.oriveo.community.core.model.ProviderKind.Anthropic)
        val url = EndpointResolver.resolveEndpoint(
            provider,
            EndpointResolver.EndpointKind.CHAT,
            metadata = null,
        )
        // anthropic fallback baseUrl = api.anthropic.com, chat = /v1/messages
        assertEquals("https://api.anthropic.com/v1/messages", url)
    }

    @Test
    fun `official metadata baseUrl outside allowlist falls back to built in base`() {
        val provider = buildProvider(ai.oriveo.community.core.model.ProviderKind.OpenAI)
        val metadata = ProviderTransportDefinition(
            baseUrl = "https://evil.example",
            endpoints = TransportEndpoints(chat = "/v1/chat/completions"),
        )

        val url = EndpointResolver.resolveEndpoint(
            provider,
            EndpointResolver.EndpointKind.CHAT,
            metadata,
        )

        assertEquals("https://api.openai.com/v1/chat/completions", url)
    }

    @Test
    fun `SiliconFlow international metadata baseUrl is allowlisted`() {
        val provider = buildProvider(ai.oriveo.community.core.model.ProviderKind.SiliconFlow)
        val metadata = ProviderTransportDefinition(
            baseUrl = "https://api.siliconflow.com",
            endpoints = TransportEndpoints(chat = "/v1/chat/completions"),
        )

        val url = EndpointResolver.resolveEndpoint(
            provider,
            EndpointResolver.EndpointKind.CHAT,
            metadata,
        )

        assertEquals("https://api.siliconflow.com/v1/chat/completions", url)
    }

    @Test
    fun `user baseUrl is not constrained by official metadata allowlist`() {
        val provider = buildProvider(
            ai.oriveo.community.core.model.ProviderKind.OpenAI,
            baseUrl = "https://my-proxy.example",
        )
        val metadata = ProviderTransportDefinition(
            baseUrl = "https://evil.example",
            endpoints = TransportEndpoints(chat = "/v1/chat/completions"),
        )

        val url = EndpointResolver.resolveEndpoint(
            provider,
            EndpointResolver.EndpointKind.CHAT,
            metadata,
        )

        assertEquals("https://my-proxy.example/v1/chat/completions", url)
    }

    // De-duplicating the version segment between base and endpoint path; a guard against the
    // 404 the library's agentic leg used to hit.

    private fun chatUrl(
        kind: ai.oriveo.community.core.model.ProviderKind,
        userBase: String?,
        metaBase: String?,
        metaPath: String?,
    ): String = EndpointResolver.resolveEndpoint(
        buildProvider(kind, userBase),
        EndpointResolver.EndpointKind.CHAT,
        metaBase?.let {
            ProviderTransportDefinition(
                baseUrl = it,
                endpoints = TransportEndpoints(chat = metaPath),
            )
        },
    )

    @Test
    fun `deepseek user baseUrl with version segment does not duplicate metadata version path`() {
        // Exact reproduction: baseUrlText holds defaultBaseUrl (api.deepseek.com/v1) while the
        // metadata chat path is the full versioned path, so a naive join yields
        // /v1/v1/chat/completions, which the upstream answers with a 404 and an empty body.
        assertEquals(
            "https://api.deepseek.com/v1/chat/completions",
            chatUrl(
                ai.oriveo.community.core.model.ProviderKind.DeepSeek,
                userBase = "https://api.deepseek.com/v1",
                metaBase = "https://api.deepseek.com",
                metaPath = "/v1/chat/completions",
            ),
        )
    }

    @Test
    fun `openAI user baseUrl with version segment does not duplicate metadata version path`() {
        assertEquals(
            "https://api.openai.com/v1/chat/completions",
            chatUrl(
                ai.oriveo.community.core.model.ProviderKind.OpenAI,
                userBase = "https://api.openai.com/v1",
                metaBase = "https://api.openai.com",
                metaPath = "/v1/chat/completions",
            ),
        )
    }

    @Test
    fun `groq two segment prefix in user baseUrl is not duplicated`() {
        assertEquals(
            "https://api.groq.com/openai/v1/chat/completions",
            chatUrl(
                ai.oriveo.community.core.model.ProviderKind.Groq,
                userBase = "https://api.groq.com/openai/v1",
                metaBase = "https://api.groq.com",
                metaPath = "/openai/v1/chat/completions",
            ),
        )
    }

    @Test
    fun `zhipu multi segment version prefix is not duplicated`() {
        assertEquals(
            "https://open.bigmodel.cn/api/paas/v4/chat/completions",
            chatUrl(
                ai.oriveo.community.core.model.ProviderKind.Zhipu,
                userBase = "https://open.bigmodel.cn/api/paas/v4",
                metaBase = "https://open.bigmodel.cn",
                metaPath = "/api/paas/v4/chat/completions",
            ),
        )
    }

    @Test
    fun `qwen compatible mode baseUrl switches to native dashscope endpoint`() {
        // Qwen is a special case: the images and native paths do not overlap the compatible-mode
        // prefix on the base, so the generic overlap rule cannot see it and the prefix has to be
        // stripped explicitly.
        assertEquals(
            "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/text-generation/generation",
            chatUrl(
                ai.oriveo.community.core.model.ProviderKind.Qwen,
                userBase = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
                metaBase = "https://dashscope-intl.aliyuncs.com",
                metaPath = "/api/v1/services/aigc/text-generation/generation",
            ),
        )
    }

    @Test
    fun `qwen compatible mode baseUrl keeps single compatible prefix for compatible endpoint`() {
        assertEquals(
            "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
            chatUrl(
                ai.oriveo.community.core.model.ProviderKind.Qwen,
                userBase = "https://dashscope.aliyuncs.com/compatible-mode/v1",
                metaBase = "https://dashscope.aliyuncs.com",
                metaPath = "/compatible-mode/v1/chat/completions",
            ),
        )
    }

    @Test
    fun `bare origin user baseUrl is untouched`() {
        assertEquals(
            "https://api.deepseek.com/v1/chat/completions",
            chatUrl(
                ai.oriveo.community.core.model.ProviderKind.DeepSeek,
                userBase = "https://api.deepseek.com",
                metaBase = "https://api.deepseek.com",
                metaPath = "/v1/chat/completions",
            ),
        )
    }

    @Test
    fun `non overlapping base path is preserved`() {
        // A self-hosted gateway prefix does not overlap the endpoint path, so the base has to be
        // kept verbatim.
        assertEquals(
            "https://proxy.example/gateway/v1/chat/completions",
            chatUrl(
                ai.oriveo.community.core.model.ProviderKind.DeepSeek,
                userBase = "https://proxy.example/gateway",
                metaBase = "https://api.deepseek.com",
                metaPath = "/v1/chat/completions",
            ),
        )
    }

    // The built-in fallback table: the safety net for when metadata is missing entirely.
    // These values come from the **real upstream endpoints**. An earlier fallback table was a
    // second copy transcribed out of the individual services, and the transcription dropped
    // the path prefix for four of them (openRouter missing /api, groq missing /openai,
    // fireworks missing /inference, zhipu missing /api/paas) while qwen pointed at the retired
    // native DashScope path. Anything that fell through to that table got a 404 or an empty
    // response. Base and path are now both derived from the single ProviderKind.defaultBaseUrl
    // table, so one edit keeps both halves correct.

    private fun fallbackChatUrl(kind: ai.oriveo.community.core.model.ProviderKind): String =
        EndpointResolver.resolveEndpoint(
            buildProvider(kind, baseUrl = null),
            EndpointResolver.EndpointKind.CHAT,
            metadata = null,
        )

    @Test
    fun `fallback chat endpoints match the real upstream URLs`() {
        assertEquals("https://api.openai.com/v1/chat/completions", fallbackChatUrl(ai.oriveo.community.core.model.ProviderKind.OpenAI))
        assertEquals("https://api.anthropic.com/v1/messages", fallbackChatUrl(ai.oriveo.community.core.model.ProviderKind.Anthropic))
        assertEquals("https://api.deepseek.com/v1/chat/completions", fallbackChatUrl(ai.oriveo.community.core.model.ProviderKind.DeepSeek))
        assertEquals("https://api.x.ai/v1/chat/completions", fallbackChatUrl(ai.oriveo.community.core.model.ProviderKind.Grok))
        assertEquals("https://api.together.xyz/v1/chat/completions", fallbackChatUrl(ai.oriveo.community.core.model.ProviderKind.Together))
        assertEquals("https://api.minimax.io/v1/chat/completions", fallbackChatUrl(ai.oriveo.community.core.model.ProviderKind.MiniMax))
        assertEquals("https://api.moonshot.ai/v1/chat/completions", fallbackChatUrl(ai.oriveo.community.core.model.ProviderKind.Moonshot))
        assertEquals("https://api.mistral.ai/v1/chat/completions", fallbackChatUrl(ai.oriveo.community.core.model.ProviderKind.Mistral))
        assertEquals("https://api.siliconflow.cn/v1/chat/completions", fallbackChatUrl(ai.oriveo.community.core.model.ProviderKind.SiliconFlow))

        // The four providers that carry a path prefix, all of which used to 404.
        assertEquals("https://openrouter.ai/api/v1/chat/completions", fallbackChatUrl(ai.oriveo.community.core.model.ProviderKind.OpenRouter))
        assertEquals("https://api.groq.com/openai/v1/chat/completions", fallbackChatUrl(ai.oriveo.community.core.model.ProviderKind.Groq))
        assertEquals("https://api.fireworks.ai/inference/v1/chat/completions", fallbackChatUrl(ai.oriveo.community.core.model.ProviderKind.Fireworks))
        assertEquals("https://open.bigmodel.cn/api/paas/v4/chat/completions", fallbackChatUrl(ai.oriveo.community.core.model.ProviderKind.Zhipu))

        // Qwen: chat has to go through the OpenAI-compatible endpoint. The native text-generation
        // path answers qwen3.x with an in-stream error.
        assertEquals(
            "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions",
            fallbackChatUrl(ai.oriveo.community.core.model.ProviderKind.Qwen),
        )
        // Images still go to the native DashScope multimodal endpoint, decoupled from chat.
        assertEquals(
            "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation",
            EndpointResolver.resolveEndpoint(
                buildProvider(ai.oriveo.community.core.model.ProviderKind.Qwen, baseUrl = null),
                EndpointResolver.EndpointKind.IMAGES,
                metadata = null,
            ),
        )
        // MiniMax image generation has its own endpoint. The OpenAI-shaped
        // /v1/images/generations does not exist on MiniMax, so falling into the generic bucket
        // would always 404.
        assertEquals(
            "https://api.minimax.io/v1/image_generation",
            EndpointResolver.resolveEndpoint(
                buildProvider(ai.oriveo.community.core.model.ProviderKind.MiniMax, baseUrl = null),
                EndpointResolver.EndpointKind.IMAGES,
                metadata = null,
            ),
        )
    }

    /**
     * The fallback base and the fallback path share a source: they are the origin half and the
     * path half of ProviderKind.defaultBaseUrl. That way the join is still correct when the
     * user's baseUrl happens to be exactly defaultBaseUrl, which is the common shape for an
     * official provider because that is what auto-fill writes, and metadata may well be missing
     * its endpoints.
     */
    @Test
    fun `default baseUrl plus fallback path never duplicates the version prefix`() {
        fun url(kind: ai.oriveo.community.core.model.ProviderKind) = EndpointResolver.resolveEndpoint(
            buildProvider(kind, baseUrl = kind.defaultBaseUrl),
            EndpointResolver.EndpointKind.CHAT,
            metadata = null,
        )

        assertEquals("https://openrouter.ai/api/v1/chat/completions", url(ai.oriveo.community.core.model.ProviderKind.OpenRouter))
        assertEquals("https://api.groq.com/openai/v1/chat/completions", url(ai.oriveo.community.core.model.ProviderKind.Groq))
        assertEquals("https://api.fireworks.ai/inference/v1/chat/completions", url(ai.oriveo.community.core.model.ProviderKind.Fireworks))
        assertEquals("https://open.bigmodel.cn/api/paas/v4/chat/completions", url(ai.oriveo.community.core.model.ProviderKind.Zhipu))
        assertEquals("https://api.openai.com/v1/chat/completions", url(ai.oriveo.community.core.model.ProviderKind.OpenAI))
        assertEquals("https://api.deepseek.com/v1/chat/completions", url(ai.oriveo.community.core.model.ProviderKind.DeepSeek))
    }

    /** A relay's fallback path has to stay at `/v1/...`: a user's own endpoint has no official
     *  prefix to speak of. */
    @Test
    fun `relay keeps the plain v1 fallback path`() {
        assertEquals(
            "https://relay.example/v1/chat/completions",
            EndpointResolver.resolveEndpoint(
                buildProvider(ai.oriveo.community.core.model.ProviderKind.Relay, "https://relay.example"),
                EndpointResolver.EndpointKind.CHAT,
                metadata = null,
            ),
        )
        // When the user types the base only as far as /v1, the segment still appears once.
        assertEquals(
            "https://relay.example/v1/chat/completions",
            EndpointResolver.resolveEndpoint(
                buildProvider(ai.oriveo.community.core.model.ProviderKind.Relay, "https://relay.example/v1"),
                EndpointResolver.EndpointKind.CHAT,
                metadata = null,
            ),
        )
    }

    @Test
    fun `user baseUrl without scheme still dedupes version segment`() {
        // The common shape of Provider.baseUrlText is defaultBaseUrl without a scheme.
        assertEquals(
            "https://api.deepseek.com/v1/chat/completions",
            chatUrl(
                ai.oriveo.community.core.model.ProviderKind.DeepSeek,
                userBase = "api.deepseek.com/v1",
                metaBase = "https://api.deepseek.com",
                metaPath = "/v1/chat/completions",
            ),
        )
    }

    @Test
    fun `user baseUrl trailing slash still dedupes version segment`() {
        assertEquals(
            "https://api.deepseek.com/v1/chat/completions",
            chatUrl(
                ai.oriveo.community.core.model.ProviderKind.DeepSeek,
                userBase = "https://api.deepseek.com/v1/",
                metaBase = "https://api.deepseek.com",
                metaPath = "/v1/chat/completions",
            ),
        )
    }

    @Test
    fun `metadata baseUrl with version segment also dedupes`() {
        // Normalisation treats userBase, metadataBase and fallbackBase alike.
        assertEquals(
            "https://api.deepseek.com/v1/chat/completions",
            chatUrl(
                ai.oriveo.community.core.model.ProviderKind.DeepSeek,
                userBase = null,
                metaBase = "https://api.deepseek.com/v1",
                metaPath = "/v1/chat/completions",
            ),
        )
    }

    @Test
    fun `fallback shape without metadata keeps legacy behaviour`() {
        // The built-in fallback is an origin plus a versioned path; normalisation must not touch it.
        assertEquals(
            "https://api.deepseek.com/v1/chat/completions",
            chatUrl(
                ai.oriveo.community.core.model.ProviderKind.DeepSeek,
                userBase = null,
                metaBase = null,
                metaPath = null,
            ),
        )
        assertEquals(
            "https://generativelanguage.googleapis.com/v1beta",
            chatUrl(
                ai.oriveo.community.core.model.ProviderKind.Gemini,
                userBase = null,
                metaBase = null,
                metaPath = null,
            ),
        )
    }

    @Test
    fun `endpoint path with query is compared by pathname only`() {
        assertEquals(
            "https://generativelanguage.googleapis.com/v1beta/models?alt=sse",
            chatUrl(
                ai.oriveo.community.core.model.ProviderKind.Gemini,
                userBase = "https://generativelanguage.googleapis.com/v1beta",
                metaBase = "https://generativelanguage.googleapis.com",
                metaPath = "/v1beta/models?alt=sse",
            ),
        )
    }
}

/**
 * Unit tests for profile mergeParams injection and deepMerge.
 */
class ProfileMergeParamsTest {

    private val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }

    @org.junit.Test
    fun `known profile mergeParams gets deepMerged into base body`() {
        val baseJson = json.parseToJsonElement(
            """{"model":"claude-3","messages":[]}"""
        ) as kotlinx.serialization.json.JsonObject
        val merge = json.parseToJsonElement(
            """{"tools":[{"type":"web_search_20250305","name":"web_search","max_uses":5}]}"""
        ) as kotlinx.serialization.json.JsonObject

        val out = applyProfileMergeParams(
            baseBody = baseJson,
            profileName = "ant_web_tool",
            mergeParams = merge,
        )
        val outStr = out.toString()
        org.junit.Assert.assertTrue("body should contain tools array, got: $outStr",
            outStr.contains("\"tools\":["))
        org.junit.Assert.assertTrue("body should contain web_search_20250305, got: $outStr",
            outStr.contains("web_search_20250305"))
    }

    @org.junit.Test
    fun `profile with mergeParams is injected even when profile name is new to client`() {
        val baseJson = json.parseToJsonElement(
            """{"model":"x","messages":[]}"""
        ) as kotlinx.serialization.json.JsonObject
        val merge = json.parseToJsonElement(
            """{"tools":[{"type":"future_web"}]}"""
        ) as kotlinx.serialization.json.JsonObject

        val out = applyProfileMergeParams(
            baseBody = baseJson,
            profileName = "future_unknown_profile",
            mergeParams = merge,
        )
        org.junit.Assert.assertTrue(out.toString().contains("future_web"))
    }

    @org.junit.Test
    fun `deepMerge merges nested objects key by key`() {
        val base = json.parseToJsonElement(
            """{"parameters":{"enable_search":false,"temperature":0.7}}"""
        ) as kotlinx.serialization.json.JsonObject
        val incoming = json.parseToJsonElement(
            """{"parameters":{"enable_search":true,"search_options":{"forced_search":false}}}"""
        ) as kotlinx.serialization.json.JsonObject

        val merged = deepMergeJsonObject(base, incoming)
        val merged_str = merged.toString()
        // enable_search is overridden by the incoming body.
        org.junit.Assert.assertTrue(merged_str.contains(""""enable_search":true"""))
        // temperature is preserved.
        org.junit.Assert.assertTrue(merged_str.contains(""""temperature":0.7"""))
        // search_options is injected.
        org.junit.Assert.assertTrue(merged_str.contains(""""search_options":{"forced_search":false}"""))
    }

    @org.junit.Test
    fun `deepMerge composes owned tools without erasing builder tools`() {
        val base = json.parseToJsonElement(
            """{"tools":[{"existing":1}]}"""
        ) as kotlinx.serialization.json.JsonObject
        val incoming = json.parseToJsonElement(
            """{"tools":[{"type":"web_search"}]}"""
        ) as kotlinx.serialization.json.JsonObject
        val merged = deepMergeJsonObject(base, incoming)
        org.junit.Assert.assertTrue(merged.toString().contains("existing"))
        org.junit.Assert.assertTrue(merged.toString().contains(""""type":"web_search""""))
    }

    @org.junit.Test
    fun `deepMerge does not duplicate anonymous tool with reordered keys`() {
        val base = json.parseToJsonElement("""{"tools":[{"type":"web_search","config":{"b":2,"a":1}}]}""") as kotlinx.serialization.json.JsonObject
        val incoming = json.parseToJsonElement("""{"tools":[{"config":{"a":1,"b":2},"type":"web_search"}]}""") as kotlinx.serialization.json.JsonObject
        org.junit.Assert.assertEquals(1, (deepMergeJsonObject(base, incoming)["tools"] as kotlinx.serialization.json.JsonArray).size)
    }

    @org.junit.Test
    fun `parseJsonObjectOrNull returns object for valid json`() {
        val obj = parseJsonObjectOrNull("""{"a":1,"b":"x"}""")
        org.junit.Assert.assertNotNull(obj)
        org.junit.Assert.assertEquals("1", obj?.get("a")?.toString())
    }

    @org.junit.Test
    fun `parseJsonObjectOrNull returns null for malformed json`() {
        org.junit.Assert.assertNull(parseJsonObjectOrNull(""))
        org.junit.Assert.assertNull(parseJsonObjectOrNull("not json"))
        // An array is not a JsonObject.
        org.junit.Assert.assertNull(parseJsonObjectOrNull("""[1,2,3]"""))
    }
}
