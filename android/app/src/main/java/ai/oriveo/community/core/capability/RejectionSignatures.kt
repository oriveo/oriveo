package ai.oriveo.community.core.capability

import android.content.Context
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull

/** Result of a narrow-signature match: input_rejected carries [capabilityKey], param_rejected carries [parameter]. */
data class RejectionSignature(
    val signatureId: String,
    val kind: String,
    val capabilityKey: String? = null,
    val parameter: String? = null,
)

/**
 * Table of narrow signatures for upstream rejecting media / parameters, with the same semantics as the Web client.
 *
 * Contains only byWireFamily / byProtocol of the shared JSON; candidates / notFound do not enter the table.
 * byWireFamily comes first in file order (only when the request carries that wire family), byProtocol after; the first match is returned;
 * no match returns null, and the caller shows the upstream error as is, without inference.
 */
class RejectionSignatureTable internal constructor(
    internal val byWireFamily: Map<String, List<Entry>>,
    internal val byProtocol: Map<String, List<Entry>>,
) {
    internal class Entry(
        val signatureId: String,
        val httpStatus: Int,
        val errorCode: String?,
        val messagePattern: Regex,
        val kind: String,
        val capabilityKey: String?,
        val parameter: String?,
    )

    private class UpstreamError(val type: String?, val code: String?, val message: String?)

    fun match(protocol: String, wireFamily: String?, httpStatus: Int, body: Any?): RejectionSignature? =
        match(protocol, listOfNotNull(wireFamily), httpStatus, body)

    /** [body] is a parsed [JsonElement] or raw text; any other type is treated as unrecognizable. */
    fun match(protocol: String, wireFamilies: Collection<String>, httpStatus: Int, body: Any?): RejectionSignature? {
        val error = extractError(body) ?: return null
        val ordered = byWireFamily.filterKeys { it in wireFamilies }.values.flatten() +
            byProtocol[protocol].orEmpty()
        val hit = ordered.firstOrNull { matches(it, httpStatus, error) } ?: return null
        return toSignature(hit)
    }

    private fun matches(entry: Entry, status: Int, error: UpstreamError): Boolean {
        if (entry.httpStatus != status) return false
        if (entry.errorCode != null && entry.errorCode != error.type && entry.errorCode != error.code) return false
        val message = error.message ?: return false
        return entry.messagePattern.containsMatchIn(message)
    }

    private fun toSignature(entry: Entry): RejectionSignature? = when {
        entry.kind == "input_rejected" && !entry.capabilityKey.isNullOrEmpty() ->
            RejectionSignature(entry.signatureId, entry.kind, capabilityKey = entry.capabilityKey)
        entry.kind == "param_rejected" && !entry.parameter.isNullOrEmpty() ->
            RejectionSignature(entry.signatureId, entry.kind, parameter = entry.parameter)
        else -> null
    }

    /** Accepts `{error:{...}}`, Anthropic's `{type:"error", error:{...}}` and JSON text. */
    private fun extractError(body: Any?): UpstreamError? {
        val parsed: JsonElement = when (body) {
            is JsonElement -> body
            is String -> runCatching { Json.parseToJsonElement(body) }.getOrNull() ?: return null
            else -> return null
        }
        val error = (parsed as? JsonObject)?.get("error") as? JsonObject ?: return null
        return UpstreamError(error.string("type"), error.string("code"), error.string("message"))
    }

    private fun JsonObject.string(key: String): String? =
        (get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content
}

/** Single source of the signature table: reads the shared JSON from the APK assets at runtime (attached by :app's syncMetadataContractAssets at build time). */
object RejectionSignatures {
    const val ASSET = "model-contracts/rejection-signatures.v1.json"

    /** Reads the asset and parses it; returns null when it cannot be read or parsed (the caller treats everything as no match). */
    fun load(context: Context): RejectionSignatureTable? = try {
        parse(context.applicationContext.assets.open(ASSET).bufferedReader().use { it.readText() })
    } catch (_: Exception) {
        null
    }

    fun parse(text: String): RejectionSignatureTable {
        val root = Json.parseToJsonElement(text) as JsonObject
        return RejectionSignatureTable(
            byWireFamily = groups(root["byWireFamily"]),
            byProtocol = groups(root["byProtocol"]),
        )
    }

    private fun groups(element: JsonElement?): Map<String, List<RejectionSignatureTable.Entry>> {
        val obj = element as? JsonObject ?: return emptyMap()
        // LinkedHashMap keeps file order (the first match is returned).
        return obj.entries.associateTo(LinkedHashMap()) { (key, value) ->
            key to (value as JsonArray).map { entry(it as JsonObject) }
        }
    }

    private fun entry(obj: JsonObject): RejectionSignatureTable.Entry {
        fun str(key: String): String? = (obj[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
        return RejectionSignatureTable.Entry(
            signatureId = requireNotNull(str("signatureId")) { "signatureId missing" },
            httpStatus = requireNotNull((obj["httpStatus"] as? JsonPrimitive)?.intOrNull) { "httpStatus missing" },
            errorCode = str("errorCode"),
            messagePattern = Regex(requireNotNull(str("messagePattern")) { "messagePattern missing" }, RegexOption.IGNORE_CASE),
            kind = requireNotNull(str("kind")) { "kind missing" },
            capabilityKey = str("capabilityKey"),
            parameter = str("parameter"),
        )
    }
}
