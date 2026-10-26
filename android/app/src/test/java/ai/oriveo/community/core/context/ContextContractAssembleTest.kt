package ai.oriveo.community.core.context

import ai.oriveo.community.core.context.ContextContractFixture.bool
import ai.oriveo.community.core.context.ContextContractFixture.double
import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.ContextContractFixture.int
import ai.oriveo.community.core.context.ContextContractFixture.intOrNull
import ai.oriveo.community.core.context.ContextContractFixture.objOrNull
import ai.oriveo.community.core.context.ContextContractFixture.stringOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Cross-platform context assembly contract: runs the shared assemble.v1 fixture case by case, comparing every key present in expected, text byte for byte. */
class ContextContractAssembleTest {

    private val fixture: JsonObject by lazy { ContextContractFixture.load("assemble.v1.json") }

    @Test
    fun `constants match fixture`() {
        val c = fixture["constants"]!!.jsonObject
        assertEquals(c.stringOrNull("instructionsHeader"), ContextAssembler.INSTRUCTIONS_HEADER)
        assertEquals(c.stringOrNull("reminderPointer"), ContextAssembler.REMINDER_POINTER)
        assertEquals(c.stringOrNull("continuePrompt"), ContextAssembler.CONTINUE_PROMPT)
        assertEquals(c.int("reminderFullTextMaxTokens"), ContextAssembler.REMINDER_FULL_TEXT_MAX_TOKENS)
        assertEquals(c.int("reminderMinUserMessages"), ContextAssembler.REMINDER_MIN_USER_MESSAGES)
        assertEquals(c.stringOrNull("libraryEmptyEntry"), ContextAssembler.LIBRARY_EMPTY_ENTRY)
        assertEquals(c.stringOrNull("deliveryVoice"), ContextAssembler.DELIVERY_VOICE)
        val notes = c["notes"]!!.jsonObject
        assertEquals(notes.keys, ContextAssembler.ENVELOPE_NOTES.keys)
        notes.forEach { (tag, note) -> assertEquals(tag, note.jsonPrimitive.content, ContextAssembler.ENVELOPE_NOTES[tag]) }
    }

    @Test
    fun `assemble cases`() {
        val cases = ContextContractFixture.cases(fixture, "cases")
        assertEquals(47, cases.size)
        cases.forEach { case -> check(case.id(), assemble(case["input"]!!.jsonObject), case["expected"]!!.jsonObject) }
    }

    private fun assemble(input: JsonObject): ContextPlan {
        val window = input["window"]!!.jsonObject
        val conversation = input["conversation"]!!.jsonObject
        val conversationId = conversation.stringOrNull("id")!!
        val current = input.stringOrNull("current")
        val dynamic = input.objOrNull("dynamic")
        return ContextAssembler.assemble(
            ContextAssembleInput(
                purpose = RequestPurpose.entries.first { it.wire == input.stringOrNull("purpose") },
                window = ContextWindowInput(
                    W = window.intOrNull("W"),
                    windowKind = ContextWindowKind.fromWire(window.stringOrNull("windowKind")!!),
                    maxOutput = ContextMaxOutput(model = window.intOrNull("maxOutput")),
                ),
                rhoHi = if (input.containsKey("rhoHi")) input.double("rhoHi") else ContextBudget.RHO0,
                conversation = ContextConversation(
                    id = conversationId,
                    useMemory = conversation.bool("useMemory"),
                    skillPrompt = conversation.stringOrNull("skillPrompt"),
                    instructions = conversation.stringOrNull("instructions"),
                    reminderEnabled = if (input.containsKey("reminderEnabled")) input.bool("reminderEnabled") else true,
                    pinnedNotes = conversation["pinnedNotes"]?.jsonArray.orEmpty().map {
                        ContextPinnedNote(it.jsonObject.stringOrNull("title")!!, it.jsonObject.stringOrNull("text")!!)
                    },
                    knowledgeFiles = conversation["knowledgeFiles"]?.jsonArray.orEmpty().map {
                        ContextKnowledgeFile(it.jsonObject.stringOrNull("name")!!, it.jsonObject.stringOrNull("text")!!)
                    },
                ),
                memoryItems = input["memoryItems"]?.jsonArray.orEmpty().map { el ->
                    val m = el.jsonObject
                    val scope = m.objOrNull("scope")
                    ContextMemoryItem(
                        id = m.stringOrNull("id")!!,
                        kind = m.stringOrNull("kind")!!,
                        content = m.stringOrNull("content")!!,
                        pinned = m["pinned"]?.jsonPrimitive?.content?.toBooleanStrict() ?: false,
                        layer = m.stringOrNull("layer"),
                        status = m.stringOrNull("status"),
                        scope = scope?.let { ContextMemoryScope(it.stringOrNull("type")!!, it.stringOrNull("id")) },
                    )
                },
                history = input["history"]!!.jsonArray.map { ContextContractFixture.message(it.jsonObject) },
                current = current,
                dynamic = dynamic?.let { d ->
                    ContextDynamicInput(
                        recall = d["recall"]?.jsonArray.orEmpty().map { el ->
                            val r = el.jsonObject
                            ContextRecallEntry(id = r.stringOrNull("id")!!, text = r.stringOrNull("text")!!, date = r.stringOrNull("date"))
                        },
                        library = (d["library"] as? JsonArray)?.map { el ->
                            val e = el.jsonObject
                            ContextLibraryEntry(
                                citation = e.intOrNull("citation"),
                                title = e.stringOrNull("title"),
                                truncated = e.bool("truncated"),
                                text = e.stringOrNull("text")!!,
                            )
                        },
                        attachmentGuide = d.stringOrNull("attachmentGuide"),
                        delivery = d.stringOrNull("delivery")?.let { if (it == "voice") ContextDelivery.VOICE else error("unknown delivery $it") },
                    )
                },
                toolSafety = input.stringOrNull("toolSafety"),
                purposeSystem = input.stringOrNull("purposeSystem"),
                checkpoint = input.stringOrNull("checkpoint"),
            ),
        )
    }

