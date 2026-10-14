package ai.oriveo.community.feature.providers.detail

import ai.oriveo.community.R
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.relay.RelayCapabilityTest
import ai.oriveo.community.core.provider.relay.RelayCapabilityTestItemResult
import ai.oriveo.community.core.provider.relay.RelayCapabilityTestKind
import ai.oriveo.community.core.provider.relay.RelayCapabilityTestReason
import ai.oriveo.community.core.provider.relay.RelayCapabilityTestStopReason
import ai.oriveo.community.core.provider.relay.RelayCapabilityVerdict
import ai.oriveo.community.core.provider.relay.RelayWebSource
import java.nio.file.Files
import java.nio.file.Paths
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure presentation rules of the Test capabilities bottom panel (fixture `capability-test.v1.json` `panelCases`).
 * Each `RD4-PANEL-<caseId>`: the input is fed unchanged to production [RelayCapabilityTestPanelModel.present],
 * and the string id (Android resource name) is mapped to this platform's resource id by R-class reflection before comparing.
 */
class RelayCapabilityTestPanelTest {
    private val fixture: JsonObject by lazy {
        var dir = Paths.get("").toAbsolutePath()
        repeat(8) {
            val candidate = dir.resolve("shared/test-fixtures/relay/capability-test.v1.json")
            if (Files.exists(candidate)) {
                return@lazy Json.parseToJsonElement(String(Files.readAllBytes(candidate), Charsets.UTF_8)).jsonObject
            }
            dir = dir.parent ?: return@repeat
        }
        throw IllegalStateException("capability-test.v1.json not found")
    }

    private fun case(caseId: String): JsonObject =
        fixture.getValue("panelCases").jsonObject.getValue("cases").jsonArray.map { it.jsonObject }
            .single { it.getValue("caseId").jsonPrimitive.content == caseId }

    @Test fun `RD4-PANEL-running_second_of_three`() = check("running_second_of_three")
    @Test fun `RD4-PANEL-completed_board`() = check("completed_board")
    @Test fun `RD4-PANEL-completed_nothing_saved_single_key`() = check("completed_nothing_saved_single_key")
    @Test fun `RD4-PANEL-running_first_single_key_image_user_set`() = check("running_first_single_key_image_user_set")
    @Test fun `RD4-PANEL-text_not_found`() = check("text_not_found")
    @Test fun `RD4-PANEL-text_rejected_422`() = check("text_rejected_422")
    @Test fun `RD4-PANEL-text_unauthorized`() = check("text_unauthorized")
    @Test fun `RD4-PANEL-stopped_cancelled_during_tool`() = check("stopped_cancelled_during_tool")
    @Test fun `RD4-PANEL-stopped_connection_changed_before_write`() = check("stopped_connection_changed_before_write")
    @Test fun `RD4-PANEL-stopped_protocol_changed`() = check("stopped_protocol_changed")
    @Test fun `RD4-PANEL-stopped_model_unavailable`() = check("stopped_model_unavailable")
    @Test fun `RD4-PANEL-completed_not_observed_single_key`() = check("completed_not_observed_single_key")

    // Web is the 4th item.
    @Test fun `RD4-PANEL-running_web_after_not_observed`() = check("running_web_after_not_observed")
    @Test fun `RD4-PANEL-running_text_named_key_with_web`() = check("running_text_named_key_with_web")
    @Test fun `RD4-PANEL-completed_web_searched`() = check("completed_web_searched")
    @Test fun `RD4-PANEL-completed_web_silent_nothing_saved`() = check("completed_web_silent_nothing_saved")
    @Test fun `RD4-PANEL-completed_web_rejected`() = check("completed_web_rejected")
    @Test fun `RD4-PANEL-text_failed_web_not_run`() = check("text_failed_web_not_run")

    // With no stored fragment the web item is tested with the protocol template, which is the effective fragment.
    @Test fun `RD4-PANEL-running_web_template`() = check("running_web_template")
    @Test fun `RD4-PANEL-completed_web_template_searched`() = check("completed_web_template_searched")
    @Test fun `RD4-PANEL-completed_web_template_silent`() = check("completed_web_template_silent")
    @Test fun `RD4-PANEL-completed_web_template_rejected`() = check("completed_web_template_rejected")

    @Test
    fun `RD4-PANEL every fixture case has a named test`() {
        val ids = fixture.getValue("panelCases").jsonObject.getValue("cases").jsonArray.map { it.jsonObject.getValue("caseId").jsonPrimitive.content }
        val named = javaClass.declaredMethods.map { it.name }.filter { it.startsWith("RD4-PANEL-") }.map { it.removePrefix("RD4-PANEL-") }
        assertEquals(ids.toSet(), named.toSet())
    }

    private fun kindOf(wire: String): RelayCapabilityTestKind =
        if (wire == "toolCall") RelayCapabilityTestKind.Tool else RelayCapabilityTestKind.entries.single { it.wire == wire }

    private fun panelWire(kind: RelayCapabilityTestKind): String = if (kind == RelayCapabilityTestKind.Tool) "toolCall" else kind.wire

    private fun JsonElement?.stringOrNull(): String? = (this as? JsonPrimitive)?.takeUnless { it is JsonNull }?.content

    private fun res(name: String): Int = runCatching { R.string::class.java.getField(name).getInt(null) }
        .recoverCatching { R.plurals::class.java.getField(name).getInt(null) }
        .getOrElse { throw AssertionError("No resource $name") }

