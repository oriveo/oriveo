package ai.oriveo.community.core.app

/**
 * Registry of new-feature badges.
 *
 * The id list matches badges[].id in feature-badges.v1.json one to one (FeatureBadgesTest compares them).
 * A badge shows when its id is registered and not in this device's "seen" set; unregistered ids are dropped on read and write, so the set cannot only grow.
 */
object FeatureBadges {
    /** The "Memory" row in Settings, leading to the memory settings screen. */
    const val SETTINGS_MEMORY = "settings.memory.2026-10"

    /** The "Tools & Connections > Web Search" cell in Settings, leading to the web search page. */
    const val SETTINGS_WEB_SEARCH = "settings.webSearch.2026-10"

    val REGISTERED_IDS: List<String> = listOf(
        SETTINGS_MEMORY,
        SETTINGS_WEB_SEARCH,
    )

    /** Registered and not yet seen: show the badge. */
    fun isUnseen(id: String, seen: Set<String>): Boolean =
        id in REGISTERED_IDS && id !in seen

    /** Keeps only ids that are still in the registry. */
    fun pruned(seen: Set<String>): Set<String> =
        seen.filterTo(linkedSetOf()) { it in REGISTERED_IDS }

    /** The set after marking an id seen (unregistered ids are pruned too); an unregistered id is never written. */
    fun markSeen(seen: Set<String>, id: String): Set<String> =
        pruned(seen + id)
}
