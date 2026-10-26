package ai.oriveo.community.core.capability

import ai.oriveo.community.core.capability.truth.resolveInputCapabilityProjections
import ai.oriveo.community.core.data.mapper.ProviderMapper
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.AttachmentSupportInfo
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RELAY_MODEL_FIELDS
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade.InputCapabilityDisabledReason
import ai.oriveo.community.feature.providers.detail.RelayAdvancedCapability
import ai.oriveo.community.feature.providers.detail.RelayModelAdvancedEdits
import ai.oriveo.community.core.provider.relay.RelayNegativeCache
import java.time.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Persistence of Relay input-capability delta overrides: the delta is produced by the production write entry
 * [RelayModelAdvancedEdits.settingCapabilityOverride], survives a round trip through local storage, and the
 * decision is read from the model.
 */
class CapabilityOverridesPersistenceTest {
    private val now: Instant = Instant.parse("2026-10-19T00:00:00Z")
    private val cache = InputNegativeCache(InputNegativeCache.MemoryStore()) { now.epochSecond }

    private fun provider(model: AIModel) = Provider(
        id = "relay-input",
        kind = ProviderKind.Relay,
        baseUrlText = "https://api.myrelay.dev",
        relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
        models = listOf(model),
    )

    /** The provider after the production write entry turns image input on. */
    private fun visionAdded(): Provider {
        val model = AIModel(id = "relay-model", name = "relay-model", capabilities = listOf(ModelCapability.Image))
        return RelayModelAdvancedEdits.settingCapabilityOverride(
            provider(model),
            "relay-model",
            RelayAdvancedCapability.Image,
            true,
            RelayNegativeCache(RelayNegativeCache.MemoryStore()),
            now,
        )
    }

    @Test
    fun `AIModel round trip keeps capabilityOverrides`() {
        val model = visionAdded().models.single()
        val stored = requireNotNull(model.capabilityOverrides)
        val entry = stored.jsonObject.getValue(CapabilityEvidenceFacade.VISION_INPUT).jsonObject
        assertEquals("add", entry.getValue("op").jsonPrimitive.content)
        assertEquals(now.toString(), entry.getValue("setAt").jsonPrimitive.content)
        assertEquals("unknown", entry.getValue("baseVerdict").jsonPrimitive.content)

        val json = Json { ignoreUnknownKeys = true }
        val decoded = json.decodeFromString(AIModel.serializer(), json.encodeToString(AIModel.serializer(), model))
        assertEquals(stored, decoded.capabilityOverrides)
        val restored = with(ProviderMapper) { provider(model).toEntity().toDomain() }
        assertEquals("local storage round trip", stored, restored.models.single().capabilityOverrides)
        assertFalse("device-local only, not part of the portable Relay field surface", "capabilityOverrides" in RELAY_MODEL_FIELDS)
    }

    @Test
    fun `projection reads stored add as editable and remove as user removed`() {
        val added = visionAdded()
        val vision = project(added).vision
        assertTrue(vision.visible)
        assertTrue(vision.editable)

        val removed = RelayModelAdvancedEdits.settingCapabilityOverride(
            added, "relay-model", RelayAdvancedCapability.Image, false, RelayNegativeCache(RelayNegativeCache.MemoryStore()), now,
        )
        val removedVision = project(removed).vision
        assertFalse(removedVision.editable)
        assertEquals(InputCapabilityDisabledReason.USER_REMOVED, removedVision.disabledReason)
    }

    private fun project(provider: Provider) = requireNotNull(
        resolveInputCapabilityProjections(
            provider = provider,
            model = provider.models.single(),
            relayIdentity = CapabilityEvidenceFacade.QueryIdentity(
                partitionId = "partition",
                connectionInstanceId = "relay-input",
                connectionGeneration = "1",
                credentialEpoch = "1",
                providerKind = ProviderKind.Relay.rawValue,
                authMode = ProviderAuthMode.ApiKey.rawValue,
                modelId = "relay-model",
                effectiveTransport = RelayTransport.OpenAIChatCompletions.value,
                endpointFingerprint = "fingerprint",
            ),
            relayAttachmentSupport = AttachmentSupportInfo(image = true, nativeFile = true, textFileInline = true),
            metadataClient = MetadataClient(),
            negativeCache = cache,
            now = now,
        ),
    )
}
