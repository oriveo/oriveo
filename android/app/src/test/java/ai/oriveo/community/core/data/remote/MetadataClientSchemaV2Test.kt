package ai.oriveo.community.core.data.remote

import android.content.Context
import ai.oriveo.community.core.data.dao.MetadataCacheDao
import ai.oriveo.community.core.data.entity.MetadataCacheEntity
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.testing.TestSharedPreferences
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.util.zip.GZIPInputStream

/** The shared schema 2 validator: gives the same verdicts as Web on the shared fixtures, and is wired into the client through the split fetch path. */
@OptIn(ExperimentalCoroutinesApi::class)
class MetadataClientSchemaV2Test {

    private val schemaJson: JsonElement =
        Json.parseToJsonElement(workspaceFile("shared/model-contracts/metadata_payload.v2.schema.json").readText())
    private val validator = MetadataPayloadSchemaValidator(schemaJson)

    @Test
    fun catalogCasesMatchSharedExpectations() {
        val cases = Json.parseToJsonElement(
            workspaceFile("shared/model-contracts/metadata_payload.v2.cases.json").readText(),
        ).jsonObject.getValue("catalogCases").jsonArray
        assertTrue("the shared fixture catalogCases must not be empty", cases.isNotEmpty())
        cases.forEach { element ->
            val case = element.jsonObject
            val name = case.getValue("name").jsonPrimitive.content
            val expect = case.getValue("expect").jsonObject
            val result = validator.decode(case.getValue("data").jsonObject)
            when (expect.getValue("envelope").jsonPrimitive.content) {
                "reject" -> assertNotNull("$name: the envelope should be rejected", result.envelopeError)
                "accept" -> {
                    assertNull("$name: the envelope should be accepted, got ${result.envelopeError}", result.envelopeError)
                    assertEquals(
                        "$name: keptModels",
                        expect.getValue("keptModels").jsonArray.map { it.jsonPrimitive.content },
                        result.keptModels,
                    )
                    assertEquals(
                        "$name: droppedModels",
                        expect.getValue("droppedModels").jsonArray.map { it.jsonPrimitive.content },
                        result.droppedModels.map { it.modelId },
                    )
                }
                else -> fail("$name: unknown envelope expectation")
            }
        }
    }

    @Test
    fun droppedModelReportsInstancePathAndKeyword() {
        val case = Json.parseToJsonElement(
            workspaceFile("shared/model-contracts/metadata_payload.v2.cases.json").readText(),
        ).jsonObject.getValue("catalogCases").jsonArray
            .map { it.jsonObject }
            .first { it.getValue("name").jsonPrimitive.content == "bad_verdict_state_drops_only_that_model" }
        val result = validator.decode(case.getValue("data").jsonObject)
        assertEquals(
            MetadataPayloadSchemaValidator.SchemaError("/capabilityControls/vision_input/state", "enum"),
            result.droppedModels.single().error,
        )
        assertEquals(result.droppedModels.single().error, result.firstError)
    }

    @Test
    fun bundledPayloadPassesEveryProviderAndModel() {
        val text = GZIPInputStream(
            workspaceFile("shared/model-contracts/bundled-metadata.v2.json.gz").inputStream(),
        ).bufferedReader().use { it.readText() }
        val data = Json.parseToJsonElement(text).jsonObject
        val result = validator.decode(data)
        assertNull("bundled envelope: ${result.envelopeError}", result.envelopeError)
        assertEquals("bundled drops no provider", emptyList<Any>(), result.droppedProviders)
        assertEquals("bundled drops no model", emptyList<Any>(), result.droppedModels)
        val providers = data.getValue("providers").jsonObject
        val expectedModelCount = providers.values.sumOf { (it.jsonObject["models"] as? JsonObject)?.size ?: 0 }
        assertTrue("bundled should carry models", expectedModelCount > 0)
        assertEquals(expectedModelCount, result.keptModels.size)
    }

