package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ProviderKind
import io.ktor.client.HttpClient
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

/** Together usage shape contract: runs every case of the shared fixture together-usage-shapes.v1 through the service parser and the per-provider dispatch entry. */
class TogetherUsageShapesTest {

    private val json = Json { ignoreUnknownKeys = true }

    private val fixture: JsonObject by lazy {
        Json.parseToJsonElement(workspaceFile("shared/test-fixtures/provider-usage/together-usage-shapes.v1.json").readText()).jsonObject
    }

    private val cases: List<JsonObject> by lazy {
        fixture["cases"]!!.jsonArray.map { it.jsonObject }.also { assertEquals(4, it.size) }
    }

    @Test
    fun `all 4 Together usage fixture cases pass`() {
        val service = TogetherService(HttpClient(), json)
        cases.forEach { case ->
            val id = case["id"]!!.jsonPrimitive.content
            val usage = case["usage"]!!.jsonObject
            val expect = case["expect"]!!.jsonObject
            // Plain chat: TogetherService.parseUsage (shared by streaming and non-streaming)
            assertBreakdown("$id/service", expect, invokeParseUsage(service, usage))
            // Per-provider dispatch entry (the same entry tool-loop legs call)
            assertBreakdown("$id/dispatch", expect, ChatUsageParsers.openAIChat(ProviderKind.Together, usage))
        }
    }

    private fun assertBreakdown(label: String, expect: JsonObject, actual: UsageBreakdown) {
        assertEquals("$label promptTokens", expect["promptTokens"]!!.jsonPrimitive.int, actual.promptTokens)
        assertEquals("$label cachedInputTokens", expect["cachedInputTokens"]!!.jsonPrimitive.int, actual.cachedInputTokens)
        assertEquals("$label completionTokens", expect["completionTokens"]!!.jsonPrimitive.int, actual.completionTokens)
        assertEquals("$label reasoningTokens", expect["reasoningTokens"]!!.jsonPrimitive.int, actual.reasoningTokens)
        assertEquals("$label cacheReadObserved", expect["cacheReadObserved"]!!.jsonPrimitive.boolean, actual.cacheReadObserved)
    }

    /** Calls the protected parseUsage via reflection (same approach as CostCalculatorTest). */
    private fun invokeParseUsage(service: OpenAICompatibleService, usage: JsonObject?): UsageBreakdown {
        val method = OpenAICompatibleService::class.java.declaredMethods.first { it.name == "parseUsage" }
        method.isAccessible = true
        return method.invoke(service, usage) as UsageBreakdown
    }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("Cannot find $relative")
    }
}
