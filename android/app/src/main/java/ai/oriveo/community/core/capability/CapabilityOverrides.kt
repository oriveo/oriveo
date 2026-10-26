package ai.oriveo.community.core.capability

import ai.oriveo.community.core.model.RelayCapabilityOverrides
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import java.time.OffsetDateTime
import java.time.format.DateTimeParseException
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Normalization of input-capability overrides (deltas) for Relay / custom endpoints,
 * with the same semantics as the Web `normalizeCapabilityOverrides`. Fixture: `shared/test-fixtures/capability/overrides.v1.json`.
 *
 * Only the three input keys can be overridden, op is add / remove; a key the user never touched follows the server (effective null).
 * The old [RelayCapabilityOverrides] image / file entries whose source is user are migrated once into deltas (setAt = now, baseVerdict = the server state of that key, unknown by default);
 * a source of tested is a probe result, not a user choice, so it is not migrated and stays in the old field as is; other old keys are untouched. Already stored new deltas take precedence over the old fields.
 * Official connections carry no overrides. Bad entries are dropped one by one.
 */
enum class CapabilityOverrideOp(val value: String) {
    Add("add"),
    Remove("remove"),
    ;

    companion object {
        fun fromValue(raw: String?): CapabilityOverrideOp? = entries.firstOrNull { it.value == raw }
    }
}

data class CapabilityOverrideEntry(
    val op: CapabilityOverrideOp,
    /** ISO time. */
    val setAt: String,
    /** The server's state for the key when the user set the override. */
    val baseVerdict: String,
)

data class NormalizedCapabilityOverrides(
    /** Keys taken from [CapabilityOverrides.INPUT_KEYS], in its fixed order. */
    val capabilityOverrides: Map<String, CapabilityOverrideEntry>,
    /** Keys still left in the old field after migration (in the old field's key order). */
    val legacyKept: List<String>,
    /** The effective op of each of the three input keys; null = follow the server. */
    val effective: Map<String, CapabilityOverrideOp?>,
)

object CapabilityOverrides {
    val INPUT_KEYS: List<String> = listOf(
        CapabilityEvidenceFacade.VISION_INPUT,
        CapabilityEvidenceFacade.FILE_INPUT,
        CapabilityEvidenceFacade.VIDEO_INPUT,
    )

    const val CONNECTION_OFFICIAL = "official"
    private const val UNKNOWN_VERDICT = "unknown"

    /** Migratable keys in the old field -> new input keys. */
    private val LEGACY_INPUT_KEYS: Map<String, String> = mapOf(
        "image" to CapabilityEvidenceFacade.VISION_INPUT,
        "file" to CapabilityEvidenceFacade.FILE_INPUT,
    )

    /**
     * @param connection relay / custom / official
     * @param stored Locally stored deltas; the source is untrusted, so each entry is validated.
     * @param serverVerdict The server's state for each input key (a missing key = unknown).
     * @param now ISO time, the setAt of migrated entries.
     */
    fun normalize(
        connection: String,
        legacy: RelayCapabilityOverrides?,
        stored: JsonElement?,
        serverVerdict: Map<String, String>?,
        now: String,
    ): NormalizedCapabilityOverrides {
        if (connection == CONNECTION_OFFICIAL) return result(emptyMap(), emptyList())

        val overrides = linkedMapOf<String, CapabilityOverrideEntry>()
        (stored as? JsonObject)?.let { obj ->
            for (key in INPUT_KEYS) parseEntry(obj[key])?.let { overrides[key] = it }
        }

        val legacyKept = mutableListOf<String>()
        if (legacy != null) {
            for (legacyKey in RelayCapabilityOverrides.KEYS) {
                val raw: Any = legacyValue(legacy, legacyKey) ?: continue
                val target = LEGACY_INPUT_KEYS[legacyKey]
                val userChoice = (raw as? Boolean)
                    ?.takeIf { legacy.sourceOf(legacyKey) == RelayCapabilityOverrides.SOURCE_USER }
                if (target == null || userChoice == null) {
                    legacyKept += legacyKey
                    continue
                }
                // The user's choice has been consumed: when the new deltas already hold the same key they win, and the old value is simply dropped.
                if (target in overrides) continue
                overrides[target] = CapabilityOverrideEntry(
                    op = if (userChoice) CapabilityOverrideOp.Add else CapabilityOverrideOp.Remove,
                    setAt = now,
                    baseVerdict = serverVerdict?.get(target)?.takeIf { it.isNotEmpty() } ?: UNKNOWN_VERDICT,
                )
            }
        }

        // Output in fixed key order so serialization is stable.
        val ordered = INPUT_KEYS.mapNotNull { key -> overrides[key]?.let { key to it } }.toMap()
        return result(ordered, legacyKept)
    }

    private fun result(overrides: Map<String, CapabilityOverrideEntry>, legacyKept: List<String>) =
        NormalizedCapabilityOverrides(
            capabilityOverrides = overrides,
            legacyKept = legacyKept,
            effective = INPUT_KEYS.associateWith { overrides[it]?.op },
        )

    private fun legacyValue(legacy: RelayCapabilityOverrides, key: String): Any? = when (key) {
        "image" -> legacy.image
        "file" -> legacy.file
        "imageGeneration" -> legacy.imageGeneration
        "toolCall" -> legacy.toolCall
        "reasoningLevels" -> legacy.reasoningLevels
        "web" -> legacy.web
        else -> null
    }

    private fun parseEntry(value: JsonElement?): CapabilityOverrideEntry? {
        val obj = value as? JsonObject ?: return null
        val op = CapabilityOverrideOp.fromValue(stringOf(obj["op"])) ?: return null
        val setAt = stringOf(obj["setAt"])?.takeIf { it.isNotEmpty() && isIsoTime(it) } ?: return null
        val baseVerdict = stringOf(obj["baseVerdict"])?.takeIf { it.isNotEmpty() } ?: return null
        return CapabilityOverrideEntry(op, setAt, baseVerdict)
    }

    private fun stringOf(value: JsonElement?): String? =
        (value as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun isIsoTime(raw: String): Boolean = try {
        OffsetDateTime.parse(raw)
        true
    } catch (_: DateTimeParseException) {
        false
    }
}
