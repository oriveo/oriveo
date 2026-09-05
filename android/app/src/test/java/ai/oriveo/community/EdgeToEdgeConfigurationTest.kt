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
     * Pins androidx.core 1.16.0 together with androidx.activity 1.12.x, a combination that has
     * been verified on real devices.
     *
     * This assertion is not a workaround for a systemOverlays()-related crash on Android 14, and
     * the idea that "systemOverlays() only exists starting API 35, so it always crashes on
     * Android 14" is wrong -- don't reason from that premise:
     *  - `WindowInsets.Type.systemOverlays()` has been available since API **34**
     *    (see `$ANDROID_HOME/platforms/android-36/data/api-versions.xml`), so it exists on real
     *    API 34 devices.
     *  - core **1.16.0 already** contains this code path: the value `systemBars()` returns
     *    includes `SYSTEM_OVERLAYS`, and `toPlatformType()`'s `case SYSTEM_OVERLAYS` calls
     *    `systemOverlays()` the same way (WindowInsetsCompat.java:2066/2227 in
     *    core-1.16.0-sources.jar). Downgrading the version does not avoid it.
     *  - A NoSuchMethodError observed in the field traced back to a single misreporting sandboxed
     *    device that claimed to be a Pixel 8 Pro on Android 14 (SDK 34) but was actually a
     *    2GB-RAM, 4-core x86_64 environment with no Play Store and a sideloaded install -- it
     *    simply didn't have that API 34 method available at all. The same app version runs fine
     *    on a real Android 14 device. The same device also threw on
     *    `ActivityOptions.setPendingIntentBackgroundActivityStartMode` (also since=34) around the
     *    same time, confirming the pattern. Such devices are now flagged separately so they don't
     *    get mistaken for real crashes.
     *
     * The actual reason to keep this assertion (unrelated to that crash -- it's about performance
     * and verification discipline):
     *  1. core 1.18.0 adds a bounding-rects mechanism: `Impl20.initTypeBoundingRectsMaps()`
     *     unconditionally iterates `Type.FIRST..Type.LAST` on every insets dispatch, adding
     *     overhead for every type on every dispatch. `Impl35` overrides it as a no-op, but
     *     `Impl34` does not -- so on API 34 this is pure added cost.
     *  2. Don't bump the version until it's been verified on a real device: the core version
     *     isn't declared directly by this project (androidx.activity pulls it up), so watching
     *     the number in libs.versions.toml alone won't catch a bump -- this test has to guard the
     *     actually resolved version.
     *
     * `WindowInsetsCompat$Impl35` only exists starting 1.18.0, and is used here purely as a
     * version probe. Lift this pin once the insets overhead and behavior of 1.18+ have been
     * verified on real Android 14/15 devices.
     */
    @Test
    fun `androidx core stays below 1_18_0 so Android 14 survives edge to edge`() {
        val loader = EdgeToEdgeConfigurationTest::class.java.classLoader!!

        // Guard against a false green: load with initialize=false only, never initialize the class.
        // Impl35's superclass Impl34 has a static block that reads android.view.WindowInsets.CONSUMED,
        // which under the JVM unit test environment's returnDefaultValues stub throws
        // ExceptionInInitializerError on initialization -- if that got swallowed by runCatching,
        // this check would report "probe class doesn't exist" regardless of the actual version,
        // making the gate permanently and silently wrong (this was actually hit once while writing this test).
        fun canLoad(name: String) = runCatching { Class.forName(name, false, loader) }.isSuccess

        assertTrue(
            "androidx.core.view.WindowInsetsCompat is not on the unit test classpath, " +
                "meaning this test isn't checking a real dependency at all -- that's an invalid environment, not a pass.",
            canLoad("androidx.core.view.WindowInsetsCompat"),
        )

        val probeClass = "androidx.core.view.WindowInsetsCompat\$Impl35"
        assertFalse(
            "Detected androidx.core >= 1.18.0 (probe class $probeClass is present on the classpath). " +
                "This project pins 1.16.0: 1.18.0's bounding-rects mechanism makes every insets dispatch " +
                "iterate all types once more, and the upgrade hasn't been verified on a real device. Run " +
                "`bash scripts/android-build.sh :app:dependencyInsight " +
                "--dependency androidx.core:core --configuration releaseRuntimeClasspath` " +
                "to find out what pulled the version up (last time it was androidx.activity:activity:1.13.0).",
            canLoad(probeClass),
        )
    }
}
