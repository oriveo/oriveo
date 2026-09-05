package ai.oriveo.community.core.provider

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

class ToolUnsupportedErrorMatcherContractTest {
    @Serializable private data class Fixture(val rules: Rules, val cases: List<Case>)
    @Serializable private data class Rules(
        val subject_patterns: List<String>,
        val verdict_patterns: List<String>,
    )
    @Serializable private data class Case(
        val id: String,
        val status: Int,
        val body: String,
        val expect: Boolean,
    )

    @Test
    fun `runtime patterns and verdicts match the shared unsupported tools contract`() {
        val fixture = Json { ignoreUnknownKeys = true }.decodeFromString<Fixture>(fixtureFile().readText())
        assertEquals(fixture.rules.subject_patterns, ToolUnsupportedErrorMatcher.subjectPatterns)
        assertEquals(fixture.rules.verdict_patterns, ToolUnsupportedErrorMatcher.verdictPatterns)
        fixture.cases.forEach { case ->
            assertEquals(case.id, case.expect, ToolUnsupportedErrorMatcher.matches(case.status, case.body))
        }
    }

    private fun fixtureFile(): File {
        val moduleDir = File(System.getProperty("user.dir") ?: ".").absoluteFile
        val repoRoot = moduleDir.parentFile!!.parentFile!!
        return File(repoRoot, "shared/test-fixtures/provider-toolcall/tool-unsupported-4xx.json")
            .also { require(it.exists()) { "fixture not found at: ${it.absolutePath}" } }
    }
}
