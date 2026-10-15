package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Cross-platform contract for outbound history normalization: runs every case of the shared sanitize.v1 fixture through the production sanitizeOutboundMessages. */
class ContextSanitizeContractTest {

    private val fixture: JsonObject by lazy {
        Json.parseToJsonElement(workspaceFile("shared/context-contracts/sanitize.v1.json").readText()).jsonObject
    }

    @Test
    fun `note constant matches fixture`() {
        val note = fixture["unansweredEnvelope"]!!.jsonObject["note"]!!.jsonPrimitive.content
        assertEquals(note, MessageBuilder.UNANSWERED_NOTE)
    }

    @Test
    fun `every fixture case matches production sanitize`() {
        val cases = fixture["cases"]!!.jsonArray.map { it.jsonObject }
        assertTrue("The fixture must contain at least one case", cases.isNotEmpty())
        for (case in cases) {
            val caseId = case["id"]!!.jsonPrimitive.content
            val input = case["input"]!!.jsonObject
            val messages = input["messages"]!!.jsonArray.map { toMessage(it.jsonObject) }
            val keepId = input["keepAssistantId"]?.jsonPrimitive?.content
            val actual = MessageBuilder.sanitizeOutboundMessages(messages, keepAssistantId = keepId)
            val expected = case["expected"]!!.jsonArray.map { it.jsonObject }
            assertEquals("$caseId: message count", expected.size, actual.size)
            expected.zip(actual).forEachIndexed { index, (want, got) ->
                val where = "$caseId[$index]"
                assertEquals("$where id", want["id"]!!.jsonPrimitive.content, got.id)
                assertEquals("$where role", want["role"]!!.jsonPrimitive.content, got.role.rawValue)
                assertEquals("$where text", want["text"]!!.jsonPrimitive.content, got.text)
                assertEquals(
                    "$where attachments",
                    want["attachments"]!!.jsonArray.map { it.jsonPrimitive.content },
                    got.attachments.orEmpty().map { it.id },
                )
            }
        }
    }

    private fun toMessage(obj: JsonObject): ChatMessage {
        val role = when (val raw = obj["role"]!!.jsonPrimitive.content) {
            "user" -> ChatRole.User
            "assistant" -> ChatRole.Assistant
            else -> error("unknown role $raw")
        }
        val state = when (val raw = obj["state"]!!.jsonPrimitive.content) {
            "delivered" -> ChatMessageState.Delivered
            "generating" -> ChatMessageState.Generating
            "interrupted" -> ChatMessageState.Interrupted
            "failed" -> ChatMessageState.Failed
            else -> error("unknown state $raw")
        }
        val attachments = obj["attachments"]?.jsonArray?.map { element ->
            val a = element.jsonObject
            val kind = when (val raw = a["kind"]!!.jsonPrimitive.content) {
                "image" -> AttachmentKind.Image
                "video" -> AttachmentKind.Video
                "file" -> AttachmentKind.File
                else -> error("unknown kind $raw")
            }
            val id = a["id"]!!.jsonPrimitive.content
            Attachment(id = id, kind = kind, fileName = id, mimeType = "application/octet-stream")
        }
        return ChatMessage(
            id = obj["id"]!!.jsonPrimitive.content,
            role = role,
            text = obj["text"]!!.jsonPrimitive.content,
            providerKind = ProviderKind.OpenRouter,
            providerName = "Test",
            modelName = "test-model",
            state = state,
            attachments = attachments,
        )
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