    @Test
    fun unknownKeywordFailsConstruction() {
        val root = schemaJson.jsonObject
        val defs = root.getValue("\$defs").jsonObject
        val model = defs.getValue("model").jsonObject
        val mutated = JsonObject(
            root + ("\$defs" to JsonObject(defs + ("model" to JsonObject(model + ("maxProperties" to JsonPrimitive(3)))))),
        )
        try {
            MetadataPayloadSchemaValidator(mutated)
            fail("a schema with the unknown keyword maxProperties should throw at construction")
        } catch (e: IllegalArgumentException) {
            assertTrue(e.message.orEmpty(), e.message.orEmpty().contains("maxProperties"))
        }
    }

    @Test
    fun `minItems regionPricing empty array is rejected and one entry passes`() {
        // The real contract schema (regionPricing carries minItems: 1) constructs without throwing: the class-field validator is already built from it.
        val entry = """{"regionScope":"global","currencyCode":"USD","pricingStatus":"unknown","pricingUnit":"per_token","pricing":null}"""
        val empty = Json.parseToJsonElement("""{"displayName":"M","regionPricing":[]}""")
        assertEquals(
            MetadataPayloadSchemaValidator.SchemaError("/regionPricing", "minItems"),
            validator.validateModel(empty),
        )
        val one = Json.parseToJsonElement("""{"displayName":"M","regionPricing":[$entry]}""")
        assertNull(validator.validateModel(one))
    }

    @Test
    fun negativeMinItemsFailsConstruction() {
        try {
            MetadataPayloadSchemaValidator(Json.parseToJsonElement("""{"minItems":-1,"${'$'}defs":{"provider":{},"model":{}}}"""))
            fail("a negative minItems should throw at construction")
        } catch (e: IllegalArgumentException) {
            assertTrue(e.message.orEmpty(), e.message.orEmpty().contains("minItems"))
        }
    }

    // -- Client wiring: the split fetch path (fake transport modeled on MetadataCatalogSplitTest) --

    @Test
    fun `schema 2 catalog drops only the bad model and reports model_entry_invalid`() = runTest {
        val server = FakeSplitServer(splitFixture())
        server.editCatalog("openAI") { data -> withBadModel(asSchemaV2(data), BAD_MODEL) }
        val reports = mutableListOf<Map<String, String>>()
        val client = newClient(server, reports)

        client.initialize(context())

        assertNotNull(client.resolveCatalogModel(GOOD_MODEL, ProviderKind.OpenAI))
        assertNull(client.resolveCatalogModel(BAD_MODEL, ProviderKind.OpenAI))
        assertEquals(listOf(GOOD_MODEL), client.providerModelIds(ProviderKind.OpenAI))
        assertEquals(MetadataClient.CatalogLoadState.Loaded, client.catalogLoadState(ProviderKind.OpenAI))
        val report = reports.single()
        assertEquals("model_entry_invalid", report["reason"])
        assertEquals("openai", report["provider_kind"])
        assertEquals(BAD_MODEL, report["model_id"])
        assertEquals("", report["instance_path"])
        assertEquals("required", report["keyword"])
        assertEquals("catalog_decode", report["phase"])
        // Carries only the location and keyword, never any value.
        assertTrue(report.values.none { it.contains("Bad Display") })
    }

    @Test
    fun `schema 2 catalog with a bad envelope keeps the previous catalog`() = runTest {
        val server = FakeSplitServer(splitFixture())
        server.editCatalog("openAI") { data -> asSchemaV2(data) }
        val reports = mutableListOf<Map<String, String>>()
        val client = newClient(server, reports)
        client.initialize(context())
        val lastGood = client.resolveCatalogModel(BAD_MODEL, ProviderKind.OpenAI)
        assertNotNull(lastGood)
        assertTrue(reports.isEmpty())

        // A new-generation catalog: every model renamed, but the envelope lacks metadataRevision -> the whole catalog is rejected.
        server.editCatalog("openAI", newRevision = "sha256:" + "b".repeat(64)) { data ->
            val models = data.getValue("models").jsonObject.mapValues { (_, raw) ->
                JsonObject(raw.jsonObject + ("displayName" to JsonPrimitive("Renamed")))
            }
            JsonObject(data + ("models" to JsonObject(models)) - "metadataRevision")
        }
        client.refresh()

        assertEquals(lastGood?.displayName, client.resolveCatalogModel(BAD_MODEL, ProviderKind.OpenAI)?.displayName)
        assertEquals(listOf(BAD_MODEL, GOOD_MODEL).sorted(), client.providerModelIds(ProviderKind.OpenAI).sorted())
        assertEquals("catalog_decode", reports.single()["phase"])
        assertNull(reports.single()["reason"])
    }