    private fun check(caseId: String) {
        val case = case(caseId)
        val transport = RelayTransport.entries.single {
            RelayCapabilityTest.shortName(it) == case.getValue("transport").jsonPrimitive.content
        }
        val results = case["results"]?.jsonObject.orEmpty().map { (key, value) ->
            val result = value.jsonObject
            RelayCapabilityTestItemResult(
                kind = kindOf(key),
                verdict = RelayCapabilityVerdict.entries.single { it.wire == result.getValue("verdict").jsonPrimitive.content },
                reason = RelayCapabilityTestReason.entries.single { it.wire == result.getValue("reason").jsonPrimitive.content },
                status = result["status"].stringOrNull()?.toInt(),
                elapsedMs = result.getValue("elapsedMs").jsonPrimitive.content.toLong(),
            )
        }
        val running = case["running"]?.jsonObject
        val input = RelayCapTestPanelInput(
            transport = transport,
            items = case.getValue("items").jsonArray.map { kindOf(it.jsonPrimitive.content) },
            keyName = case["keyName"].stringOrNull(),
            phase = RelayCapTestPhase.entries.single { it.name.lowercase() == case.getValue("phase").jsonPrimitive.content },
            results = results,
            running = running?.let { kindOf(it.getValue("kind").jsonPrimitive.content) },
            runningElapsedMs = running?.getValue("elapsedMs")?.jsonPrimitive?.content?.toLong() ?: 0L,
            written = case["written"].stringOrNull()?.toBooleanStrict() ?: false,
            stopReason = case["stopReason"].stringOrNull()?.let { wire -> RelayCapabilityTestStopReason.entries.single { it.wire == wire } },
            // Default = saved.
            webSource = case["webSource"].stringOrNull()?.let { wire -> RelayWebSource.entries.single { it.wire == wire } } ?: RelayWebSource.Saved,
        )
        val actual = RelayCapabilityTestPanelModel.present(input)
        val expect = case.getValue("expect").jsonObject

        val header = expect.getValue("header")
        val expectedHeader = when {
            header is JsonObject -> header.getValue("progress").jsonArray.map { it.jsonPrimitive.content.toInt() }
                .let { RelayCapTestHeader.Progress(it[0], it[1]) }
            header.jsonPrimitive.content == "done" -> RelayCapTestHeader.Done
            else -> RelayCapTestHeader.Stopped
        }
        assertEquals("$caseId: header", expectedHeader, actual.header)
        val fraction = expect.getValue("progressFraction").jsonArray.map { it.jsonPrimitive.content.toInt() }
        assertEquals("$caseId: progressFraction", fraction[0] to fraction[1], actual.progressFraction)
        val chips = expect.getValue("chips").jsonObject
        assertEquals("$caseId: protocol chip", chips.getValue("transport").jsonPrimitive.content, RelayCapabilityTest.shortName(actual.transport))
        assertEquals("$caseId: key chip", chips["key"].stringOrNull(), actual.keyName)

        val rows = expect.getValue("rows").jsonArray.map { it.jsonObject }
        assertEquals("$caseId: row count", rows.size, actual.rows.size)
        rows.zip(actual.rows).forEach { (row, got) ->
            val label = "$caseId/${row.getValue("kind").jsonPrimitive.content}"
            assertEquals("$label: kind", row.getValue("kind").jsonPrimitive.content, panelWire(got.kind))
            assertEquals("$label: icon", row.getValue("icon").jsonPrimitive.content, got.icon.name.replaceFirstChar { it.lowercase() })
            assertEquals("$label: subtitle", row["subtitle"].stringOrNull()?.let(::res), got.subtitle)
            val expectedArg = row["subtitleArg"].stringOrNull()?.let { arg ->
                when {
                    arg.all(Char::isDigit) -> RelayCapTestArg.Code(arg.toInt())
                    ':' in arg -> RelayCapTestArg.Text(res(arg.substringBefore(':')), arg.substringAfter(':').toInt())
                    else -> RelayCapTestArg.Text(res(arg))
                }
            }
            assertEquals("$label: subtitleArg", expectedArg, got.subtitleArg)
            val trailing = when (val t = got.trailing) {
                null -> null
                RelayCapTestTrailing.Waiting -> "waiting"
                is RelayCapTestTrailing.Elapsed -> "elapsed:${t.tenths / 10}.${t.tenths % 10}"
                is RelayCapTestTrailing.Running -> "running:${t.tenths / 10}.${t.tenths % 10}"
            }
            assertEquals("$label: trailing", row["trailing"].stringOrNull(), trailing)
            // The panel's "turn on web search" is gone: fixture rows no longer have action / note.
            assertTrue("$label: no action / note", "action" !in row && "note" !in row)
        }

        val footer = expect.getValue("footer").jsonObject
        assertEquals("$caseId: footer", res(footer.getValue("key").jsonPrimitive.content), actual.footer.res)
        footer["count"]?.let { assertEquals("$caseId: footer count", it.jsonPrimitive.content.toInt(), actual.footer.count) }
        assertEquals("$caseId: footer keyName", footer["keyName"].stringOrNull(), actual.footer.keyName)
        assertEquals("$caseId: footer reason", footer["reason"].stringOrNull()?.let(::res), actual.footer.reason)

        assertEquals("$caseId: button", expect.getValue("button").jsonPrimitive.content, actual.button.name.lowercase())
        assertEquals("$caseId: dismissible", expect.getValue("dismissible").jsonPrimitive.content.toBooleanStrict(), actual.dismissible)
        assertTrue(actual.rows.isNotEmpty())
    }
}
