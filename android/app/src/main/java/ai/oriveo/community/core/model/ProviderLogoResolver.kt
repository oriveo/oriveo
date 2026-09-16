package ai.oriveo.community.core.model

import androidx.annotation.VisibleForTesting
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicInteger

/**
 * Infers the brand logo to show for a relay provider.
 *
 * An official kind answers itself; only a relay has to be guessed at, by concatenating the display
 * name, the base URL and the group key, group name, id and name of **every** model into one string
 * and running `contains` over it. A relay with many models produces tens of kilobytes, and the
 * `when` below performs close to forty substring scans, each one linear in that length.
 *
 * ## Why the in-process cache
 *
 * Provider cards and model pickers already wrap the call in `remember(provider)`, but cost
 * summaries run it on a background thread and the chat screen's model sheet calls it bare, so the
 * same provider is scanned several times within one pass.
 *
 * One entry is cached per provider id and a hit has to clear two gates:
 * 1. **The same `Provider` instance** (a weak reference compared by identity), which is the normal
 *    case when one render or one calculation asks about the same provider repeatedly. Not even the
 *    hint string has to be rebuilt. The reference is weak so the cache never pins a provider in
 *    memory.
 * 2. If the instance differs, the hints are rebuilt and compared **by content** — a re-emission
 *    from the database produces a new but identical instance, and this gate makes those pay for one
 *    hint build instead of forty substring scans.
 *
 * Only when both gates miss is a real scan performed. The branches of the `when` and their order
 * are unchanged; the cache only remembers the outcome of the same decision.
 */
fun resolveProviderLogoKind(provider: Provider): ProviderKind {
    if (provider.kind != ProviderKind.Relay) return provider.kind

    val cached = synchronized(relayLogoCache) { relayLogoCache[provider.id] }
    if (cached != null && cached.source.get() === provider) return cached.kind

    val fallback = provider.relayKind?.let(::relayKindLogoKind) ?: ProviderKind.Relay
    val hints = relayLogoHints(provider)
    if (hints.isEmpty()) return fallback
    if (cached != null && cached.hints == hints && cached.fallback == fallback) {
        synchronized(relayLogoCache) {
            relayLogoCache[provider.id] = cached.copyingSource(provider)
        }
        return cached.kind
    }

    relayLogoScanCount.incrementAndGet()
    val resolved = matchRelayLogoKind(hints) ?: fallback
    synchronized(relayLogoCache) {
        relayLogoCache[provider.id] = RelayLogoCacheEntry(WeakReference(provider), hints, fallback, resolved)
    }
    return resolved
}

private fun relayLogoHints(provider: Provider): String = buildList {
    add(provider.displayName)
    provider.baseUrlText?.let(::add)
    provider.models.forEach { model ->
        model.groupKey?.let(::add)
        model.groupName?.let(::add)
        add(model.id)
        add(model.name)
    }
}.joinToString(" ").lowercase()

/** Null means no brand matched, and the caller falls back to the relay kind. Branch order is load-bearing. */
private fun matchRelayLogoKind(hints: String): ProviderKind? {
    fun has(vararg needles: String): Boolean = needles.any { hints.contains(it) }

    return when {
        has("kimi", "moonshot", "moonshot.ai", "moonshot.cn") -> ProviderKind.Moonshot
        has("grok", "xai", "x.ai") -> ProviderKind.Grok

        has("mistral", "mixtral", "codestral", "magistral", "devstral", "ministral", "pixtral") -> ProviderKind.Mistral
        has("openrouter") -> ProviderKind.OpenRouter
        has("openai", "gpt", "chatgpt") || has(" o1", " o3", " o4") -> ProviderKind.OpenAI
        has("anthropic", "claude") -> ProviderKind.Anthropic
        has("gemini", "google", "generativelanguage") -> ProviderKind.Gemini
        has("deepseek") -> ProviderKind.DeepSeek
        has("qwen", "dashscope", "aliyun", "alibaba") -> ProviderKind.Qwen
        has("groq") -> ProviderKind.Groq
        has("together") -> ProviderKind.Together
        has("fireworks") -> ProviderKind.Fireworks
        has("minimax", "minimaxi") -> ProviderKind.MiniMax
        has("zhipu", "z.ai", "bigmodel", "glm") -> ProviderKind.Zhipu
        has("siliconflow") -> ProviderKind.SiliconFlow
        else -> null
    }
}

private class RelayLogoCacheEntry(
    val source: WeakReference<Provider>,
    val hints: String,
    val fallback: ProviderKind,
    val kind: ProviderKind,
) {
    fun copyingSource(provider: Provider) = RelayLogoCacheEntry(WeakReference(provider), hints, fallback, kind)
}

/** Sized after how many relays one person plausibly adds; beyond that the least recently used entry goes. */
private const val RELAY_LOGO_CACHE_MAX_ENTRIES = 64

private val relayLogoCache = object : LinkedHashMap<String, RelayLogoCacheEntry>(16, 0.75f, true) {
    override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, RelayLogoCacheEntry>): Boolean =
        size > RELAY_LOGO_CACHE_MAX_ENTRIES
}

/**
 * How many real scans happened; only a cache miss increments it. This counter is the one side
 * effect on the production path, and it exists because "the same fingerprint is scanned once" can
 * only be reported by the production code itself — a test that synthesised the number would be
 * proving nothing.
 */
@VisibleForTesting
internal val relayLogoScanCount = AtomicInteger(0)

@VisibleForTesting
internal fun resetRelayLogoCache() {
    synchronized(relayLogoCache) { relayLogoCache.clear() }
    relayLogoScanCount.set(0)
}

private fun relayKindLogoKind(relayKind: RelayKind): ProviderKind? = when (relayKind) {
    RelayKind.OpenAICompatible,
    RelayKind.CodexStyle,
    -> ProviderKind.OpenAI
    RelayKind.AnthropicCompatible -> ProviderKind.Anthropic
    RelayKind.GeminiCompatible -> ProviderKind.Gemini
    RelayKind.Custom -> null
}
