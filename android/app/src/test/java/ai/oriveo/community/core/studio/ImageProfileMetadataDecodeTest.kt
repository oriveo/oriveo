package ai.oriveo.community.core.studio

import android.content.Context
import android.content.SharedPreferences
import ai.oriveo.community.core.data.dao.MetadataCacheDao
import ai.oriveo.community.core.data.entity.MetadataCacheEntity
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.remote.MetadataSplitTransport
import ai.oriveo.community.core.data.remote.MetadataTransport
import ai.oriveo.community.core.data.remote.MetadataTransportResponse
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.testing.TestSharedPreferences
import io.mockk.every
import io.mockk.mockk
import java.io.File
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Metadata decode of imageProfile / imageProfileOverride / profiles.image / providers.<kind>.imageModels
 * over the lean, cached and split paths, followed by the metadata -> slice adapter and resolve.
 * Fixture: shared metadata_catalog_contract.v1.json.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ImageProfileMetadataDecodeTest {

    @Test
    fun `split schema 3 index plus openRouter catalog resolves the catalog image model`() = runTest {
        val client = newClient(FakeSplitServer(schema3Index(), schema3Catalogs()), FakeRowDao(), demand(ProviderKind.OpenRouter))
        client.initialize(context())

        val slice = requireNotNull(client.imageProfileSlice())
        val indexImage = schema3Index().getValue("profiles").jsonObject.getValue("image").jsonObject
        assertTrue(indexImage.isNotEmpty())
        assertEquals(indexImage.size, slice.profiles.size)
        val catalogImageModels = schema3Catalogs().getValue(OPEN_ROUTER).getValue("imageModels").jsonObject
        assertEquals(catalogImageModels.keys, slice.providers.getValue(OPEN_ROUTER).imageModels.keys)

        val resolution = ImageProfileResolver.resolve(slice, OPEN_ROUTER, GPT_IMAGE_2)
        assertNull(resolution.reason)
        assertEquals("openrouter_gpt_images", resolution.profileRef)
        assertEquals(ImageRoute.OPENROUTER_IMAGES, resolution.profile?.route)
    }

    @Test
    fun `catalog modelDefaults imageProfile reaches every catalog model`() = runTest {
        val ref = "openrouter_gpt_images"
        val catalogs = schema3Catalogs()
        val catalog = catalogs.getValue(OPEN_ROUTER)
        val defaults = catalog.getValue("modelDefaults").jsonObject
        val injected = JsonObject(catalog + ("modelDefaults" to JsonObject(defaults + ("imageProfile" to JsonPrimitive(ref)))))
        val server = FakeSplitServer(schema3Index(), catalogs + (OPEN_ROUTER to injected))
        val client = newClient(server, FakeRowDao(), demand(ProviderKind.OpenRouter))
        client.initialize(context())

        val slice = requireNotNull(client.imageProfileSlice())
        val ids = catalog.getValue("models").jsonObject.keys
        assertTrue(ids.isNotEmpty())
        for (id in ids) {
            val resolution = ImageProfileResolver.resolve(slice, OPEN_ROUTER, id)
            assertNull(id, resolution.reason)
            assertEquals(id, ref, resolution.profileRef)
        }
    }

    @Test
    fun `lean payload decodes model override and provider imageModels and keeps them in the cache`() {
        val root = fixture().getValue("leanEquivalent").jsonObject
        val data = root.getValue("data").jsonObject
        val table = data.getValue("profiles").jsonObject.getValue("image").jsonObject
        val ref = table.keys.first()
        val base = table.getValue(ref).jsonObject
        val providers = data.getValue("providers").jsonObject
        val openAI = providers.getValue(OPEN_AI).jsonObject
        val models = openAI.getValue("models").jsonObject
        val (overridden, malformed) = models.keys.take(2)
        val override = JsonObject(mapOf("maxNPerCall" to JsonPrimitive(2), "timeoutSeconds" to JsonPrimitive(321)))
        val editedModels = models + mapOf(
            overridden to JsonObject(
                models.getValue(overridden).jsonObject + mapOf("imageProfile" to JsonPrimitive(ref), "imageProfileOverride" to override),
            ),
            malformed to JsonObject(
                models.getValue(malformed).jsonObject +
                    mapOf("imageProfile" to JsonPrimitive(ref), "imageProfileOverride" to JsonPrimitive("not-an-object")),
            ),
        )
        val imageModels = JsonObject(
            mapOf(LEAN_IMAGE_MODEL to JsonObject(mapOf("displayName" to JsonPrimitive("Image"), "imageProfile" to JsonPrimitive(ref)))),
        )
        val editedOpenAI = JsonObject(openAI + mapOf("models" to JsonObject(editedModels), "imageModels" to imageModels))
        val edited = JsonObject(
            root + ("data" to JsonObject(data + ("providers" to JsonObject(providers + (OPEN_AI to editedOpenAI))))),
        )

        val client = MetadataClient()
        client.loadNetworkPayloadForTesting(edited.toString(), "\"lean\"")
        val slice = requireNotNull(client.imageProfileSlice())
        assertEquals(table.size, slice.profiles.size)

        val merged = ImageProfileResolver.resolve(slice, OPEN_AI, overridden)
        assertNull(merged.reason)
        assertEquals(ref, merged.profileRef)
        assertEquals(override, merged.appliedOverride)
        assertEquals(2, merged.profile?.maxNPerCall)
        assertEquals(321, merged.profile?.timeoutSeconds)

        // A non-object override is ignored: the table entry applies unmerged.
        val unmerged = ImageProfileResolver.resolve(slice, OPEN_AI, malformed)
        assertNull(unmerged.reason)
        assertNull(unmerged.appliedOverride)
        assertEquals((base.getValue("timeoutSeconds") as JsonPrimitive).content.toInt(), unmerged.profile?.timeoutSeconds)

        val imageOnly = ImageProfileResolver.resolve(slice, OPEN_AI, LEAN_IMAGE_MODEL)
        assertNull(imageOnly.reason)
        assertEquals(ref, imageOnly.profileRef)

        // The persisted cache payload decodes back to the same slice.
        val replay = MetadataClient()
        replay.loadNetworkPayloadForTesting(requireNotNull(client.encodedCachePayloadForTesting()), "\"lean\"")
        assertEquals(slice, replay.imageProfileSlice())
    }

    @Test
    fun `malformed image fields in a lean payload leave every other model and provider decodable`() {
        val root = fixture().getValue("leanEquivalent").jsonObject
        val data = root.getValue("data").jsonObject
        val baseline = MetadataClient()
        baseline.loadNetworkPayloadForTesting(root.toString(), "\"lean\"")
        val expected = requireNotNull(baseline.imageProfileSlice())

        val providers = data.getValue("providers").jsonObject
        val openAI = providers.getValue(OPEN_AI).jsonObject
        val models = openAI.getValue("models").jsonObject
        val objectRef = models.keys.first()
        val editedModels = models + (
            objectRef to JsonObject(
                models.getValue(objectRef).jsonObject + ("imageProfile" to JsonObject(mapOf("ref" to JsonPrimitive("x")))),
            )
        )
        val imageModels = JsonObject(mapOf(LEAN_IMAGE_MODEL to JsonPrimitive("not-an-object")))
        val editedOpenAI = JsonObject(openAI + mapOf("models" to JsonObject(editedModels), "imageModels" to imageModels))
        val profiles = data.getValue("profiles").jsonObject
        val editedData = JsonObject(
            data + mapOf(
                "profiles" to JsonObject(profiles + ("image" to JsonArray(listOf(JsonPrimitive("not-a-table"))))),
                "providers" to JsonObject(providers + (OPEN_AI to editedOpenAI)),
            ),
        )

        val client = MetadataClient()
        client.loadNetworkPayloadForTesting(JsonObject(root + ("data" to editedData)).toString(), "\"lean\"")
        val slice = requireNotNull(client.imageProfileSlice())
        assertTrue(slice.profiles.isEmpty())
        assertEquals(expected.providers.keys, slice.providers.keys)
        assertEquals(expected.providers - OPEN_AI, slice.providers - OPEN_AI)
        assertEquals(
            expected.providers.getValue(OPEN_AI).models - objectRef,
            slice.providers.getValue(OPEN_AI).models - objectRef,
        )
        assertEquals(
            ImageProfileReason.NO_IMAGE_PROFILE,
            ImageProfileResolver.resolve(slice, OPEN_AI, objectRef).reason,
        )
        assertEquals(
            ImageProfileReason.NO_IMAGE_PROFILE,
            ImageProfileResolver.resolve(slice, OPEN_AI, LEAN_IMAGE_MODEL).reason,
        )
    }

    @Test
    fun `split catalog imageModels survive the cached cold start`() = runTest {
        val dao = FakeRowDao()
        val seed = newClient(FakeSplitServer(schema3Index(), schema3Catalogs()), dao, demand(ProviderKind.OpenRouter))
        seed.initialize(context())
        val expected = requireNotNull(seed.imageProfileSlice())
        assertTrue(expected.providers.getValue(OPEN_ROUTER).imageModels.isNotEmpty())

        val offline = FakeSplitServer(schema3Index(), schema3Catalogs()).apply { indexStatusOverride = 500 }
        val replay = newClient(offline, dao, demand(ProviderKind.OpenRouter), mutableListOf())
        replay.initialize(context())
        val replayed = requireNotNull(replay.imageProfileSlice())
        assertEquals(expected.profiles, replayed.profiles)
        assertEquals(expected.providers.getValue(OPEN_ROUTER), replayed.providers.getValue(OPEN_ROUTER))
        assertEquals("openrouter_gpt_images", ImageProfileResolver.resolve(replayed, OPEN_ROUTER, GPT_IMAGE_2).profileRef)
    }

    // -- helpers --

    private fun fixture(): JsonObject =
        Json.parseToJsonElement(workspaceFile("\u5171\u4eab/model-contracts/metadata_catalog_contract.v1.json").readText()).jsonObject

    private fun schema3(): JsonObject = fixture().getValue("schema3").jsonObject

    private fun schema3Index(): JsonObject = schema3().getValue("indexResponse").jsonObject.getValue("data").jsonObject

    private fun schema3Catalogs(): Map<String, JsonObject> = schema3().getValue("catalogResponses").jsonObject
        .mapValues { (_, value) -> value.jsonObject.getValue("data").jsonObject }

    private fun workspaceFile(path: String): File =
        generateSequence(File(System.getProperty("user.dir") ?: ".").absoluteFile) { it.parentFile }
            .map { File(it, path) }
            .firstOrNull(File::exists)
            ?: error("$path not found")

    private fun TestScope.newClient(
        server: FakeSplitServer,
        dao: FakeRowDao,
        demand: MetadataClient.CatalogDemand,
        reports: MutableList<Map<String, String>>? = null,
    ): MetadataClient = MetadataClient(
        backgroundScope = this,
        ioDispatcher = StandardTestDispatcher(testScheduler),
        metadataCacheDao = dao,
        metadataTransport = MetadataTransport { error("lean must not be requested") },
        metadataSplitTransport = server,
        nowMillis = { 1_000L },
        failureReporter = { tags -> reports?.add(tags) ?: error("unexpected failure: $tags") },
        metadataPayloadSchemaText = workspaceFile("\u5171\u4eab/model-contracts/metadata_payload.v2.schema.json").readText(),
    ).also { it.catalogDemandSupplier = { demand } }

    private fun demand(vararg kinds: ProviderKind) = MetadataClient.CatalogDemand(kinds.toSet(), hasRelay = false)

    private fun context(prefs: SharedPreferences = TestSharedPreferences()): Context {
        val context = mockk<Context>()
        every { context.applicationContext } returns context
        every { context.getSharedPreferences(any(), Context.MODE_PRIVATE) } returns prefs
        return context
    }

    /** Server stand-in: index and catalogs each carry an ETag; If-None-Match hits return 304. */
    private class FakeSplitServer(
        private val index: JsonObject,
        private val catalogs: Map<String, JsonObject>,
    ) : MetadataSplitTransport {
        var indexStatusOverride: Int? = null

        private fun catalogETag(key: String) =
            "\"catalog-$key-${(catalogs.getValue(key).getValue("catalogRevision") as JsonPrimitive).content}\""

        override suspend fun fetchIndex(ifNoneMatch: String?, cacheBust: String?): MetadataTransportResponse {
            indexStatusOverride?.let { return MetadataTransportResponse(it, null, null, 0) }
            if (ifNoneMatch == INDEX_ETAG) return MetadataTransportResponse(304, INDEX_ETAG, null, 0)
            val body = JsonObject(mapOf("data" to index)).toString()
            return MetadataTransportResponse(200, INDEX_ETAG, body, body.length.toLong())
        }

        override suspend fun fetchCatalog(provider: String, ifNoneMatch: String?, revision: String?): MetadataTransportResponse {
            val data = catalogs[provider] ?: return MetadataTransportResponse(404, null, null, 0)
            val eTag = catalogETag(provider)
            if (ifNoneMatch == eTag) return MetadataTransportResponse(304, eTag, null, 0)
            val body = JsonObject(mapOf("code" to JsonPrimitive(0), "data" to data, "message" to JsonPrimitive("ok"))).toString()
            return MetadataTransportResponse(200, eTag, body, body.length.toLong())
        }
    }

    /** Multi-row Room stand-in with the production DAO semantics (rows by key, substr chunks). */
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

        override suspend fun upsertAllInTransaction(entities: List<MetadataCacheEntity>) {
            entities.forEach { upsert(it) }
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
        const val INDEX_ETAG = "\"index-0\""
        const val OPEN_ROUTER = "openRouter"
        const val OPEN_AI = "openAI"
        const val GPT_IMAGE_2 = "openai/gpt-image-2"
        const val LEAN_IMAGE_MODEL = "image-only-model"
    }
}
