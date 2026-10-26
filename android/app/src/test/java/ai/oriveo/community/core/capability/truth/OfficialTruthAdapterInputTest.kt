package ai.oriveo.community.core.capability.truth

import ai.oriveo.community.core.capability.InputNegativeCache
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.AttachmentSupportInfo
import ai.oriveo.community.core.model.EngineDeclaration
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayCapabilityOverrides
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade.InputCapabilityDisabledReason
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade.InputCapabilityHint
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade.InputCapabilityOutbound
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade.InputCapabilityProjection
import ai.oriveo.community.core.provider.relay.RelayNegativeCache
import io.mockk.every
import io.mockk.spyk
import java.io.File
import java.time.Instant
import java.util.zip.GZIPInputStream
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Projection of the three input-capability keys. Official verdicts come from real model entries of the bundled
 * snapshot bundled-metadata.v2, are injected into a separate MetadataClient through the production decode / publish
 * boundary, and are then projected by [resolveInputCapabilityProjections].
 */
class OfficialTruthAdapterInputTest {
    private val now: Instant = Instant.parse("2026-10-19T00:00:00Z")
    private val cache = InputNegativeCache(InputNegativeCache.MemoryStore()) { now.epochSecond }
    private val relayCache = RelayNegativeCache(RelayNegativeCache.MemoryStore())

    @Test
    fun `DeepSeek flash vision is auto available while native file is wire not implemented`() {
        val client = officialClient()
        val projections = project(official(ProviderKind.DeepSeek), AIModel(id = "deepseek-flash", name = "deepseek-flash"), client)
        assertAvailable(projections.vision)
        assertDisabled(projections.file, InputCapabilityDisabledReason.WIRE_NOT_IMPLEMENTED)
    }

    @Test
    fun `official Gemini vision on the gemini_generate dispatch value follows the verdict instead of a placeholder`() {
        val client = officialClient()
        val provider = official(ProviderKind.Gemini)
        val model = AIModel(id = "gemini-2.5-flash", name = "gemini-2.5-flash")
        // The dispatch route value (TransportKind.GeminiGenerate.wireValue) and the metadata entry both say gemini_generate.
        val projections = requireNotNull(
            resolveInputCapabilityProjections(
                provider = provider,
                model = model,
                finalTransport = "gemini_generate",
                metadataClient = client,
                negativeCache = cache,
                now = now,
            ),
        )
        assertAvailable(projections.vision)
        assertAvailable(project(provider, model, client).vision)
    }

    @Test
    fun `MiniMax-M3 vision is auto available`() {
        val projections = project(official(ProviderKind.MiniMax), AIModel(id = "MiniMax-M3", name = "MiniMax-M3"), officialClient())
        assertAvailable(projections.vision)
        assertAvailable(projections.video)
    }

    @Test
    fun `model capability absent disables vision and catalog silent Groq allam-2-7b stays unknown`() {
        val client = officialClient()
        val pro = project(official(ProviderKind.DeepSeek), AIModel(id = "deepseek-v4-pro", name = "deepseek-v4-pro"), client)
        assertDisabled(pro.vision, InputCapabilityDisabledReason.MODEL_ABSENT)
        // The catalog now explicitly declines image input for MiniMax M2.x, so use an official model whose image slot is still catalog_silent.
        val silent = project(official(ProviderKind.Groq), AIModel(id = "allam-2-7b", name = "allam-2-7b"), client)
        assertUnknown(silent.vision)
    }

    @Test
    fun `capabilityControls without vision_input projects unknown with first attach hint`() {
        val client = officialClient { providerKey, models ->
            if (providerKey != "deepseek") return@officialClient models
            val flash = models.getValue("deepseek-flash").jsonObject
            val controls = flash.getValue("capabilityControls").jsonObject
            JsonObject(
                models + ("deepseek-flash" to JsonObject(flash + ("capabilityControls" to JsonObject(controls - "vision_input")))),
            )
        }
        val projections = project(official(ProviderKind.DeepSeek), AIModel(id = "deepseek-flash", name = "deepseek-flash"), client)
        assertUnknown(projections.vision)
    }

    @Test
    fun `OpenAI official model missing from the catalog takes the dispatch transport and stays unknown`() {
        val projections = project(official(ProviderKind.OpenAI), AIModel(id = "gpt-unlisted-preview", name = "gpt-unlisted-preview"), officialClient())
        assertUnknown(projections.vision)
    }

