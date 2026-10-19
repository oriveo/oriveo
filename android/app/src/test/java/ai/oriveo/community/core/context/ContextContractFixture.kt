package ai.oriveo.community.core.context

import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Reads the shared context contract fixtures (the v1 fixtures under the shared context-contracts directory). */
object ContextContractFixture {

    fun load(name: String): JsonObject =
        Json.parseToJsonElement(workspaceFile("shared/context-contracts/$name").readText()).jsonObject

    fun cases(fixture: JsonObject, key: String): List<JsonObject> =
        fixture[key]!!.jsonArray.map { it.jsonObject }

    fun JsonObject.id(): String = this["id"]!!.jsonPrimitive.content

    /** A missing key or JSON null both count as null. */
    fun JsonObject.intOrNull(key: String): Int? = this[key].let { el ->
        if (el == null || el is JsonNull) null else el.jsonPrimitive.content.toInt()
    }

    fun JsonObject.int(key: String): Int = intOrNull(key) ?: error("missing integer field $key")

    fun JsonObject.double(key: String): Double = this[key]!!.jsonPrimitive.content.toDouble()

    fun JsonObject.bool(key: String): Boolean = this[key]!!.jsonPrimitive.content.toBooleanStrict()

    fun JsonObject.stringOrNull(key: String): String? = this[key].let { el ->
        if (el == null || el is JsonNull) null else el.jsonPrimitive.content
    }

    fun JsonObject.objOrNull(key: String): JsonObject? = this[key].let { el: JsonElement? ->
        if (el == null || el is JsonNull) null else el.jsonObject
    }

    /** Fixture message {id, role, text, state, attachments:[{id, kind}]} to ContextMessage; attachments are built from {id, kind}. */
    fun message(json: JsonObject): ContextMessage = ContextMessage(
        id = json.stringOrNull("id")!!,
        role = ChatRole.fromRawValue(json.stringOrNull("role")!!)!!,
        text = json.stringOrNull("text").orEmpty(),
        state = ChatMessageState.entries.first { it.name.lowercase() == json.stringOrNull("state") },
        attachments = json["attachments"]?.jsonArray.orEmpty().map { el ->
            val a = el.jsonObject
            val id = a.stringOrNull("id")!!
            Attachment(
                id = id,
                kind = AttachmentKind.entries.first { it.name.lowercase() == a.stringOrNull("kind") },
                fileName = id,
                mimeType = "application/octet-stream",
            )
        },
    )

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("cannot find $relative")
    }
}
