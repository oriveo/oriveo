package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.model.ProviderServiceError
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths

/** Drives the shared additionalBodyCases through the production merger and validator. */
class AdditionalRequestBodyContractTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `shared additional body rules match the production validator`() {
        val contract = contract()
        val rules = contract["additionalBodyRules"]!!.jsonObject
        val protected = rules["protectedRootFields"]!!.jsonArray.map { it.jsonPrimitive.content }.toSet()
        assertEquals(protected, AdditionalRequestBody.protectedRootFields)
        assertEquals(
            contract["wireHardening"]!!.jsonObject["builderOwnedRootFields"]!!.jsonArray.map { it.jsonPrimitive.content }.toSet(),
            AdditionalRequestBody.protectedRootFields,
        )
        assertEquals(
            rules["blockedSegments"]!!.jsonArray.map { it.jsonPrimitive.content }.toSet(),
            AdditionalRequestBody.blockedSegments,
        )
        val limits = rules["limits"]!!.jsonObject
        assertEquals(limits["maxBytes"]!!.jsonPrimitive.int, AdditionalRequestBody.MAX_BYTES)
        assertEquals(limits["maxDepth"]!!.jsonPrimitive.int, AdditionalRequestBody.MAX_DEPTH)
    }

    @Test
    fun `shared additional body cases match the production merger`() {
        val contract = contract()
        val reasons = contract["additionalBodyRules"]!!.jsonObject["rejectReasons"]!!.jsonArray
            .map { it.jsonPrimitive.content }.toSet()
        val cases = contract["additionalBodyCases"]!!.jsonArray.map { it.jsonObject }
        assertEquals(21, cases.size)
        val failures = mutableListOf<String>()
        cases.forEach { item ->
            val caseId = item["caseId"]!!.jsonPrimitive.content
            val raw = item["raw"]!!.jsonPrimitive.content
            val body = item["body"]!!.jsonObject
            val expect = item["expect"]!!.jsonObject
            val accepted = expect["accepted"]!!.jsonPrimitive.content.toBoolean()
            try {
                val merged = json.parseToJsonElement(AdditionalRequestBody.apply(body.toString(), raw)).jsonObject
                if (!accepted) failures += "$caseId: accepted, want ${expect["reason"]}"
                else if (merged != expect["body"]) failures += "$caseId: body=$merged, want ${expect["body"]}"
            } catch (error: ProviderServiceError.LocalRequestRejected) {
                if (accepted) failures += "$caseId: rejected ${error.reason}, want accepted"
                val reason = expect["reason"]?.jsonPrimitive?.content
                if (error.reason != reason) failures += "$caseId: reason=${error.reason}, want $reason"
                if (error.reason !in reasons) failures += "$caseId: reason ${error.reason} is not a contract reason"
                val field = expect["field"]?.jsonPrimitive?.content
                if (field != null && error.fieldName != field) failures += "$caseId: field=${error.fieldName}, want $field"
                if (error.owner != AdditionalRequestBody.OWNER) failures += "$caseId: owner=${error.owner}"
            }
        }
        if (failures.isNotEmpty()) fail(failures.joinToString("\n"))
    }

    @Test
    fun `protected fields are root only and the smallest code point is reported first`() {
        val base = """{"model":"m","messages":[]}"""
        val nested = json.parseToJsonElement(AdditionalRequestBody.apply(base, """{"extra":{"system":"x","tools":[]}}""")).jsonObject
        assertEquals("x", nested["extra"]!!.jsonObject["system"]!!.jsonPrimitive.content)
        val rejection = rejection("""{"tools":1,"model":"x","input":2}""")
        assertEquals("protected_field", rejection.reason)
        assertEquals("input", rejection.fieldName)
    }

    @Test
    fun `reject order is size then syntax then root then depth then blocked then protected`() {
        assertEquals("too_large", rejection("{\"a\":\"" + "x".repeat(AdditionalRequestBody.MAX_BYTES) + "\"").reason)
        assertEquals("invalid_json", rejection("""{"model": """).reason)
        assertEquals("not_object", rejection("\"model\"").reason)
        val deep = "[".repeat(32) + "1" + "]".repeat(32)
        assertEquals("too_deep", rejection("""{"a":$deep,"__proto__":{}}""").reason)
        // 32 levels counting the root object is still allowed
        AdditionalRequestBody.apply("{}", """{"a":${"[".repeat(30)}1${"]".repeat(30)}}""")
        val blocked = rejection("""{"model":"x","a":{"constructor":1}}""")
        assertEquals("blocked_segment", blocked.reason)
        assertEquals("constructor", blocked.fieldName)
    }

    @Test
    fun `syntax errors carry the line where the parser stopped and nothing else invents one`() {
        val broken = rejection("{\n  \"top_k\": 40,\n  \"min_p\": \n")
        assertEquals("invalid_json", broken.reason)
        assertTrue("line=${broken.line}", (broken.line ?: 0) >= 3)
        assertNull(rejection("""{"model":"x"}""").line)
        assertEquals("additional_body_rejected:protected_field:model", rejection("""{"model":"x"}""").technicalDetail)
    }

    @Test
    fun `blank content is not enabled and duplicate keys follow the parser`() {
        assertEquals("""{"a":1}""", AdditionalRequestBody.apply("""{"a":1}""", "  \n"))
        val merged = json.parseToJsonElement(AdditionalRequestBody.apply("{}", """{"top_k":1,"top_k":2}""")).jsonObject
        assertEquals(2, merged["top_k"]!!.jsonPrimitive.int)
    }

    @Test
    fun `send toggle is stored apart from the content and survives being turned off`() {
        val store = LocalCapabilityCustomFragmentStore({ null }, {})
        store.setAdditionalBody(LocalCapabilityCustomFragmentStore.AdditionalBody("""{"top_k":1}""", true), "p", "m", null)
        assertEquals("""{"top_k":1}""", store.outboundAdditionalBody("p", "m", "conversation-1"))
        store.setAdditionalBody(LocalCapabilityCustomFragmentStore.AdditionalBody("""{"top_k":1}""", false), "p", "m", null)
        assertNull(store.outboundAdditionalBody("p", "m", "conversation-1"))
        assertEquals("""{"top_k":1}""", store.additionalBody("p", "m", null).rawJSON)
        // An explicit off at the conversation layer wins over the model default
        store.setAdditionalBody(LocalCapabilityCustomFragmentStore.AdditionalBody("""{"top_k":2}""", true), "p", "m", null)
        store.setAdditionalBody(LocalCapabilityCustomFragmentStore.AdditionalBody("""{"top_k":3}""", false), "p", "m", "c")
        assertNull(store.outboundAdditionalBody("p", "m", "c"))
        assertEquals("""{"top_k":2}""", store.outboundAdditionalBody("p", "m", "other"))
    }

    @Test
    fun `legacy generation fragments migrate once by scope with drafts kept off`() {
        var payload: String? = null
        var additional: String? = null
        val legacy = LocalCapabilityCustomFragmentStore({ payload }, { payload = it })
        val identityA = "openai_chat_completions|rev-a"
        val identityB = "openai_chat_completions|rev-b"
        legacy.setFragment("""{"top_k":1}""", "p", "m", "c1", identityA)
        Thread.sleep(2)
        legacy.setFragment("""{"top_k":2}""", "p", "m", "c1", identityB)
        legacy.setFragment("""{"model":"x"}""", "p", "m", "c2", identityA)
        legacy.setConfiguration(LocalCapabilityCustomFragmentStore.Configuration(false, """{"top_k":3}"""), "p", "m", "c3", identityA)
        legacy.setFragment("""{"top_k": """, "p", "m", "c4", identityA)
        legacy.setFragment("""{"search":true}""", "p", "m", "c1", identityA, LocalCapabilityCustomFragmentStore.WEB_NAMESPACE)

        fun open() = LocalCapabilityCustomFragmentStore({ payload }, { payload = it }, readAdditionalBody = { additional }, writeAdditionalBody = { additional = it })
        val store = open()
        assertEquals("""{"top_k":2}""", store.outboundAdditionalBody("p", "m", "c1"))
        assertNull(store.outboundAdditionalBody("p", "m", "c2"))
        assertEquals("""{"model":"x"}""", store.additionalBody("p", "m", "c2").rawJSON)
        assertFalse(store.additionalBody("p", "m", "c3").sendWithRequest)
        assertEquals("""{"top_k":3}""", store.additionalBody("p", "m", "c3").rawJSON)
        assertNull(store.outboundAdditionalBody("p", "m", "c4"))
        assertFalse(payload!!.contains("generationPatch"))
        assertTrue("other owners stay put", payload!!.contains("webPatch"))

        val afterFirst = additional
        open()
        assertEquals(afterFirst, additional)
    }

    private fun rejection(raw: String): ProviderServiceError.LocalRequestRejected = try {
        AdditionalRequestBody.apply("{}", raw)
        fail("expected a local rejection for $raw")
        error("unreachable")
    } catch (error: ProviderServiceError.LocalRequestRejected) {
        error
    }

    private fun contract(): JsonObject {
        val path = generateSequence(Paths.get("").toAbsolutePath()) { it.parent }
            .map { it.resolve("shared/model-contracts/generation_parameter_contract.v1.json") }
            .firstOrNull(Files::exists)
            ?: error("generation_parameter_contract.v1.json not found")
        val casesPath = path.resolveSibling("generation_parameter_contract.v1.cases.json")
        val rules = json.parseToJsonElement(String(Files.readAllBytes(path), Charsets.UTF_8)).jsonObject
        val cases = json.parseToJsonElement(String(Files.readAllBytes(casesPath), Charsets.UTF_8)).jsonObject
        return JsonObject(rules + cases.filterKeys { it != "\$comment" })
    }
}
