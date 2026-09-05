package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RequestPreferenceResolver
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class ModelControlRuntimeIdentityTest {
    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        ModelControlRejectionCache.clearForTesting()
    }

    @Test
    fun `production metadata resolves four-field identity without generation template`() {
        val client = MetadataClient()
        val registry = workspaceFile(
            "shared/capabilityrecipe/capability_runtime.v1.json",
        ).readText().trim().removeSuffix("}") +
            ",\"revision\":\"runtime-r7\",\"generatedAt\":\"2026-08-14T00:00:00Z\"}"
        client.loadNetworkPayloadForTesting(
            """
            {"version":1,"capabilityRuntime":$registry,"providers":{"openAI":{
              "resolveMap":{"alias-model":"canonical/model"},"models":{"canonical/model":{
                "canonicalModelId":"canonical/model","transport":"openai_responses"
              }}
            }}}
            """.trimIndent(),
            "etag-r3-identity",
        )
        val provider = Provider(id = "CONNECTION-A", kind = ProviderKind.OpenAI)
        val model = AIModel(
            id = "alias-model",
            name = "Alias",
            // Deliberately unrelated to final transport. R3 identity must ignore this template.
            generationProfile = ai.oriveo.community.core.model.GenerationProfileRef(
                template = "legacy-template-that-must-not-be-identity",
                transport = "openai_chat_completions",
            ),
        )

        val identity = ModelControlRuntimeIdentityResolver.resolve(provider, model, client)
            ?: throw AssertionError("complete production metadata must resolve an identity")
        assertEquals("CONNECTION-A", identity.connectionId)
        assertEquals("canonical/model", identity.canonicalModelId)
        assertEquals("openai_responses", identity.finalTransport)
        assertEquals("runtime-r7", identity.runtimeRevision)
        assertEquals("r1.b3BlbmFpX3Jlc3BvbnNlcw.cnVudGltZS1yNw", identity.storageIdentity)
        assertEquals(
            "openai_responses" to "runtime-r7",
            ModelControlRuntimeIdentity.decodeStorageIdentity(identity.storageIdentity),
        )
    }

    @Test
    fun `missing or invalid runtime revision has no automatic identity`() {
        val client = MetadataClient()
        client.loadNetworkPayloadForTesting(
            """{"version":1,"providers":{"openAI":{"resolveMap":{"gpt":"gpt"},"models":{"gpt":{"canonicalModelId":"gpt","transport":"openai_responses"}}}}}""",
            "etag-no-runtime",
        )
        assertNull(
            ModelControlRuntimeIdentityResolver.resolve(
                Provider(id = "connection", kind = ProviderKind.OpenAI),
                AIModel(id = "gpt", name = "GPT"),
                client,
            ),
        )
    }

    @Test
    fun `negative cache is isolated by all runtime identity fields and owner`() {
        var persisted: String? = null
        ModelControlRejectionCache.configurePersistenceForTesting(
            read = { persisted },
            write = { persisted = it },
        )
        val base = ModelControlRuntimeIdentity(
            connectionId = "CONNECTION-A",
            canonicalModelId = "model/a",
            finalTransport = "openai_responses",
            runtimeRevision = "runtime-r7",
        )
        val now = System.currentTimeMillis()
        ModelControlRejectionCache.record(base, "web", "custom", "/web_search_options", nowMillis = now)
        assertTrue("negative evidence must be persisted", !persisted.isNullOrBlank())
        ModelControlRejectionCache.simulateColdStartForTesting()

        assertEquals(true, ModelControlRejectionCache.isRejected(base, "web", "custom", nowMillis = now + 1))
        assertEquals("custom rejection must not poison the official recipe", false, ModelControlRejectionCache.isRejected(base, "web", "provider_recipe", nowMillis = now + 1))
        assertEquals(false, ModelControlRejectionCache.isRejected(base, "reasoning", "custom", nowMillis = now + 1))
        assertEquals(false, ModelControlRejectionCache.isRejected(base.copy(connectionId = "CONNECTION-B"), "web", "custom", nowMillis = now + 1))
        assertEquals(false, ModelControlRejectionCache.isRejected(base.copy(canonicalModelId = "model/b"), "web", "custom", nowMillis = now + 1))
        assertEquals(false, ModelControlRejectionCache.isRejected(base.copy(finalTransport = "openai_chat_completions"), "web", "custom", nowMillis = now + 1))
        assertEquals(false, ModelControlRejectionCache.isRejected(base.copy(runtimeRevision = "runtime-r8"), "web", "custom", nowMillis = now + 1))
        ModelControlRejectionCache.record(
            base, "web", "provider_recipe", "/web_search_options",
            recipeRef = "fixture.exact.web.v1", nowMillis = now,
        )
        assertEquals(
            setOf("/web_search_options"),
            ModelControlRejectionCache.rejectedSettings(
                base, "web", "provider_recipe", recipeRef = "fixture.exact.web.v1", nowMillis = now + 1,
            ),
        )
        assertTrue(
            ModelControlRejectionCache.rejectedSettings(
                base, "web", "provider_recipe", recipeRef = "fixture.other.web.v1", nowMillis = now + 1,
            ).isEmpty(),
        )
        ModelControlRejectionCache.removeConnection("connection-a")
        assertFalse(ModelControlRejectionCache.isRejected(base, "web", "custom", nowMillis = now + 1))
        assertFalse(ModelControlRejectionCache.isRejected(base, "web", "provider_recipe", nowMillis = now + 1))
        ModelControlRejectionCache.record(base, "web", "custom", "/web_search_options", nowMillis = now)
        assertEquals(false, ModelControlRejectionCache.isRejected(base, "web", "custom", nowMillis = now + 86_400_001L))
    }

    @Test
    fun `shared R3 runtime fixture matches Android identity and explicit resend resolver`() {
        val fixture = Json.parseToJsonElement(
            workspaceFile("shared/model-contracts/model_control_runtime.v1.json").readText(),
        ).jsonObject
        assertEquals(RequestPreferenceResolver.SCOPE_PRIORITY, fixture.getValue("scopePriority").jsonArray.map { it.jsonPrimitive.content })
        assertEquals(
            listOf("connectionId", "canonicalModelId", "finalTransport", "runtimeRevision"),
            fixture.getValue("runtimeIdentity").jsonObject.getValue("requiredFields").jsonArray.map { it.jsonPrimitive.content },
        )

        fixture.getValue("identityIsolationCases").jsonArray.forEach { raw ->
            val case = raw.jsonObject
            val stored = identity(case.getValue("storedIdentity").jsonObject)
            val query = identity(case.getValue("queryIdentity").jsonObject)
            assertEquals(
                case.getValue("caseId").jsonPrimitive.content,
                case.getValue("expected").jsonObject.getValue("match").jsonPrimitive.boolean,
                stored == query,
            )
        }
        assertNull(ModelControlRuntimeIdentity.decodeStorageIdentity("openai_responses"))

        fixture.getValue("rejectionCases").jsonArray.forEach { raw ->
            val case = raw.jsonObject
            val expected = case.getValue("expected").jsonObject["action"]
                ?.jsonPrimitive?.contentOrNull ?: return@forEach
            val recipe = case["recipe"] as? JsonObject
            val recovery = case["errorRecoveryDefinition"] as? JsonObject
            val owner = recipe?.get("capability")?.jsonPrimitive?.content
                ?: case["locatedOwner"]?.jsonPrimitive?.content
            val pointers = (recovery?.get("locatorRules") as? JsonArray)
                ?.flatMap { rule -> rule.jsonObject["pointers"]!!.jsonArray.map { it.jsonPrimitive.content } }
                ?: (case["locatedPointers"] as? JsonArray)?.map { it.jsonPrimitive.content }.orEmpty()
            val result = RequestPreferenceResolver.resolveRetry(
                RequestPreferenceResolver.RetryIntent(
                    source = case.getValue("source").jsonPrimitive.content,
                    status = case.getValue("status").jsonPrimitive.int,
                    errorClass = "optional_parameter_rejected",
                    owner = owner,
                    locatedPointers = pointers,
                    preToken = case.getValue("preFirstEvent").jsonPrimitive.boolean,
                    streamStarted = case.getValue("streamStarted").jsonPrimitive.boolean,
                    sideEffects = case.getValue("sideEffects").jsonPrimitive.boolean,
                    automaticRetryCount = 0,
                ),
            )
            assertFalse(case.getValue("caseId").jsonPrimitive.content, result.retry)
            assertEquals(case.getValue("caseId").jsonPrimitive.content, expected, result.action)
        }

        val lifecycleIds = fixture.getValue("lifecycleCases").jsonArray
            .map { it.jsonObject.getValue("caseId").jsonPrimitive.content }
            .toSet()
        assertTrue("legacy lifecycle fixture missing", "legacy_upgrade_missing_runtime_identity" in lifecycleIds)
        assertTrue("cold start fixture missing", "cold_start_restores_latest_lww_winner" in lifecycleIds)
        assertTrue("Skill/Agent fixture missing", "skill_agent_uses_same_runtime_identity" in lifecycleIds)
        assertTrue("background interruption fixture missing", "background_interrupt_does_not_learn" in lifecycleIds)
        assertTrue("delete lifecycle fixture missing", "connection_delete_tombstones_all_identity_variants" in lifecycleIds)
    }

    private fun identity(value: JsonObject) = ModelControlRuntimeIdentity(
        connectionId = value.getValue("connectionId").jsonPrimitive.content,
        canonicalModelId = value.getValue("canonicalModelId").jsonPrimitive.content,
        finalTransport = value.getValue("finalTransport").jsonPrimitive.content,
        runtimeRevision = value.getValue("runtimeRevision").jsonPrimitive.content,
    )

    private fun workspaceFile(relativePath: String): File = generateSequence(
        File(System.getProperty("user.dir") ?: ".").absoluteFile,
    ) { it.parentFile }
        .map { File(it, relativePath) }
        .firstOrNull { it.isFile }
        ?: error("workspace file missing: $relativePath")
}
