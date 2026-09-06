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

    val defaultModel: AIModel?
        get() = models.firstOrNull { it.isDefault }
            ?: models.firstOrNull()
            ?: catalogModels.firstOrNull { it.isDefault }
            ?: catalogModels.firstOrNull()

    fun recoveredFromPersistence(): Provider =
        if (status is ProviderConnectionState.Syncing) {
            copy(status = ProviderConnectionState.Connected)
        } else {
            this
        }
}
