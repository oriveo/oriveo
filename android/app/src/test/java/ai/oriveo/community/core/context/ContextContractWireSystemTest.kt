package ai.oriveo.community.core.context

import ai.oriveo.community.core.context.ContextContractFixture.bool
import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.ContextContractFixture.stringOrNull
import ai.oriveo.community.core.model.ChatRole
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** WireAdapter contract: wire-system.v1 cases compare request body fragments per case and per family (JSON semantic equality, strings byte for byte). */
class ContextContractWireSystemTest {

    private val fixture: JsonObject by lazy { ContextContractFixture.load("wire-system.v1.json") }

    private fun case(id: String): JsonObject =
        ContextContractFixture.cases(fixture, "cases").first { it.id() == id }

    @Test
    fun `fixture families and cases`() {
        assertEquals(fixture["families"]!!.jsonObject.keys, ContextWireFamily.entries.map { it.wire }.toSet())
        val ids = ContextContractFixture.cases(fixture, "cases").map { it.id() }
        assertEquals(
            listOf(
                "system_history_and_dynamic_block",
                "no_system_field_when_plan_has_none",
                "two_turn_prefix_is_stable",
                "checkpoint_merges_with_first_tail_user",
                "host_loop_notice_after_tool_results",
                "host_loop_leg_bodies",
                "host_loop_leg_bodies_with_dynamic",
            ),
            ids,
        )
        val families = ContextWireFamily.entries.map { it.wire }.toSet()
        ContextContractFixture.cases(fixture, "cases").forEach { c ->
            assertEquals(c.id(), families, c["expected"]!!.jsonObject.keys - "all")
        }
    }

    @Test
    fun wire_system_history_and_dynamic_block() = checkPlanCase("system_history_and_dynamic_block")

    @Test
    fun wire_no_system_field_when_plan_has_none() = checkPlanCase("no_system_field_when_plan_has_none")

    @Test
    fun wire_checkpoint_merges_with_first_tail_user() = checkPlanCase("checkpoint_merges_with_first_tail_user")

    @Test
    fun wire_host_loop_leg_bodies() = checkLegCase("host_loop_leg_bodies")

    @Test
    fun wire_host_loop_leg_bodies_with_dynamic() = checkLegCase("host_loop_leg_bodies_with_dynamic")

    private fun checkLegCase(id: String) {
        val c = case(id)
        val (system, messages) = plan(c["plan"]!!.jsonObject)
        val leg = toolLeg(c["toolLeg"]!!.jsonObject)
        c["expected"]!!.jsonObject.forEach { (wire, expected) ->
            val family = ContextWireFamily.fromWire(wire)
            if ((expected as? JsonObject)?.get("throws") != null) {
                assertThrows("$id/$wire", IllegalArgumentException::class.java) {
                    ContextWireAdapter.project(system, messages, family, leg)
                }
            } else {
                assertEquals("$id/$wire", expected, ContextWireAdapter.project(system, messages, family, leg))
            }
        }
    }

    @Test
    fun wire_two_turn_prefix_is_stable() {
        val c = case("two_turn_prefix_is_stable")
        val turns = c["turns"]!!.jsonArray.map { plan(it.jsonObject) }
        c["expected"]!!.jsonObject.forEach { (wire, expected) ->
            val family = ContextWireFamily.fromWire(wire)
            val bodies = turns.map { (s, m) -> ContextWireAdapter.project(s, m, family) }
            assertEquals(wire, expected, JsonArray(bodies))

            // assert: system is unchanged; the first k entries of turn2 equal the first k of turn1; turn2's k-th = turn1's k-th with [D] removed (Anthropic ignores cache_control).
            assertEquals(wire, systemCarrier(bodies[0]), systemCarrier(bodies[1]))
            val (s1, m1) = turns[0]
            val k = m1.indexOfLast { it.role == ChatRole.User }
            val first = conversation(bodies[0])
            val second = conversation(bodies[1])
            assertEquals(wire, first.take(k), second.take(k))
            val withoutDynamic = m1.mapIndexed { i, m ->
                if (i == k) m.copy(blocks = m.blocks.filter { it.kind != ContextBlockKind.DYNAMIC }) else m
            }
            assertEquals(wire, conversation(ContextWireAdapter.project(s1, withoutDynamic, family))[k], second[k])
        }
    }

