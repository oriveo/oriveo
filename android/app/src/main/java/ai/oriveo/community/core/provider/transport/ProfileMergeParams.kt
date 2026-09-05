package ai.oriveo.community.core.provider.transport

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Injects a profile's mergeParams into a request body.
 *
 * When a model carries a webSearch / reasoning / imageGen profile name, the caller
 * builds the base request body and then hands it here so `profile.mergeParams` gets
 * folded in.
 *
 * Forward compatibility: any profile definition that carries mergeParams is applied,
 * with no client-side whitelist of profile names. A newly published profile must not
 * force a client release, and if the upstream rejects one of the injected parameters
 * the self-healing retry path takes care of it.
 */
fun applyProfileMergeParams(
    baseBody: JsonObject,
    profileName: String?,
    mergeParams: JsonObject?,
): JsonObject {
    if (profileName.isNullOrBlank()) return baseBody
    if (mergeParams == null || mergeParams.isEmpty()) return baseBody
    return deepMergeJsonObject(baseBody, mergeParams)
}

/**
 * Deep merge of two JSON objects.
 *
 * Rules:
 *  - when both sides hold a [JsonObject] under the same key, recurse
 *  - `tools` and `plugins` arrays are appended by element identity; every other
 *    array is replaced wholesale by the incoming one
 *  - on any other type conflict the incoming value wins
 *  - keys present only in base are kept
 *  - keys present only in incoming are added
 */
internal fun deepMergeJsonObject(base: JsonObject, incoming: JsonObject): JsonObject {
    if (incoming.isEmpty()) return base
    val keys = LinkedHashSet<String>()
    keys.addAll(base.keys)
    keys.addAll(incoming.keys)
    return buildJsonObject {
        for (key in keys) {
            val b = base[key]
            val i = incoming[key]
            when {
                i == null -> b?.let { put(key, it) }
                b == null -> put(key, i)
                b is JsonObject && i is JsonObject -> put(key, deepMergeJsonObject(b, i))
                b is JsonArray && i is JsonArray && (key == "tools" || key == "plugins") -> put(key, composeOwnedArray(b, i))
                else -> put(key, i)
            }
        }
    }
}

private fun composeOwnedArray(base: JsonArray, contribution: JsonArray): JsonArray {
    val out = base.toMutableList()
    val identities = out.mapTo(LinkedHashSet(), ::ownedArrayIdentity)
    contribution.forEach { item -> if (identities.add(ownedArrayIdentity(item))) out += item }
    return JsonArray(out)
}

private fun ownedArrayIdentity(value: JsonElement): String = canonicalJson(value)
private fun canonicalJson(value: JsonElement): String = when (value) {
    is JsonArray -> value.joinToString(prefix = "[", postfix = "]") { canonicalJson(it) }
    is JsonObject -> value.keys.sorted().joinToString(prefix = "{", postfix = "}") { "${JsonPrimitive(it)}:${canonicalJson(value[it]!!)}" }
    else -> value.toString()
}

/**
 * Parses a JSON fragment held as a string into a [JsonObject], returning null when
 * it does not parse.
 *
 * The service layer still builds some request bodies by string concatenation, so
 * this lets those paths pick up mergeParams injection without being rewritten:
 * decode, run applyProfileMergeParams, encode back to a string.
 */
internal fun parseJsonObjectOrNull(raw: String): JsonObject? {
    return runCatching {
        kotlinx.serialization.json.Json.parseToJsonElement(raw) as? JsonObject
    }.getOrNull()
}
