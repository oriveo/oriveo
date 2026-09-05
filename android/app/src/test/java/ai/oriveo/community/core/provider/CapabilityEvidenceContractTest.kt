package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import java.io.File
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.After
import org.junit.Test

/** Android-side facade assertions against the shared `capability_evidence_contract.v1.json` fixture. */
class CapabilityEvidenceContractTest {
    private val json = Json { ignoreUnknownKeys = true }

    @After
    fun clearRuntimeEvidence() {
        UnsupportedParamCache.resetForTest()
        CapabilityEvidenceObservationBridge.resetForTesting()
    }

    @Test
    fun `all shared evidence golden cases resolve identically`() {
        val contract = readJson("shared/model-contracts/capability_evidence_contract.v1.json")
        contract.getArray("cases").forEach { rawCase ->
            val item = rawCase.jsonObject
            val queryObject = item.getObject("query")
            val query = CapabilityEvidenceFacade.Query(
                identity = queryObject.toIdentity(),
                now = queryObject.requiredLong("now"),
                hasExplicitValue = queryObject.optionalBoolean("hasExplicitValue") ?: false,
            )
            val candidates = item.getArray("candidates").map { rawCandidate ->
                rawCandidate.jsonObject.toCandidate()
            }
            val expected = item.getObject("expect")
            val actual = CapabilityEvidenceFacade.resolve(expected.requiredString("key"), query, candidates)

            assertEquals(item.requiredString("caseId"), expected.requiredString("support"), actual.support)
            assertEquals(item.requiredString("caseId"), expected.requiredString("source"), actual.source)
            assertEquals(item.requiredString("caseId"), expected.requiredString("grade"), actual.grade)
            assertEquals(item.requiredString("caseId"), expected.requiredString("requestPolicy"), actual.requestPolicy)
            assertEquals(item.requiredString("caseId"), expected.requiredString("reasonCode"), actual.reasonCode)
            val expectedPolicy = expected["policyEvidence"]
            if (expectedPolicy == null || expectedPolicy.toString() == "null") {
                assertEquals(item.requiredString("caseId"), null, actual.policyEvidence)
            } else {
                val policy = expectedPolicy.jsonObject
                assertNotNull(item.requiredString("caseId"), actual.policyEvidence)
                assertEquals(policy.requiredString("source"), actual.policyEvidence!!.source)
                assertEquals(policy.requiredString("grade"), actual.policyEvidence!!.grade)
            }
        }
    }

    @Test
    fun `production generation parameter shape is normalized before facade resolution`() {
        val shapes = readJson("shared/test-fixtures/provider-capability-evidence/production-shapes.v1.json")
        val payload = shapes.getObject("sources").getObject("generationProfile").getObject("payload")
        // Feed the raw payload through the production @Serializable decoder instead of hand-building a GenerationParameterRef here.
        val profile = json.decodeFromString<GenerationProfileRef>(payload.toString())
        val raw = profile.parameters.first { it.id == "top_p" }
        assertEquals("accepted_unverified", raw.support)

        val identity = relayCandidateIdentity()
        val normalized = CapabilityEvidenceFacade.normalizeGenerationParameter(raw, identity)
        assertNotNull(normalized)
        val resolved = CapabilityEvidenceFacade.resolve(
            "generation_parameter/top_p",
            CapabilityEvidenceFacade.Query(relayQueryIdentity(), now = 1_000, hasExplicitValue = true),
            listOf(normalized!!),
        )

        assertEquals("unknown", resolved.support)
        assertEquals("relay_declaration", resolved.source)
        assertEquals("accepted_unverified", resolved.grade)
        assertEquals("allow_explicit_unverified", resolved.requestPolicy)

        val accepted = CapabilityEvidenceFacade.normalizeGenerationParameter(raw.copy(support = "accepted"), identity)
        assertEquals("unknown", accepted!!.support)
        assertEquals("accepted_unverified", accepted.grade)

        val providerMetadata = CapabilityEvidenceFacade.normalizeGenerationParameter(
            raw.copy(support = "supported", source = "provider_metadata"),
            identity,
        )
        assertEquals("server_profile", providerMetadata!!.source)
        assertEquals("declared", providerMetadata.grade)

        val verified = CapabilityEvidenceFacade.normalizeGenerationParameter(
            raw.copy(support = "supported", source = "relay_verification"),
            identity,
        )
        assertEquals("relay_verification", verified!!.source)
        assertEquals("observed", verified.grade)
    }

