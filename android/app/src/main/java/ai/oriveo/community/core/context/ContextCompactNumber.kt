package ai.oriveo.community.core.context

/** One compact tier: values from [min] use [pattern] ([few] for the Arabic 3...10 plural form). */
data class ContextCompactTier(val min: Long, val pattern: String, val few: String? = null)

/** Per-language compact number table: decimal / group separators and ten tiers from 10^3 to 10^12. */
data class ContextCompactLocale(val decimal: String, val group: String, val tiers: List<ContextCompactTier>)

/**
 * Compact token counts by app language (shared fixture compact-number.v1).
 * The table is a CLDR snapshot shipped in code; platform ICU / CompactDecimalFormat is not used because
 * Android's CLDR follows the OS version. Always rounds down with integer arithmetic.
 */
object ContextCompactNumber {

    const val DEFAULT_LOCALE = "en"

    private const val MAX_VALUE = 1_000_000_000_000_000L

    /** Fixture `locales`, same keys, order and patterns (U+00A0 kept as is). */
    val TABLE: Map<String, ContextCompactLocale> = linkedMapOf(
        "zh-Hans" to ContextCompactLocale(
            decimal = ".",
            group = ",",
            tiers = listOf(
                ContextCompactTier(1000L, "0"),
                ContextCompactTier(10000L, "0万"),
                ContextCompactTier(100000L, "00万"),
                ContextCompactTier(1000000L, "000万"),
                ContextCompactTier(10000000L, "0000万"),
                ContextCompactTier(100000000L, "0亿"),
                ContextCompactTier(1000000000L, "00亿"),
                ContextCompactTier(10000000000L, "000亿"),
                ContextCompactTier(100000000000L, "0000亿"),
                ContextCompactTier(1000000000000L, "0万亿"),
            ),
        ),
        "zh-Hant" to ContextCompactLocale(
            decimal = ".",
            group = ",",
            tiers = listOf(
                ContextCompactTier(1000L, "0"),
                ContextCompactTier(10000L, "0萬"),
                ContextCompactTier(100000L, "00萬"),
                ContextCompactTier(1000000L, "000萬"),
                ContextCompactTier(10000000L, "0000萬"),
                ContextCompactTier(100000000L, "0億"),
                ContextCompactTier(1000000000L, "00億"),
                ContextCompactTier(10000000000L, "000億"),
                ContextCompactTier(100000000000L, "0000億"),
                ContextCompactTier(1000000000000L, "0兆"),
            ),
        ),
        "en" to ContextCompactLocale(
            decimal = ".",
            group = ",",
            tiers = listOf(
                ContextCompactTier(1000L, "0K"),
                ContextCompactTier(10000L, "00K"),
                ContextCompactTier(100000L, "000K"),
                ContextCompactTier(1000000L, "0M"),
                ContextCompactTier(10000000L, "00M"),
                ContextCompactTier(100000000L, "000M"),
                ContextCompactTier(1000000000L, "0B"),
                ContextCompactTier(10000000000L, "00B"),
                ContextCompactTier(100000000000L, "000B"),
                ContextCompactTier(1000000000000L, "0T"),
            ),
        ),
        "ja" to ContextCompactLocale(
            decimal = ".",
            group = ",",
            tiers = listOf(
                ContextCompactTier(1000L, "0"),
                ContextCompactTier(10000L, "0万"),
                ContextCompactTier(100000L, "00万"),
                ContextCompactTier(1000000L, "000万"),
                ContextCompactTier(10000000L, "0000万"),
                ContextCompactTier(100000000L, "0億"),
                ContextCompactTier(1000000000L, "00億"),
                ContextCompactTier(10000000000L, "000億"),
                ContextCompactTier(100000000000L, "0000億"),
                ContextCompactTier(1000000000000L, "0兆"),
            ),
        ),
        "ko" to ContextCompactLocale(
            decimal = ".",
            group = ",",
            tiers = listOf(
                ContextCompactTier(1000L, "0천"),
                ContextCompactTier(10000L, "0만"),
                ContextCompactTier(100000L, "00만"),
                ContextCompactTier(1000000L, "000만"),
                ContextCompactTier(10000000L, "0000만"),
                ContextCompactTier(100000000L, "0억"),
                ContextCompactTier(1000000000L, "00억"),
                ContextCompactTier(10000000000L, "000억"),
                ContextCompactTier(100000000000L, "0000억"),
                ContextCompactTier(1000000000000L, "0조"),
            ),
        ),
        "de" to ContextCompactLocale(
            decimal = ",",
            group = ".",
            tiers = listOf(
                ContextCompactTier(1000L, "0"),
                ContextCompactTier(10000L, "0"),
                ContextCompactTier(100000L, "0"),
                ContextCompactTier(1000000L, "0\u00A0Mio."),
                ContextCompactTier(10000000L, "00\u00A0Mio."),
                ContextCompactTier(100000000L, "000\u00A0Mio."),
                ContextCompactTier(1000000000L, "0\u00A0Mrd."),
                ContextCompactTier(10000000000L, "00\u00A0Mrd."),
                ContextCompactTier(100000000000L, "000\u00A0Mrd."),
                ContextCompactTier(1000000000000L, "0\u00A0Bio."),
            ),
        ),
        "fr" to ContextCompactLocale(
            decimal = ",",
            group = "\u202F",
            tiers = listOf(
                ContextCompactTier(1000L, "0\u00A0k"),
                ContextCompactTier(10000L, "00\u00A0k"),
                ContextCompactTier(100000L, "000\u00A0k"),
                ContextCompactTier(1000000L, "0\u00A0M"),
                ContextCompactTier(10000000L, "00\u00A0M"),
                ContextCompactTier(100000000L, "000\u00A0M"),
                ContextCompactTier(1000000000L, "0\u00A0Md"),
                ContextCompactTier(10000000000L, "00\u00A0Md"),
                ContextCompactTier(100000000000L, "000\u00A0Md"),
                ContextCompactTier(1000000000000L, "0\u00A0Bn"),
            ),
        ),
        "es" to ContextCompactLocale(
            decimal = ",",
            group = ".",
            tiers = listOf(
                ContextCompactTier(1000L, "0\u00A0mil"),
                ContextCompactTier(10000L, "00\u00A0mil"),
                ContextCompactTier(100000L, "000\u00A0mil"),
                ContextCompactTier(1000000L, "0\u00A0M"),
                ContextCompactTier(10000000L, "00\u00A0M"),
                ContextCompactTier(100000000L, "000\u00A0M"),
                ContextCompactTier(1000000000L, "0000\u00A0M"),
                ContextCompactTier(10000000000L, "00\u00A0mil\u00A0M"),
                ContextCompactTier(100000000000L, "000\u00A0mil\u00A0M"),
                ContextCompactTier(1000000000000L, "0\u00A0B"),
            ),
        ),
        "pt-BR" to ContextCompactLocale(
            decimal = ",",
            group = ".",
            tiers = listOf(
                ContextCompactTier(1000L, "0\u00A0mil"),
                ContextCompactTier(10000L, "00\u00A0mil"),
                ContextCompactTier(100000L, "000\u00A0mil"),
                ContextCompactTier(1000000L, "0\u00A0mi"),
                ContextCompactTier(10000000L, "00\u00A0mi"),
                ContextCompactTier(100000000L, "000\u00A0mi"),
                ContextCompactTier(1000000000L, "0\u00A0bi"),
                ContextCompactTier(10000000000L, "00\u00A0bi"),
                ContextCompactTier(100000000000L, "000\u00A0bi"),
                ContextCompactTier(1000000000000L, "0\u00A0tri"),
            ),
        ),
        "ru" to ContextCompactLocale(
            decimal = ",",
            group = "\u00A0",
            tiers = listOf(
                ContextCompactTier(1000L, "0\u00A0тыс."),
                ContextCompactTier(10000L, "00\u00A0тыс."),
                ContextCompactTier(100000L, "000\u00A0тыс."),
                ContextCompactTier(1000000L, "0\u00A0млн"),
                ContextCompactTier(10000000L, "00\u00A0млн"),
                ContextCompactTier(100000000L, "000\u00A0млн"),
                ContextCompactTier(1000000000L, "0\u00A0млрд"),
                ContextCompactTier(10000000000L, "00\u00A0млрд"),
                ContextCompactTier(100000000000L, "000\u00A0млрд"),
                ContextCompactTier(1000000000000L, "0\u00A0трлн"),
            ),
        ),
        "tr" to ContextCompactLocale(
            decimal = ",",
            group = ".",
            tiers = listOf(
                ContextCompactTier(1000L, "0\u00A0B"),
                ContextCompactTier(10000L, "00\u00A0B"),
                ContextCompactTier(100000L, "000\u00A0B"),
                ContextCompactTier(1000000L, "0\u00A0Mn"),
                ContextCompactTier(10000000L, "00\u00A0Mn"),
                ContextCompactTier(100000000L, "000\u00A0Mn"),
                ContextCompactTier(1000000000L, "0\u00A0Mr"),
                ContextCompactTier(10000000000L, "00\u00A0Mr"),
                ContextCompactTier(100000000000L, "000\u00A0Mr"),
                ContextCompactTier(1000000000000L, "0\u00A0Tn"),
            ),
        ),
        "id" to ContextCompactLocale(
            decimal = ",",
            group = ".",
            tiers = listOf(
                ContextCompactTier(1000L, "0\u00A0rb"),
                ContextCompactTier(10000L, "00\u00A0rb"),
                ContextCompactTier(100000L, "000\u00A0rb"),
                ContextCompactTier(1000000L, "0\u00A0jt"),
                ContextCompactTier(10000000L, "00\u00A0jt"),
                ContextCompactTier(100000000L, "000\u00A0jt"),
                ContextCompactTier(1000000000L, "0\u00A0M"),
                ContextCompactTier(10000000000L, "00\u00A0M"),
                ContextCompactTier(100000000000L, "000\u00A0M"),
                ContextCompactTier(1000000000000L, "0\u00A0T"),
            ),
        ),
        "vi" to ContextCompactLocale(
            decimal = ",",
            group = ".",
            tiers = listOf(
                ContextCompactTier(1000L, "0\u00A0N"),
                ContextCompactTier(10000L, "00\u00A0N"),
                ContextCompactTier(100000L, "000\u00A0N"),
                ContextCompactTier(1000000L, "0\u00A0Tr"),
                ContextCompactTier(10000000L, "00\u00A0Tr"),
                ContextCompactTier(100000000L, "000\u00A0Tr"),
                ContextCompactTier(1000000000L, "0\u00A0T"),
                ContextCompactTier(10000000000L, "00\u00A0T"),
                ContextCompactTier(100000000000L, "000\u00A0T"),
                ContextCompactTier(1000000000000L, "0\u00A0NT"),
            ),
        ),
        "th" to ContextCompactLocale(
            decimal = ".",
            group = ",",
            tiers = listOf(
                ContextCompactTier(1000L, "0K"),
                ContextCompactTier(10000L, "00K"),
                ContextCompactTier(100000L, "000K"),
                ContextCompactTier(1000000L, "0M"),
                ContextCompactTier(10000000L, "00M"),
                ContextCompactTier(100000000L, "000M"),
                ContextCompactTier(1000000000L, "0B"),
                ContextCompactTier(10000000000L, "00B"),
                ContextCompactTier(100000000000L, "000B"),
                ContextCompactTier(1000000000000L, "0T"),
            ),
        ),
        "hi" to ContextCompactLocale(
            decimal = ".",
            group = ",",
            tiers = listOf(
                ContextCompactTier(1000L, "0\u00A0हज़ार"),
                ContextCompactTier(10000L, "00\u00A0हज़ार"),
                ContextCompactTier(100000L, "0\u00A0लाख"),
                ContextCompactTier(1000000L, "00\u00A0लाख"),
                ContextCompactTier(10000000L, "0\u00A0क॰"),
                ContextCompactTier(100000000L, "00\u00A0क॰"),
                ContextCompactTier(1000000000L, "0\u00A0अ॰"),
                ContextCompactTier(10000000000L, "00\u00A0अ॰"),
                ContextCompactTier(100000000000L, "0\u00A0ख॰"),
                ContextCompactTier(1000000000000L, "00\u00A0ख॰"),
            ),
        ),
        "ar" to ContextCompactLocale(
            decimal = ".",
            group = ",",
            tiers = listOf(
                ContextCompactTier(1000L, "0\u00A0ألف", few = "0\u00A0آلاف"),
                ContextCompactTier(10000L, "00\u00A0ألف"),
                ContextCompactTier(100000L, "000\u00A0ألف"),
                ContextCompactTier(1000000L, "0\u00A0مليون"),
                ContextCompactTier(10000000L, "00\u00A0مليون"),
                ContextCompactTier(100000000L, "000\u00A0مليون"),
                ContextCompactTier(1000000000L, "0\u00A0مليار"),
                ContextCompactTier(10000000000L, "00\u00A0مليار"),
                ContextCompactTier(100000000000L, "000\u00A0مليار"),
                ContextCompactTier(1000000000000L, "0\u00A0ترليون"),
            ),
        ),
    )

