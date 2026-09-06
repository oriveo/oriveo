package ai.oriveo.community.benchmark

import androidx.benchmark.macro.CompilationMode
import androidx.benchmark.macro.FrameTimingMetric
import androidx.benchmark.macro.junit4.MacrobenchmarkRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ModelPickerBenchmark {
    @get:Rule
    val benchmarkRule = MacrobenchmarkRule()

    @Test
    fun openExpandAndScrollSeededModels() {
        benchmarkRule.measureRepeated(
            packageName = TARGET_PACKAGE_NAME,
            metrics = listOf(FrameTimingMetric()),
            iterations = 10,
            compilationMode = CompilationMode.Partial(),
            setupBlock = {
                seedBenchmarkData(device)
                killProcess()
                pressHome()
                device.executeShellCommand(
                    "am start -W --activity-clear-task -n $TARGET_ACTIVITY",
                )
                waitForHomeScreen(device)
            },
        ) {
            waitForObject(device, MODEL_PICKER_BUTTON_TAG).click()
            val search = device.wait(
                Until.findObject(By.clazz("android.widget.EditText")),
                UI_TIMEOUT_MS,
            ) ?: error("Model picker search field was not found")
            search.text = "Benchmark"
            check(
                device.wait(
                    Until.hasObject(By.textContains("Benchmark Model")),
                    UI_TIMEOUT_MS,
                ),
            ) { "Seeded benchmark models were not rendered" }
            repeat(3) {
                device.swipe(
                    device.displayWidth / 2,
                    device.displayHeight * 4 / 5,
                    device.displayWidth / 2,
                    device.displayHeight / 3,
                    24,
                )
            }
            repeat(3) {
                device.swipe(
                    device.displayWidth / 2,
                    device.displayHeight / 3,
                    device.displayWidth / 2,
                    device.displayHeight * 4 / 5,
                    24,
                )
            }
        }
    }

    private fun seedBenchmarkData(device: UiDevice) {
        device.executeShellCommand(
            "am broadcast --include-stopped-packages " +
                "-a $SEED_ACTION -n $TARGET_PACKAGE_NAME/$BENCHMARK_RECEIVER_CLASS",
        )
        device.waitForIdle()
    }

    private fun waitForObject(device: UiDevice, tag: String) =
        device.wait(Until.findObject(By.res(TARGET_PACKAGE_NAME, tag)), UI_TIMEOUT_MS)
            ?: device.wait(Until.findObject(By.res(tag)), UI_TIMEOUT_MS)
            ?: error("$tag was not found within ${UI_TIMEOUT_MS}ms")

    private fun waitForHomeScreen(device: UiDevice) {
        check(
            (device.wait(
                Until.hasObject(By.res(TARGET_PACKAGE_NAME, HOME_SCREEN_TAG)),
                UI_TIMEOUT_MS,
            ) || device.wait(Until.hasObject(By.res(HOME_SCREEN_TAG)), UI_TIMEOUT_MS)) &&
                (device.hasObject(By.res(TARGET_PACKAGE_NAME, MODEL_PICKER_BUTTON_TAG)) ||
                    device.hasObject(By.res(MODEL_PICKER_BUTTON_TAG))),
        ) { "Home screen was not found within ${UI_TIMEOUT_MS}ms" }
    }

    companion object {
        private const val TARGET_PACKAGE_NAME = "ai.oriveo.community"
        private const val TARGET_ACTIVITY = "$TARGET_PACKAGE_NAME/.MainActivity"
        private const val HOME_SCREEN_TAG = "home_screen"
        private const val MODEL_PICKER_BUTTON_TAG = "model_picker_button"
        private const val SEED_ACTION = "ai.oriveo.community.action.SEED_BENCHMARK_DATA"
        private const val BENCHMARK_RECEIVER_CLASS =
            "ai.oriveo.community.benchmark.BenchmarkSeedReceiver"
        private const val UI_TIMEOUT_MS = 10_000L
    }
}