    @Test
    fun `schema 1 catalog is not validated`() = runTest {
        val server = FakeSplitServer(splitFixture())
        // Without metadataSchema: entries are adopted the old way even if they would be invalid under schema 2.
        server.editCatalog("openAI") { data -> withBadModel(data, BAD_MODEL) }
        val client = newClient(server, mutableListOf())

        client.initialize(context())

        assertNotNull(client.resolveCatalogModel(BAD_MODEL, ProviderKind.OpenAI))
    }

    @Test
    fun `schema 2 index with a bad envelope is not adopted`() = runTest {
        val server = FakeSplitServer(splitFixture())
        server.editIndex { data -> JsonObject(data + ("metadataSchema" to JsonPrimitive(2))) }
        val reports = mutableListOf<Map<String, String>>()
        val client = newClient(server, reports)

        client.initialize(context())

        assertTrue(server.catalogCalls.isEmpty())
        assertNull(client.resolveCatalogModel(GOOD_MODEL, ProviderKind.OpenAI))
        assertEquals("index_decode", reports.single()["phase"])
    }

    @Test
    fun `schema 2 index drops only the bad provider`() = runTest {
        val server = FakeSplitServer(splitFixture())
        server.editIndex { data ->
            val providers = data.getValue("providers").jsonObject
            val anthropic = JsonObject(providers.getValue("anthropic").jsonObject - "displayName")
            JsonObject(asSchemaV2(data) + ("providers" to JsonObject(providers + ("anthropic" to anthropic))))
        }
        val reports = mutableListOf<Map<String, String>>()
        val client = newClient(server, reports, ProviderKind.OpenAI, ProviderKind.Anthropic)

        client.initialize(context())

        assertNotNull(client.resolveCatalogModel(GOOD_MODEL, ProviderKind.OpenAI))
        assertEquals(listOf("openAI"), server.catalogCalls.map { it.first })
        val report = reports.single()
        // Same criteria as Web: a bad provider is dropped whole, reported with the same code and without model_id.
        assertEquals("model_entry_invalid", report["reason"])
        assertEquals("anthropic", report["provider_kind"])
        assertFalse(report.containsKey("model_id"))
        assertEquals("required", report["keyword"])
    }

    @Test
    fun `real contract index as schema 2 is adopted through the production decode path`() = runTest {
        val server = FakeSplitServer(splitFixture())
        server.editIndex { data -> asSchemaV2(data) }
        val reports = mutableListOf<Map<String, String>>()
        val client = newClient(server, reports, ProviderKind.OpenAI, ProviderKind.Anthropic)

        client.initialize(context())

        assertTrue(reports.toString(), reports.isEmpty())
        assertEquals(listOf("anthropic", "openAI"), server.catalogCalls.map { it.first }.sorted())
        assertNotNull(client.resolveCatalogModel(GOOD_MODEL, ProviderKind.OpenAI))
    }

    // -- Aligned with the Web criteria --

    @Test
    fun `catalog cases through the split production path keep and drop the same models`() {
        sharedCatalogCases().forEach { case ->
            val name = case.getValue("name").jsonPrimitive.content
            val expect = case.getValue("expect").jsonObject
            val data = case.getValue("data").jsonObject
            runTest {
                val server = FakeSplitServer(splitFixture())
                val revision = data.getValue("catalogRevision").jsonPrimitive.content
                server.editCatalog("openAI", newRevision = revision) {
                    JsonObject(data + ("provider" to JsonPrimitive("openAI")))
                }
                val reports = mutableListOf<Map<String, String>>()
                val client = newClient(server, reports)

                client.initialize(context())

                when (expect.getValue("envelope").jsonPrimitive.content) {
                    "reject" -> {
                        assertTrue("$name: no models expected after rejection", client.providerModelIds(ProviderKind.OpenAI).isEmpty())
                        assertEquals("$name", "catalog_decode", reports.single()["phase"])
                        assertNull("$name", reports.single()["reason"])
                    }
                    "accept" -> {
                        val kept = expect.getValue("keptModels").jsonArray.map { it.jsonPrimitive.content }
                        val dropped = expect.getValue("droppedModels").jsonArray.map { it.jsonPrimitive.content }
                        assertEquals("$name: production path kept", kept.sorted(), client.providerModelIds(ProviderKind.OpenAI).sorted())
                        assertEquals(
                            "$name: production path dropped report",
                            dropped.sorted(),
                            reports.filter { it["reason"] == "model_entry_invalid" }.mapNotNull { it["model_id"] }.sorted(),
                        )
                        assertEquals("$name", MetadataClient.CatalogLoadState.Loaded, client.catalogLoadState(ProviderKind.OpenAI))
                    }
                    else -> fail("$name: unknown envelope expectation")
                }
            }
        }
    }

