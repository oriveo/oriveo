package ai.oriveo.community.core.performance

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeJankStateLifecycleTest {
    @Test
    fun `home metrics state is removed when home leaves composition`() {
        val source = File("src/main/java/ai/oriveo/community/feature/home/HomeScreen.kt").readText()
        val effect = source.substringAfter("DisposableEffect(metricsStateHolder, homeMetricsMode)")
            .substringBefore("Box(")

        assertTrue(effect.contains("putState(\"home_mode\", homeMetricsMode)"))
        assertTrue(effect.contains("onDispose"))
        assertTrue(effect.contains("removeState(\"home_mode\")"))
    }
}
