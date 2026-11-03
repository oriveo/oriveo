package ai.oriveo.community.feature.usageinsights

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Success / danger text on light surfaces must use `colors.successText` / `colors.dangerText`;
 * raw `colors.success` / `colors.danger` stay reserved for icon tints, fills and strokes.
 * Scans every `Text(` call argument list in the usage insights screens and the skill improve
 * bar, plus the improve diff row label colors, and fails on any raw status color reference.
 */
class UsageStatusTextRoleGuardTest {

    private val files = listOf(
        "feature/usageinsights/BudgetDialog.kt",
        "feature/usageinsights/UsageInsightsScreen.kt",
        "feature/usageinsights/sheets/BudgetSettingSheet.kt",
        "feature/usageinsights/cards/InsightCard.kt",
        "feature/chat/components/SkillImprovePromptBar.kt",
    )

    private val textCall = Regex("""(?<![A-Za-z0-9_.])Text\(""")
    private val rawStatus = Regex("""colors\.(danger|success)\b(?!Text|Soft)""")

    // Diff row label colors: Triple(background, labelColor, labelRes).
    private val rawLabelColor = Regex("""Triple\(colors\.(danger|success)Soft,\s*colors\.(danger|success)\b(?!Text)""")

    @Test
    fun statusTextUsesTextRoles() {
        val violations = mutableListOf<String>()
        var scannedCalls = 0
        for (file in files) {
            val text = source(file)
            for (match in textCall.findAll(text)) {
                val args = argumentSegment(text, match.range.last)
                scannedCalls++
                if (rawStatus.containsMatchIn(args)) {
                    violations += "$file:${lineOf(text, match.range.first)}"
                }
            }
            for (match in rawLabelColor.findAll(text)) {
                violations += "$file:${lineOf(text, match.range.first)} (label color)"
            }
        }
        assertTrue("expected Text( calls to scan", scannedCalls > 0)
        assertTrue(
            "Status text must use colors.successText / colors.dangerText, not raw success / danger: $violations",
            violations.isEmpty(),
        )
    }

    /**
     * Over-budget amounts, percentages and alert copy on the usage cards must use
     * `colors.dangerText` regardless of font size; icons, progress bars and fills keep `danger`.
     */
    @Test
    fun overBudgetTextUsesDangerText() {
        val violations = mutableListOf<String>()
        val hero = source("feature/usageinsights/cards/HeroCard.kt")
        val budget = source("feature/usageinsights/cards/BudgetCard.kt")

        val alertBody = functionBody(hero, "forecastAlertText")
        if (rawDanger.containsMatchIn(alertBody) || !alertBody.contains("colors.dangerText")) {
            violations += "HeroCard.kt:forecastAlertText"
        }
        val statusBody = functionBody(budget, "budgetStatusTextColor")
        if (rawDanger.containsMatchIn(statusBody) || !statusBody.contains("colors.dangerText")) {
            violations += "BudgetCard.kt:budgetStatusTextColor"
        }
        val amountLine = Regex("""val amountColor\s*=[^\n]*""").find(budget)?.value
            ?: error("amountColor declaration not found in BudgetCard.kt")
        if (rawDanger.containsMatchIn(amountLine) || !amountLine.contains("colors.dangerText")) {
            violations += "BudgetCard.kt:amountColor"
        }
        for ((name, text) in listOf("HeroCard.kt" to hero, "BudgetCard.kt" to budget)) {
            for (match in textCall.findAll(text)) {
                val args = argumentSegment(text, match.range.last)
                // progressColor() returns the fill-oriented danger for the over-budget band,
                // so a text color may only fall back to it once dangerText covers that band.
                val ungatedFill = args.contains("progressColor(") && !args.contains("colors.dangerText")
                if (rawDanger.containsMatchIn(args) || ungatedFill) {
                    violations += "$name:${lineOf(text, match.range.first)}"
                }
            }
        }
        assertTrue(
            "Over-budget text must use colors.dangerText, not raw danger: $violations",
            violations.isEmpty(),
        )
    }

    /**
     * `progressColor()` is the fill palette (success / warning / danger) for progress bars; the
     * warning and success bands fall below AA as text on light surfaces, so no `Text(` on the
     * usage cards may take its color from it. Text goes through `budgetStatusTextColor()`.
     */
    @Test
    fun budgetTextNeverUsesProgressFill() {
        val violations = mutableListOf<String>()
        for (file in listOf("feature/usageinsights/cards/HeroCard.kt", "feature/usageinsights/cards/BudgetCard.kt")) {
            val text = source(file)
            for (match in textCall.findAll(text)) {
                if (argumentSegment(text, match.range.last).contains("progressColor(")) {
                    violations += "$file:${lineOf(text, match.range.first)}"
                }
            }
        }
        assertTrue(
            "Budget text must use budgetStatusTextColor(), not the progressColor() fill palette: $violations",
            violations.isEmpty(),
        )
    }

    private val rawDanger = Regex("""colors\.danger\b(?!Text|Soft)""")

    /** Returns the brace-balanced body of `fun name(`. */
    private fun functionBody(text: String, name: String): String {
        val start = Regex("""fun $name\(""").find(text)?.range?.first
            ?: error("fun $name not found")
        val open = text.indexOf('{', start)
        var depth = 0
        for (i in open until text.length) {
            when (text[i]) {
                '{' -> depth++
                '}' -> {
                    depth--
                    if (depth == 0) return text.substring(open, i + 1)
                }
            }
        }
        return text.substring(open)
    }

    private fun lineOf(text: String, index: Int): Int =
        text.substring(0, index).count { it == '\n' } + 1

    /** Returns the text from the opening parenthesis to its balanced closing parenthesis. */
    private fun argumentSegment(text: String, openIndex: Int): String {
        var depth = 0
        for (i in openIndex until text.length) {
            when (text[i]) {
                '(' -> depth++
                ')' -> {
                    depth--
                    if (depth == 0) return text.substring(openIndex, i + 1)
                }
            }
        }
        return text.substring(openIndex)
    }

    private fun source(file: String): String =
        File("src/main/java/ai/oriveo/community/$file").readText()
}
