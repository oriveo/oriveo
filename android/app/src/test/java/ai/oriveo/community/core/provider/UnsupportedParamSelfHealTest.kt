package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.ExperimentalCoroutinesApi

@OptIn(ExperimentalCoroutinesApi::class)
class UnsupportedParamSelfHealTest {

    /**
     * A complete local runtime identity for the tests, pinned to a `metadata-test` revision.
     *
     * It exercises the cache, classifier and strip behaviour only; it deliberately does not
     * claim to prove how a real identity is assembled, which is covered where the identity is
     * actually built from the repository and the production adapter.
     */
    private fun identity(
        provider: String = "grok",
        model: String = "grok-4.20",
        endpoint: String = "ep_test",
    ) = CapabilityEvidenceFacade.QueryIdentity(
        partitionId = "test-account",
        connectionInstanceId = "test-connection",
        connectionGeneration = "cg-1",
        credentialEpoch = "ce-1",
        providerKind = provider,
        modelId = model,
        effectiveTransport = "openai_chat_completions",
        endpointFingerprint = endpoint,
        metadataRevision = "metadata-test",
        generationRevision = "generation-test",
    )

    private fun cached(identity: CapabilityEvidenceFacade.QueryIdentity, parameter: String): Boolean =
        UnsupportedParamCache.runtimeRejectedEvidence(identity)
            .any { it.key == "generation_parameter/$parameter" }

    @After
    fun tearDown() {
        UnsupportedParamCache.resetForTest()
        UnsupportedParamClassifier.resetRuntimePatternsForTest()
    }

    

    @Test
    fun `classifier extracts xAI param (camelCase)`() {
        assertEquals(
            "reasoning_effort",
            UnsupportedParamClassifier.extractParam(
                "Model grok-4.20-0309-non-reasoning does not support parameter reasoningEffort.",
            ),
        )
    }

    @Test
    fun `classifier extracts OpenAI official Unsupported parameter wording`() {
        assertEquals(
            "temperature",
            UnsupportedParamClassifier.extractParam(
                "Unsupported parameter: 'temperature' is not supported with this model.",
            ),
        )
        assertEquals(
            "reasoning.summary",
            UnsupportedParamClassifier.extractParam(
                "Unsupported parameter: 'reasoning.summary' is not supported with this model.",
            ),
        )
        
        assertNull(
            UnsupportedParamClassifier.extractParam(
                "Unsupported value: 'xhigh' is not supported with this model.",
            ),
        )
        assertNull(UnsupportedParamClassifier.extractParam("unsupported parameters are ignored"))
    }

    @Test
    fun `classifier extracts OpenAI unrecognized argument`() {
        assertEquals(
            "foo_bar",
            UnsupportedParamClassifier.extractParam("Unrecognized request argument supplied: foo_bar"),
        )
    }

    @Test
    fun `classifier extracts generic unknown parameter`() {
        assertEquals(
            "enable_thinking",
            UnsupportedParamClassifier.extractParam("unknown parameter: enable_thinking"),
        )
    }

    @Test
    fun `classifier extracts Anthropic unexpected field with optional colon`() {
        assertEquals(
            "thinking",
            UnsupportedParamClassifier.extractParam("""{"error":{"message":"unexpected field: thinking"}}"""),
        )
        assertEquals(
            "reasoning",
            UnsupportedParamClassifier.extractParam("unexpected parameter: reasoning"),
        )
    }

    @Test
    fun `classifier extracts Gemini Unknown name`() {
        assertEquals(
            "thinking_config",
            UnsupportedParamClassifier.extractParam("Unknown name \"thinkingConfig\": Cannot find field."),
        )
    }

    @Test
    fun `classifier extracts dotted path and canonicalizes segments`() {
        assertEquals(
            "generation_config.thinking_config",
            UnsupportedParamClassifier.extractParam("unknown parameter: generationConfig.thinkingConfig"),
        )
    }

