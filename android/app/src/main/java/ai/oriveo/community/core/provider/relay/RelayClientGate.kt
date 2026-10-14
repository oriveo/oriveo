package ai.oriveo.community.core.provider.relay

/**
 * Official CLI gate (fixture `negative-cache.v1.json` clientGateRules): a 403 before any output whose response body contains a registered phrase means
 * the group this key belongs to only admits the official CLI. It is neither a key problem (key-access judges none) nor a route-level rejection (no protocol switch),
 * so only a relay hint is shown; official providers do not go through here. Oriveo neither sends nor impersonates any CLI identity.
 */
object RelayClientGate {
    val statuses: Set<Int> = setOf(403)

    /** Word for word as in the fixture; comparison is case-insensitive, after restoring the JSON-escaped `\/` to `/`. */
    val phrases: List<String> = listOf(
        "official claude cli",
        "restricted to claude code clients",
        "标准 claude code 客户端",
    )

    fun isClientGated(status: Int, body: String): Boolean {
        if (status !in statuses) return false
        val lower = body.replace("\\/", "/").lowercase()
        return phrases.any { lower.contains(it) }
    }
}