    @Test
    fun `date-time format follows ajv-formats full`() {
        val base = sharedCatalogCases().first { it.getValue("name").jsonPrimitive.content == "valid_models_all_kept" }
            .getValue("data").jsonObject
        fun envelopeError(generatedAt: String) =
            validator.decode(JsonObject(base + ("generatedAt" to JsonPrimitive(generatedAt)))).envelopeError
        // data sits under a oneOf branch: the first error lands on /data + oneOf, so only the rejection is asserted.
        assertNotNull("missing seconds should be rejected", envelopeError("2026-10-19T00:00Z"))
        assertNull(envelopeError("2026-10-19 00:00:00Z"))
        assertNull(envelopeError("2026-10-19T00:00:00+0800"))
        assertNull(envelopeError("2026-12-31T23:59:60Z"))
        assertNull(envelopeError("2026-10-19t00:00:00.123z"))
        assertNotNull("a nonexistent date should be rejected", envelopeError("2026-02-30T00:00:00Z"))
        // The following align with ajv-formats 3.0.1 getDateTime(true) (the rule the Web generator actually uses).
        assertNotNull("hour 29 should be rejected", envelopeError("2026-10-19T29:00:00Z"))
        assertNotNull("a missing time zone should be rejected", envelopeError("2026-10-19T00:00:00"))
        assertNotNull("a time zone hour > 23 should be rejected", envelopeError("2026-10-19T00:00:00+24:00"))
        assertNotNull("a leap second not at UTC 23:59 should be rejected", envelopeError("2026-12-31T23:59:60+01:00"))
        assertNull("a leap second that converts to UTC 23:59 should be accepted", envelopeError("2027-01-01T00:59:60+01:00"))
    }

    @Test
    fun `pattern dollar matches only at the end of the string`() {
        val base = sharedCatalogCases().first { it.getValue("name").jsonPrimitive.content == "valid_models_all_kept" }
            .getValue("data").jsonObject
        val result = validator.decode(
            JsonObject(base + ("catalogRevision" to JsonPrimitive("sha256:" + "0".repeat(64) + "\n"))),
        )
        assertNotNull("a value with a trailing newline should be rejected", result.envelopeError)
        assertNull(validator.decode(base).envelopeError)
    }

    @Test
    fun `unknown fooRef field does not drop the model`() = runTest {
        val server = FakeSplitServer(splitFixture())
        server.editCatalog("openAI") { data -> editModel(asSchemaV2(data), GOOD_MODEL) { it + ("fooRef" to JsonPrimitive("nowhere")) } }
        val reports = mutableListOf<Map<String, String>>()
        val client = newClient(server, reports)

        client.initialize(context())

        assertNotNull(client.resolveCatalogModel(GOOD_MODEL, ProviderKind.OpenAI))
        assertEquals(listOf(BAD_MODEL, GOOD_MODEL).sorted(), client.providerModelIds(ProviderKind.OpenAI).sorted())
        assertTrue(reports.toString(), reports.isEmpty())
    }

