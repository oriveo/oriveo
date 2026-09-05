package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.UsageBreakdown
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RelayUsageBreakdownTest {

    @Test
    fun `openai chat usage excludes cached prompt tokens and preserves reasoning tokens`() {
        val breakdown = openAIChatUsageBreakdown(
            promptTokens = 100,
            completionTokens = 40,
            cachedInputTokens = 25,
            reasoningTokens = 7,
        )

        assertEquals(
            UsageBreakdown(
                promptTokens = 75,
                cachedInputTokens = 25,
                completionTokens = 40,
                reasoningTokens = 7,
                // cachedInputTokens came in non-null, so the cache read was observable. The
                // observation flag follows whether the field was present, not how big it is.
                cacheReadObserved = true,
            ),
            breakdown,
        )
    }

    @Test
    fun `anthropic usage preserves cache creation buckets`() {
        val breakdown = anthropicUsageBreakdown(
            inputTokens = 120,
            outputTokens = 50,
            cacheReadInputTokens = 20,
            cacheCreation5mInputTokens = 30,
            cacheCreation1hInputTokens = 40,
        )

        assertEquals(
            UsageBreakdown(
                promptTokens = 120,
                cachedInputTokens = 20,
                cacheCreation5mTokens = 30,
                cacheCreation1hTokens = 40,
                completionTokens = 50,
                reasoningTokens = 0,
                cacheReadObserved = true,
                cacheWriteObserved = true,
            ),
            breakdown,
        )
    }

    @Test
    fun `gemini usage counts thoughts as completion and reasoning`() {
        val breakdown = geminiUsageBreakdown(
            promptTokenCount = 100,
            candidatesTokenCount = 25,
            thoughtsTokenCount = 15,
            cachedContentTokenCount = 30,
        )

        assertEquals(
            UsageBreakdown(
                promptTokens = 70,
                cachedInputTokens = 30,
                completionTokens = 40,
                reasoningTokens = 15,
                cacheReadObserved = true,
            ),
            breakdown,
        )
    }

    @Test
    fun `relay transport priority maps to official provider family`() {
        assertEquals("openAI", relayCostPriorityBackendKey(RelayTransport.OpenAIResponses))
        assertEquals("anthropic", relayCostPriorityBackendKey(RelayTransport.AnthropicMessages))
        assertEquals("gemini", relayCostPriorityBackendKey(RelayTransport.GeminiGenerateContent))
    }

    @Test
    fun `relay body builders live outside relay service god class`() {
        val bodyBuilders = java.io.File("src/main/java/ai/oriveo/community/core/provider/relay/RelayBodyBuilders.kt").readText()
        val relayService = java.io.File("src/main/java/ai/oriveo/community/core/provider/RelayService.kt").readText()

        listOf(
            "buildResponsesBody",
            "buildOpenAIChatBody",
            "buildAnthropicBody",
            "buildGeminiBody",
        ).forEach { builder ->
            assertEquals(1, bodyBuilders.countOccurrences("internal fun $builder("))
            assertEquals(0, relayService.countOccurrences("private fun $builder("))
        }
    }

    @Test
    fun `relay header builder owns header and auth helpers`() {
        val headerBuilder = java.io.File("src/main/java/ai/oriveo/community/core/provider/relay/RelayHeaderBuilder.kt").readText()
        val relayService = java.io.File("src/main/java/ai/oriveo/community/core/provider/RelayService.kt").readText()

        listOf(
            "applyRelayHeaders",
            "codexIdentityHeaders",
            "resolveAuthMode",
            "relayAuthModeFromRuntime",
        ).forEach { helper ->
            assertTrue(headerBuilder.contains(helper))
            assertEquals(0, relayService.countOccurrences("private fun $helper("))
        }
    }

    @Test
    fun `relay service delegates transport details to coordinator`() {
        val relayService = java.io.File("src/main/java/ai/oriveo/community/core/provider/RelayService.kt").readText()
        val coordinator = java.io.File("src/main/java/ai/oriveo/community/core/provider/relay/RelayTransportCoordinator.kt").readText()

        assertTrue(relayService.contains("RelayTransportCoordinator("))
        assertTrue(coordinator.contains("sendOpenAIChat("))
        assertTrue(coordinator.contains("streamResponses("))
        assertTrue(coordinator.contains("sendAnthropic("))
        assertTrue(coordinator.contains("streamGemini("))
        assertTrue(relayService.lineSequence().count() <= 800)
    }

    @Test
    fun `relay coordinator delegates each protocol to transport classes`() {
        val coordinator = java.io.File("src/main/java/ai/oriveo/community/core/provider/relay/RelayTransportCoordinator.kt").readText()

        listOf(
            "RelayOpenAIResponsesTransport",
            "RelayOpenAIChatTransport",
            "RelayAnthropicMessagesTransport",
            "RelayGeminiTransport",
        ).forEach { className ->
            val source = java.io.File("src/main/java/ai/oriveo/community/core/provider/relay/$className.kt").readText()
            assertTrue(source.contains("internal class $className("))
            assertTrue(source.contains("suspend fun send("))
            assertTrue(source.contains("fun stream("))
            assertTrue(coordinator.contains("$className("))
        }
    }

    private fun String.countOccurrences(needle: String): Int =
        split(needle).size - 1
}
