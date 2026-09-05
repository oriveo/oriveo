package ai.oriveo.community.feature.providers.detail

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverride
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import kotlinx.serialization.json.JsonNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GenerationParameterDefaultsProjectionTest {

    @Test
    fun `repository local identity yields editable Relay explicit parameter through UI projection`() {
        val projection = CapabilityEvidenceProductionAdapter.generationParameterUiProjection(
            provider = relayProvider(),
            model = relayModel(),
            localIdentity = repositoryLocalIdentity(),
            parameters = relayModel().generationProfile!!.parameters,
            values = explicitOmit(),
        )

        assertNotNull("a uniquely resolved Relay UI scope is required", projection.identity)
        assertTrue(
            "Omit is explicit intent and a scoped accepted declaration is editable",
            projection.decision("generation_parameter/temperature")?.editable == true,
        )
    }

    @Test
    fun `missing repository identity leaves Relay generation row read only`() {
        val projection = CapabilityEvidenceProductionAdapter.generationParameterUiProjection(
            provider = relayProvider(),
            model = relayModel(),
            localIdentity = null,
            parameters = relayModel().generationProfile!!.parameters,
            values = explicitOmit(),
        )

        assertFalse(
            "without the repository local identity UI scope is incomplete and must fail closed",
            projection.decision("generation_parameter/temperature")?.editable == true,
        )
    }

    private fun relayProvider() = Provider(
        id = "relay-1",
        kind = ProviderKind.Relay,
        baseUrlText = "https://relay.example/v1",
        relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
    )

    private fun relayModel() = AIModel(
        id = "relay-model",
        name = "Relay model",
        generationProfile = GenerationProfileRef(
            template = "openai_chat_completions",
            parameters = listOf(GenerationParameterRef(id = "temperature", support = "accepted_unverified")),
            wire = mapOf("temperature" to "temperature"),
        ),
    )

    private fun repositoryLocalIdentity() = CapabilityEvidenceIdentity(
        partitionId = "account-1",
        connectionInstanceId = "relay-1",
        connectionGeneration = "connection-1",
        credentialEpoch = "credential-1",
        providerKind = ProviderKind.Relay.rawValue,
        canonicalModelId = "relay-model",
        metadataRevision = "metadata-1",
        generationRevision = "generation-1",
    )

    private fun explicitOmit() = GenerationParameterOverrides(
        mapOf("temperature" to GenerationParameterOverride(GenerationOverrideState.Omit, JsonNull)),
    )
}
