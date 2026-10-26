package ai.oriveo.community.core.capability

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.nio.file.Files
import java.nio.file.Paths

/** Narrow upstream-rejection signature matching agrees with the shared fixture `shared/test-fixtures/capability/rejection-signatures.v1.json` case by case. */
@RunWith(RobolectricTestRunner::class)
class RejectionSignatureMatcherTest {

    private val fixture: JsonObject by lazy { loadFixture() }

    /** Production path: the signature table read from the APK assets. */
    private val table: RejectionSignatureTable by lazy {
        val loaded = RejectionSignatures.load(RuntimeEnvironment.getApplication())
        assertNotNull("the signature table asset should be packaged with the APK", loaded)
        loaded!!
    }

    @Test
    fun `match agrees with every shared fixture case`() {
        val cases = fixture.getValue("cases").jsonArray
        // Do not hard-code the case count: new cases added to the shared fixture by other platforms run case by case.
        assertTrue(cases.isNotEmpty())
        val failures = cases.mapNotNull { element ->
            val case = element.jsonObject
            val id = case.getValue("id").jsonPrimitive.content
            val response = case.getValue("response").jsonObject
            val result = table.match(
                protocol = case.getValue("protocol").jsonPrimitive.content,
                wireFamily = (case["wireFamily"] as? JsonPrimitive)?.content,
                httpStatus = response.getValue("status").jsonPrimitive.int,
                body = response["body"],
            )
            val expected = (case.getValue("expect").jsonObject["signatureId"] as? JsonPrimitive)
                ?.takeIf { it.isString }?.content
            if (result?.signatureId == expected) null else "$id: expected=$expected actual=${result?.signatureId}"
        }
        assertEquals(emptyList<String>(), failures)
    }

    @Test
    fun `body as raw json text matches like parsed body`() {
        val case = fixture.getValue("cases").jsonArray.first().jsonObject
        val response = case.getValue("response").jsonObject
        val result = table.match(
            protocol = case.getValue("protocol").jsonPrimitive.content,
            wireFamily = case.getValue("wireFamily").jsonPrimitive.content,
            httpStatus = response.getValue("status").jsonPrimitive.int,
            body = response.getValue("body").toString(),
        )
        assertEquals(case.getValue("expect").jsonObject.getValue("signatureId").jsonPrimitive.content, result?.signatureId)
    }

    @Test
    fun `asset table has the same entries as shared json`() {
        fun counts(key: String): Map<String, Int> =
            fixture.getValue(key).jsonObject.mapValues { it.value.jsonArray.size }
        assertEquals(counts("byWireFamily"), table.byWireFamily.mapValues { it.value.size })
        assertEquals(counts("byProtocol"), table.byProtocol.mapValues { it.value.size })
    }

    private fun loadFixture(): JsonObject {
        val relativePath = "shared/test-fixtures/capability/rejection-signatures.v1.json"
        val path = generateSequence(Paths.get("").toAbsolutePath()) { it.parent }
            .map { it.resolve(relativePath) }
            .firstOrNull(Files::exists)
            ?: error("fixture not found: $relativePath")
        return Json.parseToJsonElement(String(Files.readAllBytes(path), Charsets.UTF_8)).jsonObject
    }
}
