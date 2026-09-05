package ai.oriveo.community.core.data.remote

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import java.io.File
import java.net.HttpURLConnection
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MetadataLeanContractTest {
    @Test
    fun `shared lean fixture resolves parameter table and completes candidate identity`() {
        val root = Json.parseToJsonElement(contractFixture()).jsonObject
        val leanResponse = root.getValue("leanResponse").toString()
        val client = MetadataClient()

        client.loadNetworkPayloadForTesting(leanResponse, "etag-lean-fixture")

        val model = client.resolveCatalogModel("gpt-fixture", ProviderKind.OpenAI)
        assertNotNull(model)
        assertEquals(
            listOf("temperature", "top_p"),
            model!!.profiles.generation?.parameters?.mapNotNull { it.id },
        )
        assertEquals("sampling", model.profiles.generation?.parameters?.firstOrNull()?.group)
        assertEquals(setOf("tool_call"), model.capabilityEvidenceOwnedKeys)
        val candidate = model.capabilityEvidenceCandidates.orEmpty().single()
        assertEquals(ProviderKind.OpenAI.rawValue, candidate.providerKind)
        assertEquals("gpt-fixture", candidate.modelId)
        assertEquals("openai_chat_completions", candidate.transport)
        assertEquals("provider_model_transport", candidate.scope)
    }

    @Test
    fun `lean explicit identity conflict is rejected but safe key remains owned`() {
        val root = Json.parseToJsonElement(contractFixture()).jsonObject
        val polluted = root.getValue("leanResponse").toString()
            .replace(
                "\"grade\":\"machine_verified\"",
                "\"grade\":\"machine_verified\",\"providerKind\":\"wrong-provider\"",
            )
        val client = MetadataClient()

        client.loadNetworkPayloadForTesting(polluted, "etag-conflict")

        val model = client.resolveCatalogModel("gpt-fixture", ProviderKind.OpenAI)!!
        assertEquals(setOf("tool_call"), model.capabilityEvidenceOwnedKeys)
        assertTrue(model.capabilityEvidenceCandidates.orEmpty().isEmpty())
        assertFalse(model.capabilityEvidenceViewMalformed == true)
    }

    @Test
    fun `parametersRef is sole authority and full versus lean decisions stay equivalent`() {
        val definitions = """
          "profiles":{"generation":{
            "parameters":{"temperature":{"group":"sampling","valueSchema":"number"}},
            "templates":{"openai_chat_completions":{
              "transport":"openai_chat_completions","wire":{"temperature":"temperature"}
            }}
          }},
        """.trimIndent()
        val modelPrefix = """
          "providers":{"openAI":{"resolveMap":{"m":"m"},"models":{"m":{
            "canonicalModelId":"m","transport":"openai_chat_completions",
        """.trimIndent()
        val full = """
          {"version":2,$definitions$modelPrefix
            "profiles":{"generation":{"template":"openai_chat_completions","revision":"generation-r1",
              "parameters":[{"id":"temperature","support":"supported","source":"provider_metadata"}]}},
            "capabilityEvidenceView":{"schema":"capability-evidence-view/v1","candidates":[{
              "key":"generation_parameter/temperature","support":"supported",
              "source":"server_profile","grade":"effect_verified","scope":"provider_model_transport",
              "providerKind":"openAI","modelId":"m","transport":"openai_chat_completions",
              "generationRevision":"generation-r1"
            }]}
          }}}}}
        """.trimIndent()
        val lean = """
          {"version":2,"view":"lean",$definitions
            "generationParameterTables":{"sha256:matrix":[
              {"id":"temperature","support":"supported","source":"provider_metadata"}
            ]},$modelPrefix
            "profiles":{"generation":{"template":"openai_chat_completions","revision":"generation-r1",
              "parametersRef":"sha256:matrix",
              "parameters":[{"id":"top_p","support":"unsupported","source":"polluted_inline"}]}},
            "capabilityEvidenceView":{"candidates":[]}
          }}}}}
        """.trimIndent()
        val client = MetadataClient()
        val provider = Provider(id = "official-openai", kind = ProviderKind.OpenAI)
        val model = AIModel(id = "m", name = "m")
        val key = "generation_parameter/temperature"

        client.loadNetworkPayloadForTesting(full, "etag-full")
        val fullDecision = CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider = provider,
            model = model,
            keys = setOf(key),
            explicitKeys = setOf(key),
            finalTransport = "openai_chat_completions",
            metadataClient = client,
            now = 1_000,
        ).decision(key)!!

        client.loadNetworkPayloadForTesting(lean, "etag-lean")
        val resolvedIDs = client.resolveCatalogModel("m", ProviderKind.OpenAI)
            ?.profiles?.generation?.parameters?.mapNotNull { it.id }
        val leanDecision = CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider = provider,
            model = model,
            keys = setOf(key),
            explicitKeys = setOf(key),
            finalTransport = "openai_chat_completions",
            metadataClient = client,
            now = 1_000,
        ).decision(key)!!

        assertEquals(listOf("temperature"), resolvedIDs)
        assertEquals(fullDecision.resolution.support, leanDecision.resolution.support)
        assertEquals(fullDecision.resolution.requestPolicy, leanDecision.resolution.requestPolicy)
        assertEquals(fullDecision.visible, leanDecision.visible)
        assertEquals(fullDecision.editable, leanDecision.editable)
        assertEquals(fullDecision.permitsOutbound, leanDecision.permitsOutbound)

        client.loadNetworkPayloadForTesting(
            lean.replace("\"parametersRef\":\"sha256:matrix\"", "\"parametersRef\":\"\""),
            "etag-invalid-ref",
        )
        assertTrue(
            client.resolveCatalogModel("m", ProviderKind.OpenAI)
                ?.profiles?.generation?.parameters.orEmpty().isEmpty(),
        )
    }

    @Test
    fun `shared model facts fixture uses independent ETag and 304 while 404 is unavailable`() = runTest {
        val root = Json.parseToJsonElement(contractFixture()).jsonObject
        val responseBody = root.getValue("modelFactsResponse").toString()
        val validators = mutableListOf<String?>()
        val reports = mutableListOf<Map<String, String>>()
        val responses = ArrayDeque(
            listOf(
                MetadataTransportResponse(200, "facts-etag", responseBody, responseBody.length.toLong()),
                MetadataTransportResponse(304, null, null, 0),
                MetadataTransportResponse(HttpURLConnection.HTTP_NOT_FOUND, null, null, 0),
            ),
        )
        val client = MetadataClient(
            modelFactsTransport = ModelFactsTransport { validator ->
                validators += validator
                responses.removeFirst()
            },
            failureReporter = { reports += it },
        )
        client.loadNetworkPayloadForTesting(
            root.getValue("leanResponse").toString(),
            "metadata-etag",
        )

        client.fetchModelFactsForTesting()
        assertEquals(
            true,
            client.modelFacts(ProviderKind.OpenAI, "gpt-out-of-catalog")?.toolCall,
        )
        assertEquals("sha256:facts-fixture", client.modelFactsRevision())
        client.fetchModelFactsForTesting()
        client.fetchModelFactsForTesting()

        assertEquals(listOf(null, "facts-etag", "facts-etag"), validators)
        assertEquals(null, client.modelFactsRevision())
        assertEquals(null, client.modelFacts(ProviderKind.OpenAI, "gpt-out-of-catalog"))
        assertTrue(reports.isEmpty())
        assertFalse(client.encodedCachePayloadForTesting().orEmpty().contains("artifactHash"))
    }

    private fun contractFixture(): String {
        val path = generateSequence(File(System.getProperty("user.dir") ?: ".").absoluteFile) { it.parentFile }
            .map { File(it, "shared/model-contracts/metadata_lean_contract.v1.json") }
            .firstOrNull(File::exists)
            ?: error("metadata_lean_contract.v1.json not found")
        return path.readText(Charsets.UTF_8)
    }
}