    @Test
    fun `classifier returns null on unrelated 400 and null input`() {
        assertNull(
            UnsupportedParamClassifier.extractParam("Each message must have at least one content element"),
        )
        assertNull(UnsupportedParamClassifier.extractParam(null))
        assertNull(UnsupportedParamClassifier.extractParam(""))
    }

    

    @Test
    fun `downloaded pattern matches new wording the baseline misses`() {
        
        val wording = "Parameter 'reasoningEffort' is not allowed for this model"
        UnsupportedParamClassifier.setRuntimePatterns(
            listOf(
                MetadataClient.SelfHealPattern(
                    pattern = "parameter ['\"]?([A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)*)['\"]? is not allowed",
                    flags = "i",
                ),
            ),
        )
        
        assertEquals("reasoning_effort", UnsupportedParamClassifier.extractParam(wording))
    }

    @Test
    fun `illegal downloaded patterns are skipped without crashing`() {
        
        UnsupportedParamClassifier.setRuntimePatterns(
            listOf(
                MetadataClient.SelfHealPattern(pattern = "(unclosed", flags = "i"),
                MetadataClient.SelfHealPattern(pattern = "a".repeat(201)),
                MetadataClient.SelfHealPattern(pattern = "  "),
                MetadataClient.SelfHealPattern(pattern = "rejected param ([A-Za-z0-9_]+)", flags = "i"),
            ),
        )
        
        assertEquals("foo_bar", UnsupportedParamClassifier.extractParam("rejected param fooBar"))
        
        assertNull(UnsupportedParamClassifier.extractParam("unrelated 400 body"))
    }

    @Test
    fun `baseline still wins and works when no patterns are downloaded (regression)`() {
        
        UnsupportedParamClassifier.resetRuntimePatternsForTest()
        
        assertEquals(
            "reasoning_effort",
            UnsupportedParamClassifier.extractParam("does not support parameter reasoningEffort"),
        )
        
        assertNull(
            UnsupportedParamClassifier.extractParam("Parameter 'reasoningEffort' is not allowed for this model"),
        )
    }

    @Test
    fun `baseline takes precedence over downloaded pattern`() {
        
        UnsupportedParamClassifier.setRuntimePatterns(
            listOf(MetadataClient.SelfHealPattern(pattern = "parameter ([A-Za-z0-9_]+)", flags = "i")),
        )
        assertEquals(
            "reasoning_effort",
            UnsupportedParamClassifier.extractParam("does not support parameter reasoningEffort"),
        )
    }

    
    
    
    @Test
    fun `downloaded fixed param covers wording that never names the parameter`() {
        val wording =
            """{"error":{"message":"Your organization must be verified to generate reasoning summaries"}}"""
        
        assertNull(UnsupportedParamClassifier.extractParam(wording))

        UnsupportedParamClassifier.setRuntimePatterns(
            listOf(
                MetadataClient.SelfHealPattern(
                    pattern = "must be verified to generate reasoning summaries",
                    flags = "i",
                    param = "reasoning.summary",
                ),
            ),
        )
        assertEquals("reasoning.summary", UnsupportedParamClassifier.extractParam(wording))
    }

    @Test
    fun `capture group still wins over the downloaded fixed param`() {
        UnsupportedParamClassifier.setRuntimePatterns(
            listOf(
                MetadataClient.SelfHealPattern(
                    pattern = "rejected param ([A-Za-z0-9_]+)",
                    flags = "i",
                    param = "reasoning.summary",
                ),
            ),
        )
        assertEquals("foo_bar", UnsupportedParamClassifier.extractParam("rejected param fooBar"))
    }

    @Test
    fun `malformed fixed param is dropped instead of poisoning the parameter name`() {
        UnsupportedParamClassifier.setRuntimePatterns(
            listOf(
                MetadataClient.SelfHealPattern(pattern = "must be verified", flags = "i", param = "reasoning summary"),
                MetadataClient.SelfHealPattern(pattern = "quota exhausted", flags = "i", param = "a".repeat(65)),
            ),
        )
        assertNull(UnsupportedParamClassifier.extractParam("must be verified"))
        assertNull(UnsupportedParamClassifier.extractParam("quota exhausted"))
        
        assertEquals(
            "reasoning_effort",
            UnsupportedParamClassifier.extractParam("does not support parameter reasoningEffort"),
        )
    }

    