    @Test
    fun `unresolved ref drops only that model and reports unresolved_ref`() = runTest {
        val server = FakeSplitServer(splitFixture())
        server.editCatalog("openAI") { data ->
            editModel(asSchemaV2(data), BAD_MODEL) { it + ("capabilityControlsRef" to JsonPrimitive("missing")) }
        }
        val reports = mutableListOf<Map<String, String>>()
        val client = newClient(server, reports)

        client.initialize(context())

        assertNull(client.resolveCatalogModel(BAD_MODEL, ProviderKind.OpenAI))
        assertEquals(listOf(GOOD_MODEL), client.providerModelIds(ProviderKind.OpenAI))
        val report = reports.single()
        assertEquals("model_entry_invalid", report["reason"])
        assertEquals(BAD_MODEL, report["model_id"])
        assertEquals("/capabilityControlsRef", report["instance_path"])
        assertEquals("unresolved_ref", report["keyword"])
    }

    @Test
    fun `provider whose models is not an object is dropped with models type`() = runTest {
        val server = FakeSplitServer(splitFixture())
        server.editIndex { data ->
            val providers = data.getValue("providers").jsonObject
            val anthropic = JsonObject(providers.getValue("anthropic").jsonObject + ("models" to JsonPrimitive("x")))
            JsonObject(asSchemaV2(data) + ("providers" to JsonObject(providers + ("anthropic" to anthropic))))
        }
        val reports = mutableListOf<Map<String, String>>()
        val client = newClient(server, reports, ProviderKind.OpenAI, ProviderKind.Anthropic)

        client.initialize(context())

        assertEquals(listOf("openAI"), server.catalogCalls.map { it.first })
        val report = reports.single()
        assertEquals("model_entry_invalid", report["reason"])
        assertEquals("anthropic", report["provider_kind"])
        assertEquals("/models", report["instance_path"])
        assertEquals("type", report["keyword"])
    }

    @Test
    fun `unresolved parametersRef drops only that model`() = runTest {
        val server = FakeSplitServer(splitFixture())
        server.editCatalog("openAI") { raw ->
            val data = asSchemaV2(raw)
            val tables = data.getValue("tables").jsonObject
            val profiles = tables.getValue("profiles").jsonObject
            val lost = Json.parseToJsonElement("""{"generation":{"parametersRef":"missing-params"}}""")
            val withTable = JsonObject(
                data + ("tables" to JsonObject(tables + ("profiles" to JsonObject(profiles + ("lost-params" to lost))))),
            )
            editModel(withTable, BAD_MODEL) { it + ("profilesRef" to JsonPrimitive("lost-params")) }
        }
        val client = newClient(server, mutableListOf())

        client.initialize(context())

        assertNull(client.resolveCatalogModel(BAD_MODEL, ProviderKind.OpenAI))
        assertNotNull(client.resolveCatalogModel(GOOD_MODEL, ProviderKind.OpenAI))
        assertEquals(listOf(GOOD_MODEL), client.providerModelIds(ProviderKind.OpenAI))
        assertEquals(MetadataClient.CatalogLoadState.Loaded, client.catalogLoadState(ProviderKind.OpenAI))
    }

    @Test
    fun `resolveMap is pruned by target only`() {
        val data = Json.parseToJsonElement(
            """{"models":{"a":{},"b":{}},"resolveMap":{"b":"a","alias-b":"b","alias-a":"a"}}""",
        ).jsonObject
        val pruned = MetadataCatalogAssembly.withoutModels(data, setOf("b"))
        assertEquals(
            Json.parseToJsonElement("""{"b":"a","alias-a":"a"}"""),
            pruned.getValue("resolveMap"),
        )
    }

    @Test
    fun `promptCache survives the Room round trip`() = runTest {
        val promptCache = Json.parseToJsonElement("""{"policyRef":"anthropic.explicit"}""")
        val server = FakeSplitServer(splitFixture())
        server.editCatalog("openAI") { data -> editModel(asSchemaV2(data), GOOD_MODEL) { it + ("promptCache" to promptCache) } }
        val dao = FakeRowDao()
        val writer = newClient(server, mutableListOf(), dao = dao)
        writer.initialize(context())
        assertTrue("should be written to Room", dao.rows.isNotEmpty())
        assertEquals("anthropic.explicit", writer.resolveCatalogModel(GOOD_MODEL, ProviderKind.OpenAI)?.promptCachePolicyRef)

        // Cold start: the new instance reads back from the same Room; with an unchanged server ETag the answer is always 304 and brings no new content.
        val reader = newClient(server, mutableListOf(), dao = dao)
        reader.initialize(context())
        advanceUntilIdle()

        assertEquals("anthropic.explicit", reader.resolveCatalogModel(GOOD_MODEL, ProviderKind.OpenAI)?.promptCachePolicyRef)
        // BAD_MODEL in the corpus carries its own promptCache (openai.chat.automatic), which is read back as is after a cold start.
        assertEquals("openai.chat.automatic", reader.resolveCatalogModel(BAD_MODEL, ProviderKind.OpenAI)?.promptCachePolicyRef)
        val model = Json.parseToJsonElement(requireNotNull(reader.encodedCachePayloadForTesting()))
            .jsonObject.getValue("data").jsonObject.getValue("providers").jsonObject.getValue("openAI").jsonObject
            .getValue("models").jsonObject.getValue(GOOD_MODEL).jsonObject
        assertEquals(promptCache, model.getValue("promptCache"))
    }

