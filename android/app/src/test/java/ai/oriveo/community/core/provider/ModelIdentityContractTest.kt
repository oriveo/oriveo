package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths

class ModelIdentityContractTest {

    @Serializable
    private data class ContractFile(
        val version: Int,
        val lookupCases: List<LookupCase> = emptyList(),
        val dedupeCases: List<DedupeCase> = emptyList(),
        val storedIdentifierCases: List<StoredIdentifierCase> = emptyList(),
        val sameRemoteCases: List<SameRemoteCase> = emptyList(),
    )

    @Serializable
    private data class LookupCase(
        val id: String,
        val providerKind: String,
        val query: String,
        val expectedCanonicalModelId: String? = null,
        val expectedModelId: String? = null,
        val models: List<ContractModel> = emptyList(),
    )

    @Serializable
    private data class DedupeCase(
        val id: String,
        val models: List<ContractModel> = emptyList(),
        val expectedModelIds: List<String> = emptyList(),
    )

    @Serializable
    private data class StoredIdentifierCase(
        val id: String,
        val providerKind: String,
        val model: ContractModel,
        val expectedStoredModelId: String,
    )

    @Serializable
    private data class SameRemoteCase(
        val id: String,
        val providerKind: String,
        val left: ContractModel,
        val right: ContractModel,
        val expected: Boolean,
    )

    @Serializable
    private data class ContractModel(
        val id: String,
        val name: String,
        val canonicalModelId: String? = null,
    )

    private val json = Json { ignoreUnknownKeys = true }

    private val contract: ContractFile by lazy {
        val path = contractCandidates()
            .firstOrNull { Files.exists(it) }
            ?.normalize()
            ?: error("model identity contract fixture not found")
        json.decodeFromString(path.toFile().readText())
    }

    @Test
    fun `contract fixture loads`() {
        assertEquals(1, contract.version)
        assertFalse(contract.lookupCases.isEmpty())
    }

    @Test
    fun `lookup cases stay aligned`() {
        contract.lookupCases.forEach { testCase ->
            val kind = providerKind(testCase.providerKind)
            val provider = makeProvider(kind, testCase.models)
            val resolved = ModelSelectionUtils.matchingModel(provider.allModels, testCase.query)

            assertEquals(
                "lookup ${testCase.id}",
                testCase.expectedModelId,
                resolved?.id,
            )
            assertEquals(
                "canonical ${testCase.id}",
                testCase.expectedCanonicalModelId,
                resolved?.canonicalModelId ?: resolved?.id,
            )
        }
    }

    @Test
    fun `dedupe cases stay aligned`() {
        contract.dedupeCases.forEach { testCase ->
            val deduped = ModelSelectionUtils.deduplicateByCanonical(testCase.models.map(::makeModel))
            assertEquals("dedupe ${testCase.id}", testCase.expectedModelIds, deduped.map { it.id })
        }
    }

    @Test
    fun `stored identifier cases stay aligned`() {
        contract.storedIdentifierCases.forEach { testCase ->
            val stored = ModelSelectionUtils.preferredStoredModelIdentifier(makeModel(testCase.model))
            assertEquals("stored ${testCase.id}", testCase.expectedStoredModelId, stored)
        }
    }

    @Test
    fun `same remote cases stay aligned`() {
        contract.sameRemoteCases.forEach { testCase ->
            val result = ModelSelectionUtils.modelsShareSameRemoteModel(
                makeModel(testCase.left),
                makeModel(testCase.right),
                providerKind(testCase.providerKind),
            )
            assertEquals("same remote ${testCase.id}", testCase.expected, result)
        }
    }

    private fun providerKind(raw: String): ProviderKind =
        ProviderKind.fromRawValue(raw) ?: error("unknown provider kind: $raw")

    private fun makeModel(model: ContractModel): AIModel =
        AIModel(
            id = model.id,
            name = model.name,
            canonicalModelId = model.canonicalModelId,
            capabilities = listOf(ModelCapability.Text),
            isAvailable = true,
        )

    private fun makeProvider(kind: ProviderKind, models: List<ContractModel>): Provider {
        val resolved = models.map(::makeModel)
        return Provider(
            id = "provider-contract",
            kind = kind,
            models = resolved,
            catalogModels = resolved,
        )
    }

    private fun contractCandidates(): List<Path> {
        val cwd = Paths.get("").toAbsolutePath().normalize()
        return generateSequence(cwd) { current -> current.parent }
            .take(8)
            .map { current -> current.resolve("shared/model-contracts/model_identity_contract.v1.json") }
            .toList()
    }
}
