package ai.oriveo.community.core.data.remote

import android.content.Context
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import java.util.zip.GZIPInputStream

/**
 * APK-bundled schema 2 metadata snapshot (attached by :app's syncMetadataContractAssets at build time).
 *
 * Only a fallback for a cold start with "no Room cache and the fetch failed": unreadable, unparsable or envelope-invalid data always returns null,
 * and the caller keeps waiting for online data. A bad provider / bad model drops only that entry, same as online.
 */
internal object BundledMetadata {
    /** AGP unpacks .gz when packaging, so at runtime it is the same-named plain file without the suffix. */
    const val ASSET = "model-contracts/bundled-metadata.v2.json"
    private const val GZIP_ASSET = "$ASSET.gz"

    /** Reads the asset text; when the plain file is missing, tries the un-unpacked .gz (packaging toolchain differences). Returns null if neither is readable. */
    fun readAsset(context: Context): String? {
        val assets = context.applicationContext.assets
        return try {
            assets.open(ASSET).bufferedReader().use { it.readText() }
        } catch (_: Exception) {
            try {
                GZIPInputStream(assets.open(GZIP_ASSET)).bufferedReader().use { it.readText() }
            } catch (_: Exception) {
                null
            }
        }
    }

    /** Parses and validates via [validator]; returns null when the envelope fails, and returns the data after dropping bad providers / bad models. */
    fun validated(text: String, json: Json, validator: MetadataPayloadSchemaValidator): JsonObject? {
        val data = try {
            json.parseToJsonElement(text) as? JsonObject
        } catch (_: Exception) {
            null
        } ?: return null
        val result = validator.decode(data)
        if (result.envelopeError != null) return null
        if (result.droppedProviders.isEmpty() && result.droppedModels.isEmpty()) return data
        val providers = data["providers"] as? JsonObject ?: return data
        val droppedProviders = result.droppedProviders.mapTo(hashSetOf()) { it.providerId }
        val droppedModels = result.droppedModels.map { it.modelId }
        val kept = providers.filterKeys { it !in droppedProviders }.mapValues { (providerId, raw) ->
            val provider = raw as? JsonObject ?: return@mapValues raw
            val models = provider["models"] as? JsonObject ?: return@mapValues raw
            val prefix = "$providerId/"
            val drop = droppedModels.filter { it.startsWith(prefix) }.mapTo(hashSetOf()) { it.removePrefix(prefix) }
            if (drop.isEmpty()) raw else JsonObject(provider + ("models" to JsonObject(models - drop)))
        }
        return JsonObject(data + ("providers" to JsonObject(kept)))
    }
}