    private fun sharedCatalogCases(): List<JsonObject> = Json.parseToJsonElement(
        workspaceFile("shared/model-contracts/metadata_payload.v2.cases.json").readText(),
    ).jsonObject.getValue("catalogCases").jsonArray.map { it.jsonObject }

    private fun editModel(data: JsonObject, modelId: String, edit: (JsonObject) -> Map<String, JsonElement>): JsonObject {
        val models = data.getValue("models").jsonObject
        val edited = JsonObject(edit(models.getValue(modelId).jsonObject))
        return JsonObject(data + ("models" to JsonObject(models + (modelId to edited))))
    }

    private fun asSchemaV2(data: JsonObject): JsonObject = JsonObject(
        data + mapOf(
            "metadataSchema" to JsonPrimitive(2),
            "metadataRevision" to JsonPrimitive(7),
            "generatedAt" to JsonPrimitive("2026-10-19T00:00:00Z"),
        ),
    )

    /** Removes displayName (required by $defs/model) and leaves a value that appears only in the bad entry for the "carries no value" assertion. */
    private fun withBadModel(data: JsonObject, modelId: String): JsonObject {
        val models = data.getValue("models").jsonObject
        val bad = JsonObject(models.getValue(modelId).jsonObject - "displayName" + ("tagline" to JsonPrimitive("Bad Display")))
        return JsonObject(data + ("models" to JsonObject(models + (modelId to bad))))
    }

    private fun TestScope.newClient(
        server: FakeSplitServer,
        reports: MutableList<Map<String, String>>,
        vararg kinds: ProviderKind = arrayOf(ProviderKind.OpenAI),
        dao: MetadataCacheDao = FakeRowDao(),
    ): MetadataClient = MetadataClient(
        backgroundScope = this,
        ioDispatcher = StandardTestDispatcher(testScheduler),
        metadataCacheDao = dao,
        metadataTransport = MetadataTransport { error("lean must not be requested") },
        metadataSplitTransport = server,
        nowMillis = { 1_000L },
        failureReporter = { tags -> reports.add(tags) },
        metadataPayloadSchemaText = schemaJson.toString(),
        // This class only tests fetching and decoding; the bundled snapshot fallback is covered by BundledMetadataTest, so it is switched off here to keep the mock Context from reading the asset and reporting one extra failure.
        bundledFallbackEnabled = false,
    ).also { client ->
        client.catalogDemandSupplier = { MetadataClient.CatalogDemand(kinds.toSet(), hasRelay = false) }
    }

    private fun context(): Context {
        val context = mockk<Context>()
        every { context.applicationContext } returns context
        every { context.getSharedPreferences(any(), Context.MODE_PRIVATE) } returns TestSharedPreferences()
        return context
    }

    private fun splitFixture(): JsonObject =
        Json.parseToJsonElement(workspaceFile("shared/model-contracts/metadata_catalog_contract.v1.json").readText())
            .jsonObject

    /** Server double (modeled on MetadataCatalogSplitTest.FakeSplitServer): index and catalog each carry an ETag and a match returns 304. */
    private class FakeSplitServer(root: JsonObject) : MetadataSplitTransport {
        private var index: JsonObject = root.getValue("indexResponse").jsonObject
        private val catalogs: MutableMap<String, JsonObject> = root.getValue("catalogResponses").jsonObject
            .mapValues { (_, value) -> value.jsonObject.getValue("data").jsonObject }
            .toMutableMap()
        private var indexGeneration = 0
        val catalogCalls = mutableListOf<Pair<String, String?>>()