    /** Maps a language tag to one of the 16 table codes; anything unknown or empty falls back to "en". */
    fun resolveLocale(tag: String): String {
        val subtags = mutableListOf<String>()
        for (part in tag.substringBefore('@').replace('_', '-').split('-')) {
            if (part.length == 1) break
            subtags += part.lowercase()
        }
        val language = subtags.firstOrNull().orEmpty()
        return when {
            language.isEmpty() -> DEFAULT_LOCALE
            language == "zh" -> {
                // Script subtag wins; only without one does the region decide (zh-Hans-HK stays Simplified).
                val rest = subtags.drop(1)
                when {
                    "hans" in rest -> "zh-Hans"
                    "hant" in rest -> "zh-Hant"
                    rest.any { it in TRADITIONAL_REGIONS } -> "zh-Hant"
                    else -> "zh-Hans"
                }
            }
            language == "pt" -> "pt-BR"
            language == "in" -> "id"
            language in TABLE -> language
            else -> DEFAULT_LOCALE
        }
    }

    /** Compact text of [value] for [locale] (any language tag); negative counts as 0, above 10^15 as 10^15. */
    fun format(value: Long, locale: String): String {
        val v = value.coerceIn(0L, MAX_VALUE)
        if (v < 1_000L) return v.toString()
        val table = TABLE.getValue(resolveLocale(locale))
        val tier = table.tiers.last { it.min <= v }
        val zeros = zeroRun(tier.pattern)
        if (zeros.length == tier.pattern.length) {
            return if (v >= 10_000L) grouped(v, table.group) else v.toString()
        }
        // unit10 = unit / 10 = min / 10^(z-1) / 10, always an integer >= 100.
        var unit10 = tier.min
        repeat(zeros.length) { unit10 /= 10L }
        val tenths = v / unit10
        val whole = tenths / 10L
        val frac = tenths % 10L
        val number = if (frac == 0L) whole.toString() else "$whole${table.decimal}$frac"
        val pattern = tier.few?.takeIf { frac == 0L && whole % 100L in 3L..10L } ?: tier.pattern
        return pattern.replaceFirst(zeroRun(pattern), number)
    }

    private val TRADITIONAL_REGIONS = setOf("tw", "hk", "mo")

    private fun zeroRun(pattern: String): String {
        val start = pattern.indexOf('0')
        var end = start
        while (end < pattern.length && pattern[end] == '0') end++
        return pattern.substring(start, end)
    }

    private fun grouped(value: Long, separator: String): String {
        val digits = value.toString()
        val head = digits.length % 3
        val groups = mutableListOf<String>()
        if (head > 0) groups += digits.substring(0, head)
        var i = head
        while (i < digits.length) {
            groups += digits.substring(i, i + 3)
            i += 3
        }
        return groups.joinToString(separator)
    }
}