    @Test
    fun `strip removes top-level snake key when reported as camelCase`() {
        val body = """{"model":"grok","stream":true,"reasoning_effort":"high"}"""
        val out = UnsupportedParamJson.stripParam(body, "reasoningEffort")!!
        assertFalse(out.contains("reasoning_effort"))
        assertTrue(out.contains("\"model\":\"grok\""))
        assertTrue(out.contains("\"stream\":true"))
    }

    @Test
    fun `strip removes nested reasoning effort but keeps summary (Responses)`() {
        
        val body = """{"model":"grok","reasoning":{"effort":"high","summary":"auto"}}"""
        val out = UnsupportedParamJson.stripParam(body, "reasoningEffort")!!
        assertFalse(out.contains("\"effort\""))
        assertTrue(out.contains("\"summary\":\"auto\""))
        assertTrue(out.contains("\"reasoning\""))
    }

    
    
    @Test
    fun `strip removes nested reasoning summary by fixed param path, keeps effort`() {
        val body = """{"model":"o4-mini","reasoning":{"effort":"medium","summary":"auto"}}"""
        val out = UnsupportedParamJson.stripParam(body, "reasoning.summary")!!
        assertFalse(out.contains("\"summary\""))
        assertTrue(out.contains("\"effort\":\"medium\""))
        assertTrue(out.contains("\"reasoning\""))
    }

    @Test
    fun `strip removes deeply nested thinkingConfig (Gemini) keeps siblings`() {
        val body = """{"contents":[],"generationConfig":{"thinkingConfig":{"thinkingBudget":100},"temperature":1}}"""
        val out = UnsupportedParamJson.stripParam(body, "generation_config.thinking_config")!!
        assertFalse(out.contains("thinkingConfig"))
        assertTrue(out.contains("\"temperature\":1"))
        assertTrue(out.contains("\"generationConfig\""))
    }

    @Test
    fun `strip preserves similarly named keys inside tools arrays`() {
        val body = """{"tools":[{"type":"function","reasoning_effort":"high","name":"search"}],"model":"m"}"""
        assertNull(UnsupportedParamJson.stripParam(body, "reasoningEffort"))
    }

    @Test
    fun `strip removes top-level parameter but preserves JSON Schema property`() {
        val body = """{"temperature":0.7,"tools":[{"type":"function","function":{"parameters":{"type":"object","properties":{"temperature":{"type":"number"}}}}}]}"""
        val out = UnsupportedParamJson.stripParam(body, "temperature")!!
        assertFalse(out.startsWith("{\"temperature\""))
        assertTrue(out.contains("\"properties\":{\"temperature\":{\"type\":\"number\"}}"))
    }

    @Test
    fun `strip returns null when param absent (no pointless retry)`() {
        assertNull(UnsupportedParamJson.stripParam("""{"model":"m","stream":true}""", "reasoningEffort"))
    }

    @Test
    fun `strip returns null on malformed json`() {
        assertNull(UnsupportedParamJson.stripParam("not json", "reasoningEffort"))
    }

    

    @Test
    fun `cache normalizes camel and snake to the same key`() {
        val identity = identity()
        assertEquals(UnsupportedParamCache.WriteOutcome.Added, UnsupportedParamCache.writeUnsupported(identity, "reasoningEffort"))
        
        assertTrue(cached(identity, "reasoning_effort"))
    }

    @Test
    fun `cache write outcome distinguishes duplicate exact identity`() {
        val identity = identity()
        assertEquals(UnsupportedParamCache.WriteOutcome.Added, UnsupportedParamCache.writeUnsupported(identity, "reasoning_effort"))
        assertEquals(UnsupportedParamCache.WriteOutcome.AlreadyCached, UnsupportedParamCache.writeUnsupported(identity, "reasoningEffort"))
    }

