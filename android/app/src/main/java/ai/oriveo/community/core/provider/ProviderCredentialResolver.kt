package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind

/**
 * The single entry point for obtaining a connection key per model.
 *
 * Production code obtains keys only through here. A single-key connection returns [Provider.apiKey] unchanged: no trim, no fallback, independent of [modelId].
 * Multi-key relay: an enabled model's `relayKeyID` that hits the list -> that key's value; missing, dangling, model not among the enabled ones,
 * or empty model id -> the primary key ([Provider.apiKey]; the first list entry's own value is never read); non-relays ignore the list.
 * Contract fixture: `shared/test-fixtures/relay/credential-resolve.v1.json`.
 */
object ProviderCredentialResolver {
    fun apiKey(provider: Provider, modelId: String? = null): String {
        if (provider.kind != ProviderKind.Relay || modelId == null) return provider.apiKey
        val keyID = provider.models.firstOrNull { it.id == modelId }?.relayKeyID ?: return provider.apiKey
        return keySecret(provider, keyID)
    }

    /** Value of the specified key; the primary key, a nonexistent id, and non-relays all yield [Provider.apiKey]. */
    fun keySecret(provider: Provider, keyID: String): String {
        val keys = provider.relayKeys.takeIf { provider.kind == ProviderKind.Relay } ?: return provider.apiKey
        val index = keys.indexOfFirst { it.id == keyID }
        return if (index <= 0) provider.apiKey else keys[index].apiKey
    }

    /** Values of all keys of the connection (primary first), for places that assemble a credential list from the connection to redact. */
    fun allApiKeys(provider: Provider): List<String> =
        listOf(provider.apiKey) + provider.relayKeys.orEmpty().drop(1).map { it.apiKey }
}