    @Test
    fun `DeepSeek official model missing from the catalog takes the dispatch transport and stays unknown`() {
        val projections = project(official(ProviderKind.DeepSeek), AIModel(id = "deepseek-unlisted", name = "deepseek-unlisted"), officialClient())
        assertUnknown(projections.vision)
    }

    /** A Pending catalog only means the catalog has not spoken: take the dispatch route by kind, resolve the missing key as unknown, keep the entry open and show the first-attach hint once. */
    @Test
    fun `OpenAI official catalog pending takes the dispatch transport and stays unknown`() {
        val projections = project(official(ProviderKind.OpenAI), AIModel(id = "gpt-4o-mini", name = "gpt-4o-mini"), pendingClient())
        assertUnknown(projections.vision)
    }

    @Test
    fun `DeepSeek official catalog pending takes the dispatch transport and stays unknown`() {
        val projections = project(official(ProviderKind.DeepSeek), AIModel(id = "deepseek-flash", name = "deepseek-flash"), pendingClient())
        assertUnknown(projections.vision)
    }

    /** A failed catalog fetch (Unavailable, no snapshot yet) is treated like Pending: neither unavailable nor unimplemented on this platform. */
    @Test
    fun `official catalog unavailable takes the dispatch transport and stays unknown`() {
        val client = MetadataClient()
        assertEquals(MetadataClient.CatalogLoadState.Unavailable, client.catalogLoadState(ProviderKind.OpenAI))
        assertUnknown(project(official(ProviderKind.OpenAI), AIModel(id = "gpt-4o-mini", name = "gpt-4o-mini"), client).vision)
        assertUnknown(project(official(ProviderKind.DeepSeek), AIModel(id = "deepseek-flash", name = "deepseek-flash"), client).vision)
    }

    @Test
    fun `negative cache v2 hit disables an auto available verdict as rejected recently`() {
        val client = officialClient()
        val provider = official(ProviderKind.MiniMax)
        val model = AIModel(id = "MiniMax-M3", name = "MiniMax-M3")
        val control = client.currentCapabilityEvidenceModel(model.id, provider.kind)!!
            .metadata.capabilityControls!!.getValue("vision_input").jsonObject
        val wireFamily = control.string("wireFamily")!!
        val verdict = InputNegativeCache.Verdict(
            state = control.string("state")!!,
            reasonCode = control.string("reasonCode"),
            wireFamily = wireFamily,
            sourceRefs = (control["sourceRefs"] as? JsonArray)?.map { (it as JsonPrimitive).content },
        )
        // Entries of another connection or with an old revision do not match.
        cache.record("other-connection", model.id, wireFamily, "vision_input", "sig", verdict)
        cache.record(provider.id, model.id, wireFamily, "vision_input", "sig", verdict.copy(state = "unknown"))
        assertAvailable(project(provider, model, client).vision)

        cache.record(provider.id, model.id, wireFamily, "vision_input", "sig", verdict)
        assertDisabled(project(provider, model, client).vision, InputCapabilityDisabledReason.REJECTED_RECENTLY)
    }

    @Test
    fun `model missing from the catalog records its negative cache on the dispatch transport and hits next projection`() {
        val client = officialClient()
        val provider = official(ProviderKind.DeepSeek)
        val model = AIModel(id = "deepseek-unlisted", name = "deepseek-unlisted")
        val target = requireNotNull(
            officialInputNegativeCacheTarget(provider, model, "vision_input", metadataClient = client),
        )
        assertEquals("openai_chat", target.transport)
        assertUnknown(project(provider, model, client).vision)

        cache.record(target.connectionId, target.modelId, target.wireFamily, target.capabilityKey, "sig", target.verdict)
        assertDisabled(project(provider, model, client).vision, InputCapabilityDisabledReason.REJECTED_RECENTLY)
    }

    @Test
    fun `relay vision is unknown and opens the entry with a first attach hint`() {
        val projections = relayProject(envelope = AttachmentSupportInfo(image = true, nativeFile = true, textFileInline = true))
        assertUnknown(projections.vision)
        assertUnknown(projections.file)
    }

    @Test
    fun `relay envelope image false is a hard block`() {
        val projections = relayProject(envelope = AttachmentSupportInfo(image = false, nativeFile = true, textFileInline = true))
        assertDisabled(projections.vision, InputCapabilityDisabledReason.WIRE_NOT_IMPLEMENTED)
        assertUnknown(projections.file)
    }

    @Test
    fun `relay without connection identity fails closed on every key`() {
        val projections = relayProject(
            envelope = AttachmentSupportInfo(image = true, nativeFile = true, textFileInline = true),
            identity = null,
        )
        listOf(projections.vision, projections.file, projections.video).forEach {
            assertDisabled(it, InputCapabilityDisabledReason.WIRE_NOT_IMPLEMENTED)
        }
    }