    private fun check(id: String, plan: ContextPlan, expected: JsonObject) {
        expected.forEach { (key, value) ->
            when (key) {
                "system" -> assertEquals("$id: system", (value as? JsonPrimitive)?.takeIf { value !is JsonNull }?.content, plan.system)
                "imagePrompt" -> assertEquals("$id: imagePrompt", value.jsonPrimitive.content, plan.imagePrompt)
                "reminder" -> assertEquals("$id: reminder", value.jsonPrimitive.content.toBooleanStrict(), plan.reminder)
                "unansweredMerged" -> assertEquals("$id: unansweredMerged", value.jsonPrimitive.content.toInt(), plan.unansweredMerged)
                "compaction" -> assertEquals("$id: compaction", value.jsonPrimitive.content, plan.compaction.wire)
                "reject" -> assertEquals("$id: reject", (value as? JsonPrimitive)?.takeIf { value !is JsonNull }?.content, plan.reject?.wire)
                "warnings" -> assertEquals("$id: warnings", value.jsonArray.map { it.jsonPrimitive.content }, plan.warnings.map { it.wire })
                "memoryIds" -> assertEquals("$id: memoryIds", value.jsonArray.map { it.jsonPrimitive.content }, plan.memoryIds)
                "omitted" -> {
                    val o = value.jsonObject
                    assertEquals("$id: omitted.knowledge", o.int("knowledge"), plan.omitted.knowledge)
                    assertEquals("$id: omitted.notes", o.int("notes"), plan.omitted.notes)
                    assertEquals("$id: omitted.memory", o.int("memory"), plan.omitted.memory)
                }
                "budget" -> {
                    val b = value.jsonObject
                    assertEquals("$id: budget.W", b.intOrNull("W"), plan.budget.W)
                    assertEquals("$id: budget.B", b.intOrNull("B"), plan.budget.B)
                    assertEquals("$id: budget.oWire", b.int("oWire"), plan.budget.oWire)
                    assertEquals("$id: budget.estimatedInput", b.intOrNull("estimatedInput"), plan.budget.estimatedInput)
                }
                "segments" -> {
                    val segs = value.jsonArray
                    assertEquals("$id: segments", segs.size, plan.segments.size)
                    segs.zip(plan.segments).forEachIndexed { i, (e, a) ->
                        if (e is JsonPrimitive) {
                            assertEquals("$id: segments[$i]", e.content, a.kind.wire)
                        } else {
                            val o = e.jsonObject
                            assertEquals("$id: segments[$i].kind", o.stringOrNull("kind"), a.kind.wire)
                            if (o.containsKey("tokens")) assertEquals("$id: segments[$i].tokens", o.int("tokens"), a.tokens)
                            if (o.containsKey("items")) assertEquals("$id: segments[$i].items", o.intOrNull("items"), a.items)
                            if (o.containsKey("omitted")) assertEquals("$id: segments[$i].omitted", o.intOrNull("omitted"), a.omitted)
                        }
                    }
                }
                "messages" -> {
                    if (value is JsonNull) {
                        assertNull("$id: messages", plan.messages)
                    } else {
                        val msgs = (value as JsonArray).map { it.jsonObject }
                        val actual = plan.messages!!
                        assertEquals("$id: messages.count", msgs.size, actual.size)
                        msgs.zip(actual).forEachIndexed { i, (e, a) ->
                            assertEquals("$id: messages[$i].role", e.stringOrNull("role"), a.role.rawValue)
                            val blocks = e["blocks"]!!.jsonArray.map { it.jsonObject }
                            assertEquals("$id: messages[$i].blocks.count", blocks.size, a.blocks.size)
                            blocks.zip(a.blocks).forEachIndexed { j, (eb, ab) ->
                                assertEquals("$id: messages[$i].blocks[$j].kind", eb.stringOrNull("kind"), ab.kind.wire)
                                assertEquals("$id: messages[$i].blocks[$j].text", eb.stringOrNull("text"), ab.text)
                            }
                        }
                    }
                }
                else -> error("$id: uncompared expected key $key")
            }
        }
    }
}
