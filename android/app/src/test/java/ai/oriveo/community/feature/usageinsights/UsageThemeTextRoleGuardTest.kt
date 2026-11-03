package ai.oriveo.community.feature.usageinsights

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Theme-colored text on the usage page must use the light-surface text role
 * (`primaryTextSafe`); raw `primary` stays for icons, strokes and fills.
 * Also locks the tablet width cap on the budget card's provider list.
 */
class UsageThemeTextRoleGuardTest {

    private val guardedFiles = listOf(
        "feature/usageinsights/cards/BudgetCard.kt",
        "feature/usageinsights/UsageInsightsContent.kt",
        "feature/usageinsights/cards/UsageInsightsDemoCard.kt",
        "feature/usageinsights/cards/HeroCard.kt",
        "feature/usageinsights/sheets/ProviderFilterSheet.kt",
    )

    private val rawPrimary = Regex("""colors\.primary\b(?!TextSafe|FillText|Soft|Pressed|Active)""")
    private val textCall = Regex("""\bText\(""")

    @Test
    fun text_never_uses_raw_primary() {
        val offenders = mutableListOf<String>()
        for (file in guardedFiles) {
            val source = source(file)
            var callCount = 0
            for (match in textCall.findAll(source)) {
                callCount++
                val open = match.range.last
                val args = balancedArgs(source, open)
                if (rawPrimary.containsMatchIn(args)) {
                    val line = source.substring(0, open).count { it == '\n' } + 1
                    offenders += "$file:$line"
                }
            }
            assertTrue("$file: no Text( calls found, guard is not looking at the right file", callCount > 0)
        }
        assertTrue("Text uses raw colors.primary instead of primaryTextSafe at: $offenders", offenders.isEmpty())
    }

    @Test
    fun provider_budget_list_caps_width() {
        val source = source("feature/usageinsights/cards/BudgetCard.kt")
        val start = source.indexOf("private fun ProviderBudgetList(")
        assertTrue("ProviderBudgetList not found", start >= 0)
        val bodyOpen = source.indexOf('{', source.indexOf(')', start))
        val body = balanced(source, bodyOpen, '{', '}')
        assertTrue("ProviderBudgetList must cap width at 600.dp", body.contains("widthIn(max = 600.dp)"))
    }

    private fun balancedArgs(source: String, openParen: Int): String = balanced(source, openParen, '(', ')')

    private fun balanced(source: String, openIndex: Int, open: Char, close: Char): String {
        var depth = 0
        var i = openIndex
        while (i < source.length) {
            when (source[i]) {
                open -> depth++
                close -> {
                    depth--
                    if (depth == 0) return source.substring(openIndex, i + 1)
                }
            }
            i++
        }
        return source.substring(openIndex)
    }

    private fun source(relative: String): String =
        File("src/main/java/ai/oriveo/community/$relative").readText()
}