    @Test
    fun `relay vision probed supported shows the badge and attaches`() {
        val model = relayModel(overrides = RelayCapabilityOverrides(image = true, testedKeys = setOf("image")))
        assertAvailable(relayProject(OPEN_ENVELOPE, model = model).vision)
    }

    @Test
    fun `relay vision declared or probed unsupported is disabled as model absent`() {
        val declared = relayModel(declaration = EngineDeclaration(image = false))
        assertDisabled(
            relayProject(OPEN_ENVELOPE, model = declared, engineProfile = "ollama").vision,
            InputCapabilityDisabledReason.MODEL_ABSENT,
        )
        val probed = relayModel(overrides = RelayCapabilityOverrides(image = false, testedKeys = setOf("image")))
        assertDisabled(relayProject(OPEN_ENVELOPE, model = probed).vision, InputCapabilityDisabledReason.MODEL_ABSENT)
    }

    @Test
    fun `relay vision unsupported with user add attaches and sends the image natively`() {
        val model = relayModel(
            declaration = EngineDeclaration(image = false),
            overrides = RelayCapabilityOverrides(image = true),
        )
        val vision = relayProject(OPEN_ENVELOPE, model = model, engineProfile = "ollama").vision
        assertAvailable(vision)
        assertEquals(InputCapabilityOutbound.NATIVE_PART, vision.outbound)
    }

    @Test
    fun `relay v1 image negative cache hit without override is rejected recently`() {
        val model = relayModel()
        relayCache.record(RelayNegativeCache.Key("relay-input", model.id, RelayTransport.OpenAIChatCompletions.value), RelayNegativeCache.Kind.Image)
        val projections = relayProject(OPEN_ENVELOPE, model = model)
        assertDisabled(projections.vision, InputCapabilityDisabledReason.REJECTED_RECENTLY)
        // The v1 negative cache only covers image input.
        assertUnknown(projections.file)
    }

    @Test
    fun `relay vision user remove is disabled as user removed`() {
        val model = relayModel(overrides = RelayCapabilityOverrides(image = false))
        assertDisabled(relayProject(OPEN_ENVELOPE, model = model).vision, InputCapabilityDisabledReason.USER_REMOVED)
    }

    /** Subscriptions are projected too: a first-hand input_modalities verdict, and the Codex Responses route has no video protocol family so that entry is closed. */
    @Test
    fun `subscription projects from the first hand input modalities`() {
        val model = AIModel(id = "gpt-5", name = "gpt-5", upstreamInputModalities = listOf("text", "image"))
        val provider = Provider(
            id = "openAI-sub",
            kind = ProviderKind.OpenAI,
            authMode = ProviderAuthMode.Subscription,
            models = listOf(model),
            catalogModels = listOf(model),
        )
        val projections = project(provider, model, officialClient())
        assertAvailable(projections.vision)
        assertDisabled(projections.file, InputCapabilityDisabledReason.MODEL_ABSENT)
        assertFalse(projections.video.editable)
        assertEquals(InputCapabilityOutbound.PLACEHOLDER, projections.video.outbound)
    }

    /** Old data has no first-hand field (null) and no modelFacts: unknown, entry open with the first-attach hint, and no fallback to the legacy capability bits. */
    @Test
    fun `subscription without first hand or model facts stays unknown`() {
        val model = AIModel(id = "gpt-5", name = "gpt-5", capabilities = listOf(ModelCapability.Image))
        val provider = Provider(
            id = "openAI-sub",
            kind = ProviderKind.OpenAI,
            authMode = ProviderAuthMode.Subscription,
            models = listOf(model),
            catalogModels = listOf(model),
        )
        val projections = project(provider, model, MetadataClient())
        assertUnknown(projections.vision)
        assertUnknown(projections.file)
    }

    // ---- helpers ----

    private fun project(provider: Provider, model: AIModel, client: MetadataClient) =
        requireNotNull(projectOrNull(provider, model, client))

    private fun projectOrNull(provider: Provider, model: AIModel, client: MetadataClient) =
        resolveInputCapabilityProjections(
            provider = provider,
            model = model,
            metadataClient = client,
            negativeCache = cache,
            now = now,
        )

    private fun relayModel(
        declaration: EngineDeclaration? = null,
        overrides: RelayCapabilityOverrides? = null,
    ) = AIModel(
        id = "relay-model",
        name = "relay-model",
        capabilities = listOf(ModelCapability.Image),
        engineDeclaration = declaration,
        relayCapabilityOverrides = overrides,
    )