    @Test
    fun wire_host_loop_notice_after_tool_results() {
        val c = case("host_loop_notice_after_tool_results")
        val bodies = case("host_loop_leg_bodies")
        val (system, messages) = plan(bodies["plan"]!!.jsonObject)
        val leg = toolLeg(bodies["toolLeg"]!!.jsonObject)
        val notice = leg.notice!!
        val all = c["expected"]!!.jsonObject["all"]!!.jsonObject
        assertTrue(all.bool("systemEqualsFirstLeg"))
        assertTrue(all.bool("noSystemRoleMessagesAdded"))
        (c["expected"]!!.jsonObject.keys - "all").forEach { wire ->
            val family = ContextWireFamily.fromWire(wire)
            if (family == ContextWireFamily.FREE) {
                assertThrows(wire, IllegalArgumentException::class.java) {
                    ContextWireAdapter.project(system, messages, family, leg)
                }
                return@forEach
            }
            val firstLeg = ContextWireAdapter.project(system, messages, family)
            val body = ContextWireAdapter.project(system, messages, family, leg)
            assertEquals(wire, systemCarrier(firstLeg), systemCarrier(body))
            assertEquals(wire, systemRoleCount(firstLeg), systemRoleCount(body))
            val items = conversation(body)
            when (family) {
                ContextWireFamily.OPENAI_RESPONSES -> {
                    val lastOutput = items.indexOfLast { it.str("type") == "function_call_output" }
                    assertEquals(wire, items.lastIndex, lastOutput + 1)
                    assertEquals(wire, "user", items.last().str("role"))
                    assertEquals(wire, notice, items.last().str("content"))
                }
                ContextWireFamily.ANTHROPIC -> {
                    val blocks = items.last().jsonObject["content"]!!.jsonArray.map { it.jsonObject }
                    assertEquals(wire, "user", items.last().str("role"))
                    assertTrue(wire, blocks.dropLast(1).all { it.str("type") == "tool_result" } && blocks.size > 1)
                    assertEquals(wire, "text", blocks.last().str("type"))
                    assertEquals(wire, notice, blocks.last().str("text"))
                }
                ContextWireFamily.GEMINI -> {
                    val parts = items.last().jsonObject["parts"]!!.jsonArray.map { it.jsonObject }
                    assertEquals(wire, "user", items.last().str("role"))
                    assertTrue(wire, parts.dropLast(1).all { it.containsKey("functionResponse") } && parts.size > 1)
                    assertEquals(wire, notice, parts.last().str("text"))
                }
                else -> {
                    val lastTool = items.indexOfLast { it.str("role") == "tool" }
                    assertEquals(wire, items.lastIndex, lastTool + 1)
                    assertEquals(wire, "user", items.last().str("role"))
                    assertEquals(wire, notice, items.last().str("content"))
                }
            }
        }
    }

    @Test
    fun `projection rejects empty plans and bad tool arguments`() {
        assertThrows(IllegalArgumentException::class.java) {
            ContextWireAdapter.project(null, emptyList(), ContextWireFamily.OPENAI_CHAT)
        }
        val (system, messages) = plan(case("host_loop_leg_bodies")["plan"]!!.jsonObject)
        val blank = ContextToolLeg(listOf(ContextToolCall("c", "t", " 　")), listOf(ContextToolResult("c", "t", "ok")))
        val anthropic = ContextWireAdapter.project(system, messages, ContextWireFamily.ANTHROPIC, blank)
        val toolUse = conversation(anthropic)[1].jsonObject["content"]!!.jsonArray[0].jsonObject
        assertEquals(JsonObject(emptyMap()), toolUse["input"])
        listOf("[1]", "{bad").forEach { args ->
            val bad = blank.copy(calls = listOf(ContextToolCall("c", "t", args)))
            listOf(ContextWireFamily.ANTHROPIC, ContextWireFamily.GEMINI).forEach { family ->
                assertThrows("$family $args", IllegalArgumentException::class.java) {
                    ContextWireAdapter.project(system, messages, family, bad)
                }
            }
        }
    }

    // ---- Fixture to input ----

    private fun checkPlanCase(id: String) {
        val c = case(id)
        val (system, messages) = plan(c["plan"]!!.jsonObject)
        c["expected"]!!.jsonObject.forEach { (wire, expected) ->
            assertEquals("$id/$wire", expected, ContextWireAdapter.project(system, messages, ContextWireFamily.fromWire(wire)))
        }
    }

    private fun plan(json: JsonObject): Pair<String?, List<ContextPlanMessage>> =
        json.stringOrNull("system") to json["messages"]!!.jsonArray.mapIndexed { i, el ->
            val m = el.jsonObject
            ContextPlanMessage(
                id = "m$i",
                role = ChatRole.fromRawValue(m.stringOrNull("role")!!)!!,
                blocks = m["blocks"]!!.jsonArray.map { b ->
                    val block = b.jsonObject
                    ContextPlanBlock(
                        kind = ContextBlockKind.entries.first { it.wire == block.stringOrNull("kind") },
                        text = block.stringOrNull("text")!!,
                    )
                },
                attachments = emptyList(),
            )
        }

    private fun toolLeg(json: JsonObject) = ContextToolLeg(
        calls = json["calls"]!!.jsonArray.map {
            val o = it.jsonObject
            ContextToolCall(o.stringOrNull("id")!!, o.stringOrNull("name")!!, o.stringOrNull("arguments")!!)
        },
        results = json["results"]!!.jsonArray.map {
            val o = it.jsonObject
            ContextToolResult(o.stringOrNull("callId")!!, o.stringOrNull("name")!!, o.stringOrNull("output")!!)
        },
        notice = json.stringOrNull("notice"),
    )

    // ---- Reading the request body ----

    private fun systemCarrier(body: JsonObject): JsonElement? =
        body["system"] ?: body["instructions"] ?: body["systemInstruction"]
            ?: body["messages"]?.jsonArray?.firstOrNull { it.str("role") == "system" }

    private fun systemRoleCount(body: JsonObject): Int =
        (body["messages"] ?: body["input"] ?: body["contents"])!!.jsonArray.count { it.str("role") == "system" }

    /** Message list without system-role messages; for Anthropic, cache_control is removed. */
    private fun conversation(body: JsonObject): List<JsonElement> {
        val list = (body["messages"] ?: body["input"] ?: body["contents"])!!.jsonArray
            .filter { it.str("role") != "system" }
        return list.map(::stripCacheControl)
    }

    private fun stripCacheControl(el: JsonElement): JsonElement = when (el) {
        is JsonObject -> JsonObject(el.filterKeys { it != "cache_control" }.mapValues { stripCacheControl(it.value) })
        is JsonArray -> JsonArray(el.map(::stripCacheControl))
        else -> el
    }

    private fun JsonElement.str(key: String): String? =
        ((this as? JsonObject)?.get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content
}
