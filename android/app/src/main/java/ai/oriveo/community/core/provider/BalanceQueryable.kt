package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.Provider
import java.net.URI
import java.time.Duration
import java.time.Instant
import java.util.concurrent.ConcurrentHashMap

/**
 * Reads the credit balance the user holds with their own provider account. Only four
 * upstreams expose such an endpoint: OpenRouter, SiliconFlow, DeepSeek and Moonshot.
 *
 * The balance endpoint host must be derived from the user's configured baseURL rather
 * than hard coded to the vendor's main domain: Moonshot runs two hosts, and a user may
 * point the provider at their own baseURL, either of which would break a hard coded
 * one.
 *
 * The remaining providers and relay endpoints do not implement this interface; the UI
 * consults [BALANCE_CAPABLE_KINDS] to decide whether to render the balance card.
 */
interface BalanceQueryable {
    /**
     * @param apiKey the caller's API key, sent as a Bearer token
     * @param baseURL the baseURL the user configured, from `Provider.baseUrlText`; when
     *   null each service falls back to its own default host.
     *   The chat path and the balance path differ per provider, so implementations must
     *   take the origin via [balanceOriginOf] and then append an absolute path. That
     *   avoids producing `/v1/v1/...`: a chat baseURL usually already ends in `/v1`,
     *   while the DeepSeek balance endpoint hangs off the root.
     */
    suspend fun fetchBalance(apiKey: String, baseURL: String? = null): ProviderBalance
}

/**
 * Extracts the origin (`scheme://host[:port]`) from the user's configured baseURL,
 * dropping any path. Balance endpoint paths are fixed, so building them off the origin
 * is what keeps them from colliding with the `/v1` suffix a chat baseURL carries.
 */
fun balanceOriginOf(baseURL: String?, fallbackOrigin: String): String {
    val raw = baseURL?.trim().orEmpty()
    if (raw.isNotEmpty()) {
        // Match how the chat path behaves. Users often type a bare host into baseURL,
        // such as `api.moonshot.cn/v1` with no scheme. OkHttp fills the scheme in for
        // chat, but URI.create on a bare string yields scheme=null and therefore
        // host=null, which drops us to the global-host fallback. A regional key then
        // gets a 401 from the global host and the UI wrongly reports "API Key invalid".
        val normalized = if (raw.startsWith("http://") || raw.startsWith("https://")) raw else "https://$raw"
        runCatching {
            val u = URI.create(normalized)
            val scheme = u.scheme
            val host = u.host
            if (!scheme.isNullOrBlank() && !host.isNullOrBlank()) {
                return if (u.port > 0) "$scheme://$host:${u.port}" else "$scheme://$host"
            }
        }
    }
    return fallbackOrigin
}

/**
 * Normalised view of a provider account balance.
 *
 * Fields:
 *   - `currency`: USD or CNY today, extensible.
 *   - `total`: the total balance. granted + topUp does not necessarily add up to it;
 *     whatever the upstream reports as the total wins.
 *   - `granted`: promotional credit or vouchers, used by SiliconFlow, DeepSeek and
 *     Moonshot. OpenRouter has no such concept, so it is null there.
 *   - `topUp`: credit the user paid for. Moonshot's cash_balance can go negative when
 *     the account is in arrears, which the UI needs to flag.
 *   - `totalUsage`: cumulative spend, OpenRouter only, from its `total_usage` field.
 *     Null everywhere else.
 *   - `fetchedAt`: the reference point for the cache, which reuses a value for five
 *     minutes.
 */
data class ProviderBalance(
    val currency: String,
    val total: Double,
    val granted: Double? = null,
    val topUp: Double? = null,
    val totalUsage: Double? = null,
    val fetchedAt: Instant,
)

/**
 * The providers whose accounts expose a balance endpoint, used by the UI to decide
 * whether to render the balance card. Keyed on [ProviderKind] rather than strings so a
 * typo cannot silently disable it.
 */
val BALANCE_CAPABLE_KINDS: Set<ProviderKind> = setOf(
    ProviderKind.OpenRouter,
    ProviderKind.SiliconFlow,
    ProviderKind.DeepSeek,
    ProviderKind.Moonshot,
)

/** Five minute balance cache shared by the provider list and the provider detail screen; it invalidates itself when the key or the regional endpoint changes. */
class ProviderBalanceRepository(
    private val services: Map<ProviderKind, BalanceQueryable>,
    private val now: () -> Instant = Instant::now,
    private val cacheTtl: Duration = Duration.ofMinutes(5),
) {
    private data class CacheEntry(
        val apiKey: String,
        val baseURL: String,
        val balance: ProviderBalance,
    )

    private val cache = ConcurrentHashMap<String, CacheEntry>()

    suspend fun fetchBalance(provider: Provider, forceRefresh: Boolean = false): ProviderBalance {
        require(provider.kind in BALANCE_CAPABLE_KINDS) {
            "Balance is not supported for ${provider.kind}"
        }
        val apiKey = provider.apiKey.trim()
        require(apiKey.isNotEmpty()) { "API key is empty" }
        val baseURL = provider.baseUrlText?.trim().orEmpty()

        if (!forceRefresh) {
            val cached = cache[provider.id]
            if (
                cached != null &&
                cached.apiKey == apiKey &&
                cached.baseURL == baseURL &&
                Duration.between(cached.balance.fetchedAt, now()) < cacheTtl
            ) {
                return cached.balance
            }
        }

        val service = requireNotNull(services[provider.kind]) {
            "Balance service is not registered for ${provider.kind}"
        }
        val fresh = service.fetchBalance(apiKey, baseURL.ifEmpty { null })
        cache[provider.id] = CacheEntry(apiKey = apiKey, baseURL = baseURL, balance = fresh)
        return fresh
    }

    fun retainProviders(validProviderIds: Set<String>) {
        cache.keys.removeIf { it !in validProviderIds }
    }

    internal fun clearForTesting() {
        cache.clear()
    }
}