    private fun relayProject(
        envelope: AttachmentSupportInfo,
        identity: CapabilityEvidenceFacade.QueryIdentity? = relayIdentity(),
        model: AIModel = relayModel(),
        engineProfile: String? = null,
    ): InputCapabilityProjections {
        val provider = Provider(
            id = "relay-input",
            kind = ProviderKind.Relay,
            relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions, engineProfile = engineProfile),
            models = listOf(model),
        )
        return requireNotNull(
            resolveInputCapabilityProjections(
                provider = provider,
                model = model,
                relayIdentity = identity,
                relayAttachmentSupport = envelope,
                metadataClient = MetadataClient(),
                negativeCache = cache,
                relayNegativeCache = relayCache,
                now = now,
            ),
        )
    }

    private fun relayIdentity() = CapabilityEvidenceFacade.QueryIdentity(
        partitionId = "partition",
        connectionInstanceId = "relay-input",
        connectionGeneration = "1",
        credentialEpoch = "1",
        providerKind = ProviderKind.Relay.rawValue,
        authMode = ProviderAuthMode.ApiKey.rawValue,
        modelId = "relay-model",
        effectiveTransport = RelayTransport.OpenAIChatCompletions.value,
        endpointFingerprint = "fingerprint",
    )

    private fun official(kind: ProviderKind) = Provider(id = "official-${kind.rawValue}", kind = kind)

    /** Publishes the real deepseek / miniMax / gemini entries of the bundled snapshot to a separate client through the production decode / publish boundary. */
    private fun officialClient(
        editModels: (String, JsonObject) -> JsonObject = { _, models -> models },
    ): MetadataClient {
        val bundled = bundledPayload()
        val providers = bundled.getValue("providers").jsonObject
        val payload = buildJsonObject {
            put("version", 1)
            put("contractVersion", 1)
            put("providers", buildJsonObject {
                listOf("deepseek", "miniMax", "gemini").forEach { key ->
                    val entry = providers.getValue(key).jsonObject
                    val models = editModels(key, entry.getValue("models").jsonObject)
                    put(key, JsonObject(entry + ("models" to models)))
                }
            })
        }
        return MetadataClient().apply { loadNetworkPayloadForTesting(payload.toString(), "\"input-truth\"") }
    }

    /** This provider is already in the index but its catalog has not arrived: no entry can be found and the load state is Pending. */
    private fun pendingClient(): MetadataClient = spyk(MetadataClient()).also { client ->
        every { client.catalogLoadState(any()) } returns MetadataClient.CatalogLoadState.Pending
    }

    private fun bundledPayload(): JsonObject {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "shared/model-contracts/bundled-metadata.v2.json.gz")
            if (candidate.exists()) {
                val text = GZIPInputStream(candidate.inputStream()).bufferedReader().use { it.readText() }
                return Json.parseToJsonElement(text).jsonObject
            }
            dir = dir.parentFile
        }
        throw IllegalStateException("bundled-metadata.v2.json.gz not found")
    }

    private fun assertAvailable(projection: InputCapabilityProjection) {
        assertTrue(projection.toString(), projection.visible)
        assertTrue(projection.toString(), projection.editable)
        assertEquals(InputCapabilityOutbound.NATIVE_PART, projection.outbound)
        assertNull(projection.hint)
        assertNull(projection.disabledReason)
    }

    private fun assertUnknown(projection: InputCapabilityProjection) {
        assertFalse(projection.toString(), projection.visible)
        assertTrue(projection.toString(), projection.editable)
        assertEquals(InputCapabilityOutbound.NATIVE_PART, projection.outbound)
        assertEquals(InputCapabilityHint.FIRST_ATTACH_ONCE, projection.hint)
        assertNull(projection.disabledReason)
    }

    private fun assertDisabled(projection: InputCapabilityProjection, reason: InputCapabilityDisabledReason) {
        assertFalse(projection.toString(), projection.visible)
        assertFalse(projection.toString(), projection.editable)
        assertEquals(InputCapabilityOutbound.PLACEHOLDER, projection.outbound)
        assertEquals(projection.toString(), reason, projection.disabledReason)
    }

    private companion object {
        val OPEN_ENVELOPE = AttachmentSupportInfo(image = true, nativeFile = true, textFileInline = true)
    }

    private fun JsonObject.string(name: String): String? = (this[name] as? JsonPrimitive)?.takeIf { it.isString }?.content
}
