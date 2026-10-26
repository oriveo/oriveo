package ai.oriveo.community.core.capability.truth

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * For a model inside the catalog, tool_call is decided only by the server typed evidence: once the evidence
 * namespace is present it is authoritative, and empty, expired or corrupted views all resolve to unknown without falling back
 * to the top-level `toolCall` / model facts; only an absent namespace (an old server) allows legacy handling, and
 * only a hand-entered model outside the catalog may fall back to a first-hand declaration / model facts.
 *
 * The catalog is the whole payload of the server golden sample `tool-call-order-evidence.v1.json` (only the top-level
 * `toolCall` is set to true); the time window is judged only by the injected clock, and the payload is injected
 * into a separate MetadataClient through the production decode / publish boundary.
 */
class OfficialTruthAdapterToolCallTest {
    private val golden = ToolCallOrderEvidenceGolden
    private val now = golden.nowMs
    private val model = AIModel(id = golden.modelId, name = golden.modelId, toolCall = true)
    private val official = Provider(id = "official-openAI", kind = ProviderKind.OpenAI)
    private val subscription = Provider(id = "openAI-sub", kind = ProviderKind.OpenAI, authMode = ProviderAuthMode.Subscription)

    @Test
    fun `typed supported evidence resolves supported`() {
        val client = client("supported")
        val decoded = client.currentCapabilityEvidenceModel(model.id, official.kind)!!.metadata
        assertTrue(decoded.capabilityEvidenceCandidates!!.any { it.key == "tool_call" && it.source == "server_typed" })
        assertEquals("supported", support(official, client))
        assertEquals(true, verdict(official, client))
    }

    @Test
    fun `typed unsupported evidence beats top level toolCall true`() {
        val client = client("unsupported")
        assertEquals(true, client.currentCapabilityEvidenceModel(model.id, official.kind)!!.metadata.toolCall)
        assertEquals("unsupported", support(official, client))
        assertEquals(false, verdict(official, client))
    }

    @Test
    fun `subscription ignores the catalog namespace and model toolCall, reading only modelFacts`() {
        // The official catalog has an entry whose typed evidence is supported, and both the catalog top level and model.toolCall are true.
        // The subscription /models response has no tool field: the catalog bit is not first-hand, the subscription route does not read official catalog evidence and trusts only modelFacts, and without them the verdict is unknown.
        val client = client("supported")
        assertTrue(client.currentCapabilityEvidenceModel(model.id, subscription.kind)!!
            .metadata.capabilityEvidenceCandidates!!.any { it.key == "tool_call" && it.support == "supported" })
        assertNull(client.modelFacts(subscription.kind, model.id)?.toolCall)
        assertUnknown(subscription, client)

        val withFacts = client("supported", modelFactsToolCall = false)
        assertEquals(false, withFacts.modelFacts(subscription.kind, model.id)?.toolCall)
        val resolution = resolution(subscription, withFacts)
        assertEquals("unsupported", resolution?.support)
        assertEquals("model_facts", resolution?.source)
        assertEquals(false, verdict(subscription, withFacts))
    }

    @Test
    fun `expired typed evidence with top level toolCall true stays unknown`() {
        val client = client("supported")
        // Push the injected clock past the golden evidence window without changing observedAt / expiresAt.
        val later = golden.toolCallExpiresAt("supported") + 1
        assertTrue(
            client.currentCapabilityEvidenceModel(model.id, official.kind)!!.metadata
                .capabilityEvidenceCandidates!!.any { it.key == "tool_call" && it.expiresAt!! < later },
        )
        assertUnknown(official, client, at = later)
    }

    @Test
    fun `contract v2 payload without an evidence view and top level toolCall true stays unknown`() {
        // A new server omits the view key for a model without evidence: absent means unknown, with no fallback to the top-level toolCall.
        val client = client("missing")
        assertNull(client.currentCapabilityEvidenceModel(model.id, official.kind)!!.metadata.capabilityEvidenceCandidates)
        assertUnknown(official, client)
    }

    @Test
    fun `absent namespace from a legacy server keeps the legacy toolCall bit`() {
        // The golden missing payload carries no evidence view key; lowering the capability contract version to 1 and setting the top-level toolCall to true gives the old-server shape.
        val client = client("missing", capabilityContractVersion = 1)
        assertNull(client.currentCapabilityEvidenceModel(model.id, official.kind)!!.metadata.capabilityEvidenceCandidates)
        assertEquals("supported", support(official, client))
        assertEquals(true, verdict(official, client))
    }

    @Test
    fun `model outside the catalog keeps the first party fallback`() {
        val client = client("unsupported")
        val custom = AIModel(id = "my-hand-typed-model", name = "my-hand-typed-model", toolCall = true)
        assertNull(client.currentCapabilityEvidenceModel(custom.id, official.kind))
        assertEquals("supported", support(official, client, custom))
        assertEquals(true, verdict(official, client, custom))
    }

    // ---- helpers ----

    private fun assertUnknown(provider: Provider, client: MetadataClient, at: Long = now) {
        assertEquals(provider.authMode.rawValue, "unknown", support(provider, client, at = at))
        assertNull(provider.authMode.rawValue, verdict(provider, client, at = at))
    }

    private fun support(provider: Provider, client: MetadataClient, target: AIModel = model, at: Long = now): String? =
        resolution(provider, client, target, at)?.support

    private fun resolution(provider: Provider, client: MetadataClient, target: AIModel = model, at: Long = now) =
        CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider = provider,
            model = target,
            keys = setOf("tool_call"),
            // A model outside the catalog has no metadata transport, so it is given the outbound channel of the golden subject.
            finalTransport = golden.transport,
            metadataClient = client,
            now = at,
        ).decision("tool_call")?.resolution

    private fun verdict(provider: Provider, client: MetadataClient, target: AIModel = model, at: Long = now): Boolean? =
        CapabilityEvidenceProductionAdapter.toolCallVerdict(provider, target, metadataClient = client, now = at)

    /** The whole golden [variant] payload with only the subject entry's top-level toolCall set to true (the old-server case additionally lowers the capability contract version). */
    private fun client(
        variant: String,
        modelFactsToolCall: Boolean? = null,
        capabilityContractVersion: Int? = null,
    ): MetadataClient =
        golden.client(
            variant = variant,
            capabilityContractVersion = capabilityContractVersion,
            topLevelToolCall = JsonPrimitive(true),
            modelFacts = modelFactsToolCall?.let { mapOf(model.id to it) }.orEmpty(),
            etag = "\"tool-call-truth\"",
        )
}
