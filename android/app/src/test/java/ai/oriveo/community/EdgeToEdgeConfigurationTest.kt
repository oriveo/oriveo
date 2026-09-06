package ai.oriveo.community

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EdgeToEdgeConfigurationTest {

    @Test
    fun `edge to edge is enabled before activity creation`() {
        val source = File("src/main/java/ai/oriveo/community/MainActivity.kt").readText()

        assertTrue(
            "AndroidX requires enableEdgeToEdge before super.onCreate for consistent setup.",
            source.contains("enableEdgeToEdge()\n        super.onCreate(savedInstanceState)"),
        )
    }

    @Test
    fun `system bar contrast uses AndroidX defaults`() {
        val source = File("src/main/java/ai/oriveo/community/MainActivity.kt").readText()

        assertFalse(source.contains("SystemBarStyle"))
        assertFalse(source.contains("isNavigationBarContrastEnforced"))
        assertFalse(source.contains("statusBarColor"))
        assertFalse(source.contains("navigationBarColor"))
    }

    /**
     * Pins androidx.core to 1.16.x by probing for a class that only exists from 1.18.0.
     *
     * The version is not declared by this project at all - androidx.activity pulls it in - so
     * watching `libs.versions.toml` would not notice a bump. The probe has to look at what actually
     * resolved.
     *
     * Why 1.16.0 and not later: 1.18.0 adds a bounding-rects mechanism whose
     * `Impl20.initTypeBoundingRectsMaps()` walks `Type.FIRST..Type.LAST` on every insets dispatch.
     * `Impl35` overrides it as a no-op, `Impl34` does not, so on API 34 it is pure added cost on a
     * path that runs constantly. Lift the pin once 1.18+ has been measured on a real Android 14 or
     * 15 device.
     *
     * `WindowInsetsCompat$Impl35` is used only as a version marker; it carries no meaning of its own.
     */
    @Test
    fun `androidx core stays below 1_18_0 so Android 14 survives edge to edge`() {
        val loader = EdgeToEdgeConfigurationTest::class.java.classLoader!!

        // Load with initialize=false, never initialize the class. Impl35's superclass Impl34 has a
        // static block that reads android.view.WindowInsets.CONSUMED, which throws
        // ExceptionInInitializerError under the unit test environment's returnDefaultValues stub. If
        // runCatching swallowed that, the probe would report "class doesn't exist" whatever the
        // resolved version was, and the gate would pass forever without checking anything.
        fun canLoad(name: String) = runCatching { Class.forName(name, false, loader) }.isSuccess

        assertTrue(
            "androidx.core.view.WindowInsetsCompat is not on the unit test classpath, " +
                "meaning this test isn't checking a real dependency at all -- that's an invalid environment, not a pass.",
            canLoad("androidx.core.view.WindowInsetsCompat"),
        )

        val probeClass = "androidx.core.view.WindowInsetsCompat\$Impl35"
        assertFalse(
            "Detected androidx.core >= 1.18.0 (probe class $probeClass is present on the classpath). " +
                "This project pins 1.16.x: 1.18.0's bounding-rects mechanism makes every insets dispatch " +
                "iterate all types once more, and the upgrade has not been measured on a real device. Run " +
                "`./gradlew :app:dependencyInsight --dependency androidx.core:core " +
                "--configuration releaseRuntimeClasspath` to see what pulled the version up; " +
                "androidx.activity is the usual culprit.",
            canLoad(probeClass),
        )
    }
}
