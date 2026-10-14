package ai.oriveo.community.core.model

import androidx.compose.runtime.Immutable
import ai.oriveo.community.core.provider.ProviderCatalogResolver
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
enum class ProviderAuthMode(val rawValue: String) {
    @SerialName("apiKey") ApiKey("apiKey"),
    @SerialName("subscription") Subscription("subscription"),
    ;

    companion object {

        fun fromRawValue(raw: String?): ProviderAuthMode =
            entries.firstOrNull { it.rawValue.equals(raw, ignoreCase = false) } ?: ApiKey
    }
}

@Immutable
@Serializable
data class Provider(
    val id: String,
    val kind: ProviderKind,
    val status: ProviderConnectionState = ProviderConnectionState.Connected,
    val models: List<AIModel> = emptyList(),

    val catalogModels: List<AIModel> = emptyList(),
    val lastCheckedAt: Long? = null,
    val apiKey: String = "",
    val apiKeyPreview: String = "",
    val lastError: String? = null,
    val baseUrlText: String? = null,
    val customName: String? = null,
    val relayKind: RelayKind? = null,
    val relayRequested: RelayRequestedConfig? = null,
    val relayImage: RelayImageConfig? = null,

    val authMode: ProviderAuthMode = ProviderAuthMode.ApiKey,
    val updatedAt: Long = 0L,
    /**
     * Model count written when the catalog is stored, so a list row can show a number without
     * parsing the catalog JSON. Null falls back to computing it.
     */
    val cachedAvailableModelCount: Int? = null,
    /**
     * Address source of official providers: `default` / `region:<id>` are computed from the current metadata at request time, while `custom` and null (unclassified) use the literal address.
     * Stored on this device only, not synced or exported, so it does not take part in serialization. See [ai.oriveo.community.core.provider.transport.OfficialEndpointSource].
     */
    @kotlinx.serialization.Transient
    val endpointSource: String? = null,
    /** Values of the extra fields of the setup page (currently only `workspaceId`). Stored on this device only, same as [endpointSource]. */
    @kotlinx.serialization.Transient
    val setupValues: Map<String, String>? = null,
    /**
     * Key list of a relay connection: ordered, the first key is the primary key and its value is always [apiKey] (the entry's own apiKey is stored empty).
     * null = one implicit key `initial` (existing single-key connections need no migration). Stored on this device only, same as [setupValues]:
     * Room stores only id / name / status, the values of non-primary keys live in SecureKeyStore; nothing goes to Firestore or backups.
     */
    @kotlinx.serialization.Transient
    val relayKeys: List<RelayKey>? = null,
) {
    val displayName: String
        get() {
            val trimmed = customName?.trim()
            if (!trimmed.isNullOrEmpty()) {
                return trimmed
            }
            return if (kind == ProviderKind.Relay) {
                // A relay has no vendor name of its own, so the host is the only thing that tells
                // two of them apart in a list.
                val host = relayBaseURLHost()
                if (host != null) "Relay ($host)" else "Relay"
            } else {
                kind.displayName
            }
        }

    private fun relayBaseURLHost(): String? {
        val raw = baseUrlText?.trim().orEmpty()
        if (raw.isEmpty()) return null
        val withScheme = if (raw.contains("://")) raw else "https://$raw"
        return runCatching { java.net.URI(withScheme).host?.takeIf { it.isNotEmpty() } }.getOrNull()
    }

    val enabledModelCount: Int
        get() = models.size

    val allModels: List<AIModel>
        get() = if (kind == ProviderKind.Relay || catalogModels.isNotEmpty()) {
            if (catalogModels.isEmpty()) models else catalogModels
        } else {
            ProviderCatalogResolver.resolve(this).catalog
                .map { resolved -> resolved.model }
                .ifEmpty { models }
        }

    val availableModelCount: Int
        get() = cachedAvailableModelCount ?: allModels.count { it.isAvailable }

    /** Relays have no default model: the legacy isDefault is ignored, only the first enabled model is taken, with no fallback to the catalog. */
    val defaultModel: AIModel?
        get() = if (kind == ProviderKind.Relay) {
            models.firstOrNull()
        } else {
            models.firstOrNull { it.isDefault }
                ?: models.firstOrNull()
                ?: catalogModels.firstOrNull { it.isDefault }
                ?: catalogModels.firstOrNull()
        }

    fun recoveredFromPersistence(): Provider =
        if (status is ProviderConnectionState.Syncing) {
            copy(status = ProviderConnectionState.Connected)
        } else {
            this
        }
}

/**
 * One key of a relay connection. [apiKey] is only populated in memory: for the primary key (the first in the list) it is always empty and the value lives in
 * [Provider.apiKey]; the other values are stored in SecureKeyStore. Name and status take no part in any connection identity comparison.
 */
@Immutable
@Serializable
data class RelayKey(
    val id: String,
    val name: String? = null,
    val apiKey: String = "",
    val status: RelayKeyStatus? = null,
)

/** The latest result for a key, coming only from catalog fetches and real requests; null = not checked. [checkedAt] is a local millisecond timestamp. */
@Immutable
@Serializable
data class RelayKeyStatus(
    val state: String,
    val httpStatus: Int? = null,
    val checkedAt: Long? = null,
) {
    companion object {
        /** Identical word for word to `keyStatusStates` in `key-binding.v1.json`. */
        val STATES: List<String> = listOf("ok", "invalid", "denied", "limited", "failed")
    }
}