    @Test
    fun `ui relay identity endpoint matches each final transport and stream branch`() {
        val model = AIModel(id = "model-a", name = "Model A")
        val local = CapabilityEvidenceIdentity(
            partitionId = "user-a",
            connectionInstanceId = "relay-a",
            connectionGeneration = "generation-a",
            credentialEpoch = "credential-a",
            providerKind = ProviderKind.Relay.rawValue,
        )
        fun actual(transport: RelayTransport, stream: Boolean? = null, base: String? = "https://relay.test/custom") =
            CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
                provider = Provider(
                    id = "relay-a",
                    kind = ProviderKind.Relay,
                    baseUrlText = base,
                    relayRequested = RelayRequestedConfig(transport = transport, stream = stream),
                ),
                model = model,
                localIdentity = local,
            )
        fun expected(transport: RelayTransport, url: String) =
            CapabilityEvidenceProductionAdapter.dispatchIdentity(local, model, transport, url)

        assertEquals(
            expected(RelayTransport.OpenAIChatCompletions, "https://relay.test/custom/chat/completions"),
            actual(RelayTransport.OpenAIChatCompletions),
        )
        assertEquals(
            expected(RelayTransport.OpenAIResponses, "https://relay.test/custom/responses"),
            actual(RelayTransport.OpenAIResponses),
        )
        assertEquals(
            expected(RelayTransport.LlamaCppNative, "https://relay.test/custom/completion"),
            actual(RelayTransport.LlamaCppNative),
        )
        assertEquals(
            expected(RelayTransport.AnthropicMessages, "https://relay.test/custom/v1/messages"),
            actual(RelayTransport.AnthropicMessages),
        )
        val geminiStream = "https://relay.test/custom/v1beta/models/model-a:streamGenerateContent"
        assertEquals(expected(RelayTransport.GeminiGenerateContent, geminiStream), actual(RelayTransport.GeminiGenerateContent))
        assertEquals(expected(RelayTransport.GeminiGenerateContent, geminiStream), actual(RelayTransport.GeminiGenerateContent, stream = true))
        assertEquals(
            expected(RelayTransport.GeminiGenerateContent, "https://relay.test/custom/v1beta/models/model-a:generateContent"),
            actual(RelayTransport.GeminiGenerateContent, stream = false),
        )
        assertNull(actual(RelayTransport.Auto))
        assertNull(actual(RelayTransport.OpenAIChatCompletions, base = null))
    }

    @Test
    fun `observation bridge expires the nearest projection with a deterministic clock`() {
        val before = CapabilityEvidenceObservationBridge.revision.value
        CapabilityEvidenceObservationBridge.observeExpiry(expiryAt = 200, now = 100)
        assertEquals(false, CapabilityEvidenceObservationBridge.expireDueForTesting(199))
        assertEquals(true, CapabilityEvidenceObservationBridge.expireDueForTesting(200))
        assertEquals(before + 1, CapabilityEvidenceObservationBridge.revision.value)
        CapabilityEvidenceObservationBridge.invalidate()
        assertEquals(before + 2, CapabilityEvidenceObservationBridge.revision.value)
    }

    @Test
    fun `metadata publication automatically advances the observation revision`() = runTest {
        // Touch/reset the singleton before publishing: this proves its refresh collector, not a
        // caller-provided invalidate(), observes the real MetadataClient publication boundary.
        CapabilityEvidenceObservationBridge.resetForTesting()
        val before = CapabilityEvidenceObservationBridge.revision.value
        MetadataTestFixtures.applyRaw(
            """{"version":1,"providers":{"openAI":{"models":{"bridge-model":{"canonicalModelId":"bridge-model","transport":"openai_chat"}}}}}""",
        )
        val observed = withTimeout(2_000) {
            CapabilityEvidenceObservationBridge.revision.first { it > before }
        }
        assertTrue(observed > before)
    }

    @Test
    fun `connection scoped candidate without partition never becomes evidence`() {
        val queryIdentity = relayQueryIdentity()
        val candidate = CapabilityEvidenceFacade.Candidate(
            key = "generation_parameter/temperature",
            support = "supported",
            source = "relay_declaration",
            grade = "declared",
            scope = "connection_model_transport",
            identity = CapabilityEvidenceFacade.CandidateIdentity(
                providerKind = "relay",
                modelId = "local-model",
                effectiveTransport = "openai_chat_completions",
                metadataRevision = "local-7",
            ),
        )

        // With no explicit value this still fails closed: a candidate whose identity is incomplete authorises nothing.
        assertResolves(candidate, hasExplicitValue = false, policy = "omit_unknown", reason = "missing_evidence")
        // An explicitly set value does go out, but the authorisation comes from the user's intent alone. The candidate
        // itself stays rejected as none/none and must never come back to life as `supported` evidence.
        val explicit = resolve(candidate, hasExplicitValue = true)
        assertEquals("allow_explicit_unverified", explicit.requestPolicy)
        assertEquals("none", explicit.source)
        assertEquals("none", explicit.grade)
        assertEquals("unknown", explicit.support)
    }

    @Test
    fun `connection scoped candidate without endpoint fingerprint never becomes evidence`() {
        val candidate = CapabilityEvidenceFacade.Candidate(
            key = "generation_parameter/temperature",
            support = "supported",
            source = "relay_declaration",
            grade = "declared",
            scope = "connection_model_transport",
            identity = relayCandidateIdentity().copy(endpointFingerprint = null),
        )

        assertResolves(candidate, hasExplicitValue = false, policy = "omit_unknown", reason = "missing_evidence")
        val explicit = resolve(candidate, hasExplicitValue = true)
        assertEquals("allow_explicit_unverified", explicit.requestPolicy)
        assertEquals("none", explicit.source)
        assertEquals("none", explicit.grade)
    }

    /**
     * For an `accepted_unverified` candidate the only outbound criterion left is [hasExplicitValue]; neither a relay
     * providerKind nor a connection-level scope is required any more. The same candidate with no explicit value still
     * stays off the wire, and that reverse assertion is what keeps the relaxation from being implemented as an
     * unconditional yes.
     */
    @Test
    fun `accepted unverified provider scoped candidate follows the explicit value alone`() {
        val candidate = CapabilityEvidenceFacade.Candidate(
            key = "generation_parameter/temperature",
            support = "unknown",
            source = "relay_declaration",
            grade = "accepted_unverified",
            scope = "provider_model_transport",
            identity = CapabilityEvidenceFacade.CandidateIdentity(
                providerKind = "relay",
                modelId = "local-model",
                effectiveTransport = "openai_chat_completions",
                metadataRevision = "local-7",
            ),
        )

        assertResolves(candidate, hasExplicitValue = true, policy = "allow_explicit_unverified", reason = "user_accepted_unverified")
        assertResolves(candidate, hasExplicitValue = false, policy = "omit_unknown", reason = "missing_evidence")
    }

    /**
     * The other boundary of that relaxation: identity isolation is not a question of evidence quality. When the
     * transport this dispatch will actually use cannot be determined (a relay whose connection identity has not been
     * resolved yet reports "unknown" through `incompleteIdentity`), even an explicitly enabled capability has to fail
     * closed - otherwise one account's scope would be applied to another account's connection.
     */
    @Test
    fun `explicit value cannot fall open when the dispatch identity is not concrete`() {
        val unresolved = relayQueryIdentity().copy(effectiveTransport = "unknown")
        val resolved = CapabilityEvidenceFacade.resolve(
            "tool_call",
            CapabilityEvidenceFacade.Query(unresolved, now = 1_000, hasExplicitValue = true),
            emptyList(),
        )
        assertEquals("omit_unknown", resolved.requestPolicy)
        assertEquals("missing_evidence", resolved.reasonCode)

        // Reverse assertion: the same query with a concrete transport must be let through, so the guard above cannot
        // quietly turn the whole relaxation off.
        val dispatchable = CapabilityEvidenceFacade.resolve(
            "tool_call",
            CapabilityEvidenceFacade.Query(relayQueryIdentity(), now = 1_000, hasExplicitValue = true),
            emptyList(),
        )
        assertEquals("allow_explicit_unverified", dispatchable.requestPolicy)
    }

    /** Where the relaxation stops: when authoritative evidence says the capability is unsupported, an explicit value is still not sent. */
    @Test
    fun `official unsupported evidence still omits even with an explicit value`() {
        val candidate = CapabilityEvidenceFacade.Candidate(
            key = "web_search",
            support = "unsupported",
            source = "server_typed",
            grade = "machine_verified",
            scope = "provider_model_transport",
            identity = relayCandidateIdentity(),
        )

        assertResolves(candidate, hasExplicitValue = true, policy = "omit_unsupported", reason = "unsupported")
    }

    @Test
    fun `runtime self-heal production cache overlays request policy without changing support`() {
        val identity = relayQueryIdentity().copy(generationRevision = "local-7")
        assertEquals(UnsupportedParamCache.WriteOutcome.Added, UnsupportedParamCache.writeUnsupported(identity, "temperature"))
        val declared = CapabilityEvidenceFacade.Candidate(
            key = "generation_parameter/temperature",
            support = "supported",
            source = "relay_declaration",
            grade = "declared",
            scope = "connection_model_transport",
            identity = relayCandidateIdentity(),
        )

        val resolved = CapabilityEvidenceFacade.resolve(
            declared.key,
            CapabilityEvidenceFacade.Query(identity, now = 1_000, hasExplicitValue = true),
            listOf(declared) + UnsupportedParamCache.runtimeRejectedEvidence(identity),
        )

        assertEquals("supported", resolved.support)
        assertEquals("allow", declared.resolutionPolicyForTest())
        assertEquals("omit_runtime_rejected", resolved.requestPolicy)
        assertEquals("runtime_rejected", resolved.reasonCode)
        assertEquals("runtime_observation", resolved.policyEvidence?.source)

        val rotated = identity.copy(credentialEpoch = "ce9")
        assertTrue(UnsupportedParamCache.runtimeRejectedEvidence(rotated).isEmpty())

        val missingRevisions = identity.copy(metadataRevision = null, generationRevision = null)
        assertEquals(UnsupportedParamCache.WriteOutcome.Ineligible, UnsupportedParamCache.writeUnsupported(missingRevisions, "top_p"))
        assertTrue(UnsupportedParamCache.runtimeRejectedEvidence(missingRevisions).isEmpty())

        UnsupportedParamCache.clear(identity)
        assertTrue(UnsupportedParamCache.runtimeRejectedEvidence(identity).isEmpty())

        val endpointA = identity.copy(endpointFingerprint = "ep_a")
        val endpointB = identity.copy(endpointFingerprint = "ep_b")
        assertEquals(UnsupportedParamCache.WriteOutcome.Added, UnsupportedParamCache.writeUnsupported(endpointA, "temperature"))
        assertEquals(UnsupportedParamCache.WriteOutcome.Added, UnsupportedParamCache.writeUnsupported(endpointB, "top_p"))
        UnsupportedParamCache.clearConnection(
            partitionId = identity.partitionId,
            connectionInstanceId = identity.connectionInstanceId,
            connectionGeneration = identity.connectionGeneration,
            credentialEpoch = identity.credentialEpoch,
            providerKind = identity.providerKind,
            effectiveModelId = identity.modelId,
        )
        assertTrue(UnsupportedParamCache.runtimeRejectedEvidence(endpointA).isEmpty())
        assertTrue(UnsupportedParamCache.runtimeRejectedEvidence(endpointB).isEmpty())
    }

    private fun JsonObject.toCandidate(): CapabilityEvidenceFacade.Candidate {
        val identity = CapabilityEvidenceFacade.CandidateIdentity(
            partitionId = optionalString("partitionId"),
            connectionInstanceId = optionalString("connectionInstanceId"),
            connectionGeneration = optionalString("connectionGeneration"),
            credentialEpoch = optionalString("credentialEpoch"),
            providerKind = requiredString("providerKind"),
            modelId = requiredString("modelId"),
            effectiveTransport = requiredString("transport"),
            endpointFingerprint = optionalString("endpointFingerprint"),
            metadataRevision = optionalString("metadataRevision"),
            generationRevision = optionalString("generationRevision"),
        )
        return CapabilityEvidenceFacade.Candidate(
            key = requiredString("key"),
            support = requiredString("support"),
            source = requiredString("source"),
            grade = requiredString("grade"),
            scope = requiredString("scope"),
            identity = identity,
            observedAt = optionalLong("observedAt"),
            expiresAt = optionalLong("expiresAt"),
            policy = optionalString("policy"),
        )
    }

    private fun JsonObject.toIdentity() = CapabilityEvidenceFacade.QueryIdentity(
        partitionId = requiredString("partitionId"),
        connectionInstanceId = requiredString("connectionInstanceId"),
        connectionGeneration = requiredString("connectionGeneration"),
        credentialEpoch = requiredString("credentialEpoch"),
        providerKind = requiredString("providerKind"),
        modelId = requiredString("modelId"),
        canonicalModelId = optionalString("canonicalModelId"),
        effectiveTransport = requiredString("effectiveTransport"),
        endpointFingerprint = optionalString("endpointFingerprint"),
        metadataRevision = optionalString("metadataRevision"),
        generationRevision = optionalString("generationRevision"),
    )

    private fun relayQueryIdentity() = CapabilityEvidenceFacade.QueryIdentity(
        partitionId = "u1",
        connectionInstanceId = "relay-1",
        connectionGeneration = "cg3",
        credentialEpoch = "ce8",
        providerKind = "relay",
        modelId = "local-model",
        effectiveTransport = "openai_chat_completions",
        endpointFingerprint = "ep_fixture",
        metadataRevision = "local-7",
    )

    private fun relayCandidateIdentity() = CapabilityEvidenceFacade.CandidateIdentity(
        partitionId = "u1",
        connectionInstanceId = "relay-1",
        connectionGeneration = "cg3",
        credentialEpoch = "ce8",
        providerKind = "relay",
        modelId = "local-model",
        effectiveTransport = "openai_chat_completions",
        endpointFingerprint = "ep_fixture",
        metadataRevision = "local-7",
    )

    private fun resolve(
        candidate: CapabilityEvidenceFacade.Candidate,
        hasExplicitValue: Boolean,
    ): CapabilityEvidenceFacade.Resolution = CapabilityEvidenceFacade.resolve(
        candidate.key,
        CapabilityEvidenceFacade.Query(relayQueryIdentity(), now = 1_000, hasExplicitValue = hasExplicitValue),
        listOf(candidate),
    )

    private fun assertResolves(
        candidate: CapabilityEvidenceFacade.Candidate,
        hasExplicitValue: Boolean,
        policy: String,
        reason: String,
    ) {
        val resolved = resolve(candidate, hasExplicitValue)
        assertEquals("explicit=$hasExplicitValue", policy, resolved.requestPolicy)
        assertEquals("explicit=$hasExplicitValue", reason, resolved.reasonCode)
    }

    private fun CapabilityEvidenceFacade.Candidate.resolutionPolicyForTest(): String =
        CapabilityEvidenceFacade.resolve(
            key,
            CapabilityEvidenceFacade.Query(relayQueryIdentity(), now = 1_000, hasExplicitValue = true),
            listOf(this),
        ).requestPolicy

    private fun readJson(relativePath: String): JsonObject {
        val moduleDir = File(System.getProperty("user.dir") ?: ".").absoluteFile
        val repoRoot = moduleDir.parentFile!!.parentFile!!
        return json.parseToJsonElement(File(repoRoot, relativePath).readText()).jsonObject
    }

    private fun JsonObject.getObject(key: String): JsonObject = getValue(key).jsonObject
    private fun JsonObject.getArray(key: String): JsonArray = getValue(key).jsonArray
    private fun JsonObject.requiredString(key: String): String = getValue(key).jsonPrimitive.content
    private fun JsonObject.optionalString(key: String): String? = get(key)?.jsonPrimitive?.contentOrNull
    private fun JsonObject.requiredLong(key: String): Long = requiredString(key).toLong()
    private fun JsonObject.optionalLong(key: String): Long? = optionalString(key)?.toLong()
    private fun JsonObject.optionalBoolean(key: String): Boolean? = get(key)?.jsonPrimitive?.booleanOrNull
}
