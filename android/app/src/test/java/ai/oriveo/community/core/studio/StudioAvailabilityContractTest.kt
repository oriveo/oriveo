package ai.oriveo.community.core.studio

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths

/**
 * Runs every case of the shared StudioAvailability truth table. Android has no Web API, so
 * `webApiStatus` is the only expect key skipped.
 */
class StudioAvailabilityContractTest {
    private val fixture: JsonObject by lazy {
        val path = generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("shared/studio-contracts/studio_availability.v1.json") }
            .firstOrNull { Files.exists(it) }
            ?: error("studio_availability.v1.json not found")
        Json.parseToJsonElement(path.toFile().readText()).jsonObject
    }

    private val skippedKeys = setOf("webApiStatus")

    private fun JsonObject.bool(key: String): Boolean? = this[key]?.jsonPrimitive?.booleanOrNull

    private fun inputOf(raw: JsonObject): StudioAvailability.Input {
        val defaults = StudioAvailability.Input(compileFlag = false, isPro = false)
        return StudioAvailability.Input(
            compileFlag = raw.getValue("compileFlag").jsonPrimitive.boolean,
            remoteStudioEnabled = raw.bool("remoteStudioEnabled"),
            remoteManagedEnabled = raw.bool("remoteManagedEnabled"),
            imageDisabled = raw.bool("imageDisabled") ?: defaults.imageDisabled,
            enabledManagedModels = raw["enabledManagedModels"]?.jsonPrimitive?.int
                ?: defaults.enabledManagedModels,
            isPro = raw.getValue("isPro").jsonPrimitive.boolean,
        )
    }

    private fun StudioAvailability.Result.asMap(): Map<String, Boolean> = mapOf(
        "entryVisible" to entryVisible,
        "deepLinkOpens" to deepLinkOpens,
        "badgeRendered" to badgeRendered,
        "managedListed" to managedListed,
        "managedInChatPicker" to managedInChatPicker,
        "chatWorkRegistration" to chatWorkRegistration,
        "syncWorks" to syncWorks,
    )

    @Test
    fun `every shared case matches expect key by key`() {
        assertEquals("studio_availability.v1", fixture.getValue("contractId").jsonPrimitive.content)
        val cases = fixture.getValue("cases").jsonArray.map { it.jsonObject }
        assertTrue("fixture has cases", cases.isNotEmpty())
        val skippedSeen = mutableSetOf<String>()
        for (case in cases) {
            val id = case.getValue("caseId").jsonPrimitive.content
            val actual = StudioAvailability.evaluate(inputOf(case.getValue("input").jsonObject)).asMap()
            val expect = case.getValue("expect").jsonObject
            for ((key, value) in expect) {
                if (key !in actual) {
                    skippedSeen += key
                    continue
                }
                assertEquals("$id.$key", value.jsonPrimitive.boolean, actual.getValue(key))
            }
            assertEquals("$id covers every Result key", actual.keys, expect.keys - skippedKeys)
        }
        assertEquals("webApiStatus is the only skipped key", skippedKeys, skippedSeen)
    }

    @Test
    fun `remote flag defaults match the fixture`() {
        val remote = fixture.getValue("remoteFlags").jsonObject
        assertEquals(
            setOf(StudioAvailability.REMOTE_STUDIO_ENABLED_KEY, StudioAvailability.REMOTE_MANAGED_ENABLED_KEY),
            remote.keys,
        )
        val studioDefault = remote.getValue(StudioAvailability.REMOTE_STUDIO_ENABLED_KEY)
            .jsonObject.getValue("default").jsonPrimitive.boolean
        val managedDefault = remote.getValue(StudioAvailability.REMOTE_MANAGED_ENABLED_KEY)
            .jsonObject.getValue("default").jsonPrimitive.boolean
        val onlyStudioOn = StudioAvailability.input(
            featureFlags = mapOf(StudioAvailability.REMOTE_MANAGED_ENABLED_KEY to true),
            isPro = false,
            compileFlag = true,
            enabledManagedModels = 2,
        )
        assertEquals(studioDefault, StudioAvailability.evaluate(onlyStudioOn).entryVisible)
        val onlyManagedMissing = StudioAvailability.input(
            featureFlags = mapOf(StudioAvailability.REMOTE_STUDIO_ENABLED_KEY to true),
            isPro = false,
            compileFlag = true,
            enabledManagedModels = 2,
        )
        assertEquals(managedDefault, StudioAvailability.evaluate(onlyManagedMissing).managedListed)
    }

    @Test
    fun `empty featureFlags with compile flag on shows entry but not managed`() {
        val result = StudioAvailability.evaluate(
            StudioAvailability.input(
                featureFlags = emptyMap(),
                isPro = false,
                compileFlag = true,
                enabledManagedModels = 2,
            ),
        )
        assertTrue(result.entryVisible)
        assertFalse(result.managedListed)
    }

    @Test
    fun `explicit featureFlags reach the input`() {
        val input = StudioAvailability.input(
            featureFlags = mapOf(
                StudioAvailability.REMOTE_STUDIO_ENABLED_KEY to false,
                StudioAvailability.REMOTE_MANAGED_ENABLED_KEY to true,
            ),
            isPro = true,
            compileFlag = true,
            imageDisabled = true,
            enabledManagedModels = 3,
        )
        assertEquals(
            StudioAvailability.Input(
                compileFlag = true,
                remoteStudioEnabled = false,
                remoteManagedEnabled = true,
                imageDisabled = true,
                enabledManagedModels = 3,
                isPro = true,
            ),
            input,
        )
    }
}
