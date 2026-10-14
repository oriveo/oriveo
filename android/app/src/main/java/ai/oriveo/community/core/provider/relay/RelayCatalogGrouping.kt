package ai.oriveo.community.core.provider.relay

/** One group: when [label] is null it is "Other", and the UI takes the localized copy. */
data class RelayCatalogGroup<T>(val id: String, val label: String?, val items: List<T>)

/**
 * Relay model-library grouping (fixture `catalog-groups.v1.json`):
 * family = the family function given by the caller (production = cached Server by-model family -> [ai.oriveo.community.core.provider.RelayFamilyHeuristics],
 * i.e. [RelayKeyBinding.cachedFamily]); groups are ordered by first appearance in the catalog with "Other" last, and the catalog order is kept within a group.
 * The model library and add step 2 share this one function; official provider grouping does not come here.
 */
object RelayCatalogGrouping {
    const val OTHER_ID = "other"

    /** Group names are proper nouns and are not translated; a family missing from the table uses the family id itself. Verbatim identical to the fixture `labels`. */
    val LABELS: Map<String, String> = mapOf(
        "openai" to "OpenAI",
        "anthropic" to "Anthropic",
        "google" to "Google",
        "deepseek" to "DeepSeek",
        "xai" to "xAI",
        "qwen" to "Qwen",
        "mistral" to "Mistral",
        "minimax" to "MiniMax",
        "zhipu" to "Zhipu",
        "moonshot" to "Moonshot",
        "meta" to "Meta",
    )

    /** Relays often prefix the model id with a vendor (`anthropic/claude-x`); when the whole string does not identify a family, use the segment after the last `/`; used only for grouping, the family used for key binding is unchanged. */
    fun familyAllowingVendorPrefix(id: String, family: (String) -> String?): String? {
        family(id)?.trim()?.takeIf(String::isNotEmpty)?.let { return it }
        val tail = id.substringAfterLast('/', missingDelimiterValue = "")
        return if (tail.isEmpty()) null else family(tail)
    }

    fun <T> groups(rows: List<T>, modelID: (T) -> String, family: (String) -> String?): List<RelayCatalogGroup<T>> {
        val buckets = LinkedHashMap<String, MutableList<T>>()
        val other = mutableListOf<T>()
        for (row in rows) {
            val id = familyAllowingVendorPrefix(modelID(row), family)?.trim()?.takeIf(String::isNotEmpty)
            if (id == null || id == OTHER_ID) other += row else buckets.getOrPut(id) { mutableListOf() } += row
        }
        val named = buckets.map { (id, items) -> RelayCatalogGroup(id, LABELS[id] ?: id, items.toList()) }
        return if (other.isEmpty()) named else named + RelayCatalogGroup(OTHER_ID, null, other.toList())
    }
}