        private fun indexETag() = "\"index-$indexGeneration\""
        private fun catalogETag(key: String) = "\"catalog-$key-${revisionOf(catalogs.getValue(key))}\""
        private fun revisionOf(data: JsonObject) = (data.getValue("catalogRevision") as JsonPrimitive).content

        override suspend fun fetchIndex(ifNoneMatch: String?, cacheBust: String?): MetadataTransportResponse {
            if (ifNoneMatch == indexETag()) return MetadataTransportResponse(304, indexETag(), null, 0)
            val body = index.toString()
            return MetadataTransportResponse(200, indexETag(), body, body.length.toLong())
        }

        override suspend fun fetchCatalog(provider: String, ifNoneMatch: String?, revision: String?): MetadataTransportResponse {
            catalogCalls += provider to ifNoneMatch
            val data = catalogs[provider] ?: return MetadataTransportResponse(404, null, null, 0)
            val eTag = catalogETag(provider)
            if (ifNoneMatch == eTag) return MetadataTransportResponse(304, eTag, null, 0)
            val body = JsonObject(mapOf("code" to JsonPrimitive(0), "data" to data, "message" to JsonPrimitive("ok"))).toString()
            return MetadataTransportResponse(200, eTag, body, body.length.toLong())
        }

        /** Edits the catalog; when [newRevision] is given the catalog and the revision registered in the index change together (one snapshot generation change). */
        fun editCatalog(key: String, newRevision: String? = null, edit: (JsonObject) -> JsonObject) {
            var data = edit(catalogs.getValue(key))
            if (newRevision != null) {
                data = JsonObject(data + ("catalogRevision" to JsonPrimitive(newRevision)))
                editIndex { index ->
                    val providers = index.getValue("providers").jsonObject
                    val provider = providers.getValue(key).jsonObject
                    JsonObject(
                        index + ("providers" to JsonObject(providers + (key to JsonObject(provider + ("catalogRevision" to JsonPrimitive(newRevision)))))),
                    )
                }
            }
            catalogs[key] = data
        }

        fun editIndex(edit: (JsonObject) -> JsonObject) {
            val data = index.getValue("data").jsonObject
            index = JsonObject(index + ("data" to edit(data)))
            indexGeneration += 1
        }
    }

    /** Multi-row Room double (modeled on MetadataCatalogSplitTest.FakeRowDao). */
    private class FakeRowDao : MetadataCacheDao {
        val rows = linkedMapOf<String, MetadataCacheEntity>()

        override suspend fun payloadLength(key: String): Int? =
            rows[key]?.payload?.let { it.codePointCount(0, it.length) }

        override suspend fun payloadChunk(start: Int, count: Int, key: String): String? {
            val payload = rows[key]?.payload ?: return null
            val total = payload.codePointCount(0, payload.length)
            val startIndex = (start - 1).coerceIn(0, total)
            val endIndex = (startIndex + count).coerceAtMost(total)
            return payload.substring(
                payload.offsetByCodePoints(0, startIndex),
                payload.offsetByCodePoints(0, endIndex),
            )
        }

        override suspend fun upsert(entity: MetadataCacheEntity) {
            rows[entity.key] = entity
        }

        override suspend fun updatedAtMs(key: String): Long? = rows[key]?.updatedAtMs

        override suspend fun touch(key: String, updatedAtMs: Long): Int {
            val row = rows[key] ?: return 0
            rows[key] = row.copy(updatedAtMs = updatedAtMs)
            return 1
        }

        override suspend fun delete(key: String) {
            rows.remove(key)
        }

        override suspend fun deleteAllExcept(keep: String) {
            rows.keys.retainAll { it == keep }
        }

        override suspend fun clear() {
            rows.clear()
        }
    }

    private companion object {
        /** Two models from the corpus openAI catalog. */
        const val GOOD_MODEL = "chat-latest"
        const val BAD_MODEL = "gpt-3.5-turbo"
    }

    /** Walks up from the working directory to find a path relative to the repository root (modeled on MetadataTestFixtures.workspaceFile). */
    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("$relative not found")
    }
}
