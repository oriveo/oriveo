package ai.oriveo.community.core.data.remote

import android.content.Context
import ai.oriveo.community.core.data.dao.MetadataCacheDao
import ai.oriveo.community.core.data.entity.MetadataCacheEntity
import ai.oriveo.community.core.model.ProviderKind
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.io.IOException

/** The schema 2 snapshot bundled in the APK: the asset is really packaged and readable, and is adopted on a cold start with no cache and a failed fetch. */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class BundledMetadataTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()

    private fun assetText(name: String): String =
        context.assets.open(name).bufferedReader().use { it.readText() }

    @Test
    fun bundledAssetIsPackagedParsableAndPassesValidator() {
        val text = BundledMetadata.readAsset(context)
        assertNotNull("the bundled snapshot asset should ship in the APK", text)
        val data = Json.parseToJsonElement(text!!).jsonObject
        assertEquals(0L, data.getValue("metadataRevision").jsonPrimitive.longOrNull)
        assertEquals(2, data.getValue("metadataSchema").jsonPrimitive.content.toInt())

        val validator = MetadataPayloadSchemaValidator(
            Json.parseToJsonElement(assetText(MetadataClient.METADATA_PAYLOAD_SCHEMA_ASSET)),
        )
        val result = validator.decode(data)
        assertNull(result.envelopeError)
        assertEquals(emptyList<Any>(), result.droppedProviders)
        assertEquals(emptyList<Any>(), result.droppedModels)
        val modelCount = data.getValue("providers").jsonObject.values
            .sumOf { (it.jsonObject["models"] as? JsonObject)?.size ?: 0 }
        assertTrue(modelCount > 0)
        assertEquals(modelCount, result.keptModels.size)
        // Production validation entry point: returned as is when everything passes.
        assertEquals(data, BundledMetadata.validated(text, Json, validator))
    }

    @Test
    fun badEnvelopeIsNotAdopted() {
        val validator = MetadataPayloadSchemaValidator(
            Json.parseToJsonElement(assetText(MetadataClient.METADATA_PAYLOAD_SCHEMA_ASSET)),
        )
        val data = Json.parseToJsonElement(BundledMetadata.readAsset(context)!!).jsonObject
        assertNull(BundledMetadata.validated(JsonObject(data - "metadataRevision").toString(), Json, validator))
        assertNull(BundledMetadata.validated("not json", Json, validator))
    }

    @Test
    fun coldStartFetchFailureAdoptsBundledThenOnlineRevisionOverrides() = runTest {
        val dao = FakeRowDao()
        var online: String? = null
        val client = newClient(dao, enabled = true) { online }

        client.initialize(context)

        val bundled = client.resolveCatalogModel(MODEL, ProviderKind.OpenAI)
        assertNotNull("the bundled snapshot should resolve the openAI model", bundled)
        assertTrue(client.providerModelIds(ProviderKind.OpenAI).contains(MODEL))
        // Build-time data does not count as confirmed in this session and is not written to Room.
        assertFalse(client.isSnapshotConfirmed(ProviderKind.OpenAI))
        assertTrue(dao.rows.isEmpty())

        val data = Json.parseToJsonElement(BundledMetadata.readAsset(context)!!).jsonObject
        val providers = data.getValue("providers").jsonObject
        val openAI = providers.getValue("openAI").jsonObject
        val models = openAI.getValue("models").jsonObject
        val renamed = JsonObject(models.getValue(MODEL).jsonObject + ("displayName" to JsonPrimitive(ONLINE_NAME)))
        online = JsonObject(
            data + mapOf(
                "metadataRevision" to JsonPrimitive(1),
                "providers" to JsonObject(
                    providers + ("openAI" to JsonObject(openAI + ("models" to JsonObject(models + (MODEL to renamed))))),
                ),
            ),
        ).toString()

        client.refresh()

        assertEquals(ONLINE_NAME, client.resolveCatalogModel(MODEL, ProviderKind.OpenAI)?.displayName)
        assertTrue(client.isSnapshotConfirmed(ProviderKind.OpenAI))
        assertTrue(dao.rows.isNotEmpty())
    }

    @Test
    fun requestSchemaAtLeast2DefaultColdStartFetchFailureAdoptsBundled() = runTest {
        // The bundled snapshot fallback follows the request schema >= 2 (production requests schema 3); what is locked is "on from 2 upward", not a specific generation.
        assertTrue(MetadataClient.METADATA_REQUEST_SCHEMA >= 2)
        val dao = FakeRowDao()
        // No switch injected: use the production default (follows the request schema).
        val client = newClient(dao, enabled = null) { null }

        client.initialize(context)

        assertNotNull("with request schema >= 2 a cold start with no cache and a failed fetch should adopt the bundled snapshot", client.resolveCatalogModel(MODEL, ProviderKind.OpenAI))
        assertTrue(client.providerModelIds(ProviderKind.OpenAI).contains(MODEL))
        assertFalse(client.isSnapshotConfirmed(ProviderKind.OpenAI))
        assertTrue(dao.rows.isEmpty())
    }

    @Test
    fun coldStartFetchFailureWithFallbackDisabledAdoptsNothing() = runTest {
        val dao = FakeRowDao()
        val client = newClient(dao, enabled = false) { null }

        client.initialize(context)

        assertNull(client.resolveCatalogModel(MODEL, ProviderKind.OpenAI))
        assertEquals(MetadataClient.CatalogLoadState.Unavailable, client.catalogLoadState(ProviderKind.OpenAI))
        assertTrue(dao.rows.isEmpty())
    }

    @Test
    fun bundledSnapshotYieldsToOnlineDataPublishedBeforeAdoption() = runTest {
        val dao = FakeRowDao()
        val data = Json.parseToJsonElement(BundledMetadata.readAsset(context)!!).jsonObject
        val providers = data.getValue("providers").jsonObject
        val openAI = providers.getValue("openAI").jsonObject
        val models = openAI.getValue("models").jsonObject
        val renamed = JsonObject(models.getValue(MODEL).jsonObject + ("displayName" to JsonPrimitive(ONLINE_NAME)))
        val online = JsonObject(
            data + mapOf(
                "metadataRevision" to JsonPrimitive(1),
                "providers" to JsonObject(
                    providers + ("openAI" to JsonObject(openAI + ("models" to JsonObject(models + (MODEL to renamed))))),
                ),
            ),
        ).toString()
        val client = newClient(dao, enabled = true) { online }
        // Online data is published first, then the bundled snapshot adoption runs: it must not overwrite the online data.
        client.fetchMetadataForTesting(bypassETag = true)
        assertEquals(ONLINE_NAME, client.resolveCatalogModel(MODEL, ProviderKind.OpenAI)?.displayName)

        client.adoptBundledSnapshotIfEmpty(context)

        assertEquals(ONLINE_NAME, client.resolveCatalogModel(MODEL, ProviderKind.OpenAI)?.displayName)
        assertFalse(client.isBundledSnapshotActiveForTesting)
        assertTrue(client.isSnapshotConfirmed(ProviderKind.OpenAI))
    }

    /** Lean transport: throws IOException to simulate offline when [body] is null, otherwise returns 200. */
    private fun TestScope.newClient(
        dao: FakeRowDao,
        enabled: Boolean?,
        body: () -> String?,
    ): MetadataClient {
        val transport = MetadataTransport {
            val text = body() ?: throw IOException("offline")
            MetadataTransportResponse(200, "\"online-1\"", text, text.length.toLong())
        }
        val factsTransport = ModelFactsTransport { MetadataTransportResponse(404, null, null, 0) }
        // When enabled is null no switch is passed, which verifies the production default.
        return if (enabled == null) {
            MetadataClient(
                backgroundScope = this,
                ioDispatcher = StandardTestDispatcher(testScheduler),
                metadataCacheDao = dao,
                metadataTransport = transport,
                modelFactsTransport = factsTransport,
                nowMillis = { 1_000L },
                failureReporter = {},
            )
        } else {
            MetadataClient(
                backgroundScope = this,
                ioDispatcher = StandardTestDispatcher(testScheduler),
                metadataCacheDao = dao,
                metadataTransport = transport,
                modelFactsTransport = factsTransport,
                nowMillis = { 1_000L },
                failureReporter = {},
                bundledFallbackEnabled = enabled,
            )
        }
    }

    /** Multi-row Room double (modeled on MetadataClientSchemaV2Test.FakeRowDao). */
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
        const val MODEL = "chat-latest"
        const val ONLINE_NAME = "Online Revision 1"
    }
}
