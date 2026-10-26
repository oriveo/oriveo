package ai.oriveo.community.testing

import ai.oriveo.community.core.data.remote.MetadataClient
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.util.zip.GZIPInputStream

/**
 * Attachment support of official providers comes only from metadata. A test of the support matrix first uses this fixture
 * to inject the attachmentSupport of the matching provider from the bundled snapshot shared/model-contracts/bundled-metadata.v2.json.gz
 * into MetadataClient.instance, and [clear]s it in @After.
 */
object BundledAttachmentSupportFixture {

    /** Injects only the attachmentSupport of the given providers (metadata backend keys such as "openAI" / "siliconFlow"). */
    fun install(vararg backendKinds: String) {
        val bundledProviders = bundledPayload().getValue("providers").jsonObject
        val payload = buildJsonObject {
            put("version", 1)
            put("contractVersion", 1)
            put("providers", buildJsonObject {
                backendKinds.forEach { kind ->
                    val support = bundledProviders.getValue(kind).jsonObject.getValue("attachmentSupport")
                    put(kind, buildJsonObject {
                        put("attachmentSupport", support)
                        put("resolveMap", JsonObject(emptyMap()))
                        put("models", JsonObject(emptyMap()))
                    })
                }
            })
        }
        // Publish through the production decoding path on a separate client, then swap only the table into the instance, leaving the instance's other published state alone.
        val scratch = MetadataClient()
        scratch.loadNetworkPayloadForTesting(payload.toString(), null)
        tableField().set(MetadataClient.instance, tableField().get(scratch))
    }

    /** Publishes the whole bundled snapshot through the production decoding path to a separate client (the instance is untouched), for tests that read capabilityControls. */
    fun bundledMetadataClient(): MetadataClient = MetadataClient().also {
        it.loadNetworkPayloadForTesting(bundledPayload().toString(), null)
    }

    fun clear() {
        tableField().set(MetadataClient.instance, null)
    }

    private fun tableField() = MetadataClient::class.java.getDeclaredField("table").apply { isAccessible = true }

    private fun bundledPayload(): JsonObject {
        val text = GZIPInputStream(
            workspaceFile("shared/model-contracts/bundled-metadata.v2.json.gz").inputStream(),
        ).bufferedReader().use { it.readText() }
        return Json.parseToJsonElement(text).jsonObject
    }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("cannot find $relative")
    }
}