    @Test
    fun `cache isolates by model`() {
        UnsupportedParamCache.writeUnsupported(identity(), "reasoning_effort")
        assertFalse(cached(identity(model = "grok-3-mini"), "reasoning_effort"))
    }

    @Test
    fun `relay cache isolates same model by endpoint fingerprint without exposing url`() {
        val first = relayEndpointFingerprint("https://user:secret@one.example/v1/chat/completions?key=secret")!!
        val second = relayEndpointFingerprint("https://two.example/v1/chat/completions")!!
        assertTrue(first.startsWith("ep_"))
        assertFalse(first.contains("one.example"))
        val firstIdentity = identity(provider = "relay", model = "same-model", endpoint = first)
        UnsupportedParamCache.writeUnsupported(firstIdentity, "temperature")
        assertTrue(cached(firstIdentity, "temperature"))
        assertFalse(cached(identity(provider = "relay", model = "same-model", endpoint = second), "temperature"))
    }

    @Test
    fun `cache key escapes field separators so pipe in modelId cannot collide`() {
        
        
        
        val first = identity().copy(modelId = "m|x", canonicalModelId = null)
        val second = identity().copy(modelId = "m", canonicalModelId = "x")
        assertEquals(
            UnsupportedParamCache.WriteOutcome.Added,
            UnsupportedParamCache.writeUnsupported(first, "temperature"),
        )
        assertEquals(
            UnsupportedParamCache.WriteOutcome.Added,
            UnsupportedParamCache.writeUnsupported(second, "temperature"),
        )
        assertTrue(UnsupportedParamCache.runtimeRejectedParamsForRequest(second).contains("temperature"))
    }

    @Test
    fun `production send ignores legacy cache and preserves the original body`() = runTest {
        val identity = identity()
        UnsupportedParamCache.writeUnsupported(identity, "reasoningEffort")
        val bodies = mutableListOf<String>()

        UnsupportedParamRetry.run(
            providerKind = ProviderKind.Grok,
            modelId = "grok-4.20",
            initialBody = """{"model":"grok-4.20","reasoning_effort":"high","stream":true}""",
            identity = identity,
        ) { body ->
            bodies += body
        }

        assertEquals(1, bodies.size)
        assertTrue(bodies.single().contains("reasoning_effort"))
        assertTrue(bodies.single().contains("\"stream\":true"))
    }

    @Test
    fun `structured or prose 400 is surfaced after exactly one attempt`() = runTest {
        val identity = identity()
        val firstAttemptBodies = mutableListOf<String>()
        var firstSendCount = 0

        val error = runCatching {
            UnsupportedParamRetry.run(
                providerKind = ProviderKind.Grok,
                modelId = "grok-4.20",
                initialBody = """{"model":"grok-4.20","reasoning_effort":"high","stream":true}""",
                identity = identity,
            ) { body ->
                firstAttemptBodies += body
                firstSendCount += 1
                throw ProviderServiceError.Upstream(
                    statusCode = 400,
                    detail = "does not support parameter reasoning_effort",
                    rejectedParameter = "reasoning_effort",
                )
            }
        }.exceptionOrNull()
        assertTrue(error is ProviderServiceError.Upstream)
        assertEquals(1, firstSendCount)
        assertEquals(1, firstAttemptBodies.size)
        assertTrue(firstAttemptBodies.single().contains("reasoning_effort"))
        assertFalse(cached(identity, "reasoning_effort"))
    }

    @Test
    fun `failed single send does not poison the unsupported cache`() = runTest {
        var attempts = 0

        runCatching {
            UnsupportedParamRetry.run(
                providerKind = ProviderKind.Relay,
                modelId = "local-model",
                initialBody = """{"model":"local-model","temperature":0.7,"stream":true}""",
            ) {
                attempts += 1
                throw ProviderServiceError.Upstream(
                    statusCode = 400,
                    detail = "does not support parameter temperature",
                )
            }
        }

        assertEquals(1, attempts)
        assertFalse(cached(identity(provider = "relay", model = "local-model", endpoint = "ep_a"), "temperature"))
    }

}
