package ai.oriveo.community.ui.theme

import android.graphics.drawable.VectorDrawable
import androidx.core.content.ContextCompat
import ai.oriveo.community.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * `res/drawable/ph_*.xml` is generated from the source-of-truth SVGs by scripts/phosphor-icons.mjs.
 * Inflate each one for real to prove AAPT accepts the expanded pathData (unstable shorthand parsing is a long-standing Android pitfall).
 */
@RunWith(RobolectricTestRunner::class)
class PhosphorDrawableTest {

    @Test
    fun everyGeneratedPhosphorDrawableInflatesAsVector() {
        val context = RuntimeEnvironment.getApplication()
        val ids = R.drawable::class.java.fields.filter { it.name.startsWith("ph_") }
        // Icons registered in the manifest x regular / duotone; the count follows the manifest, so registering a new icon no longer needs edits here.
        assertEquals(manifestIconCount() * 2, ids.size)
        for (field in ids) {
            val drawable = ContextCompat.getDrawable(context, field.getInt(null))
            assertTrue("${field.name} is not a VectorDrawable", drawable is VectorDrawable)
        }
    }

    private fun manifestIconCount(): Int {
        val manifest = generateSequence(java.io.File("").absoluteFile) { it.parentFile }
            .map { java.io.File(it, "shared/icons/phosphor/manifest.json") }
            .first { it.exists() }
        return kotlinx.serialization.json.Json.parseToJsonElement(manifest.readText())
            .let { it as kotlinx.serialization.json.JsonObject }
            .getValue("icons")
            .let { it as kotlinx.serialization.json.JsonArray }
            .size
    }
}
