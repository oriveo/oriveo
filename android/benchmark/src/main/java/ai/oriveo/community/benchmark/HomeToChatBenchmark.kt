package ai.oriveo.community.benchmark

import androidx.benchmark.macro.CompilationMode
import androidx.benchmark.macro.FrameTimingMetric
import androidx.benchmark.macro.StartupMode
import androidx.benchmark.macro.StartupTimingMetric
import androidx.benchmark.macro.junit4.MacrobenchmarkRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HomeToChatBenchmark {

    @get:Rule
    val benchmarkRule = MacrobenchmarkRule()

    @Test
    fun coldStartOpenConversation() {
        benchmarkRule.measureRepeated(
            packageName = TARGET_PACKAGE_NAME,
            metrics = listOf(
                StartupTimingMetric(),
                FrameTimingMetric(),
            ),
            iterations = 5,
            startupMode = StartupMode.COLD,
            compilationMode = CompilationMode.Partial(),
            setupBlock = {
                seedBenchmarkData(device)
                pressHome()
            },
        ) {
            startActivityAndWait()
            waitForHomeScreen(device)

            val targetConversation = device.wait(
                Until.findObject(By.text(TARGET_CONVERSATION_TITLE)),
                UI_TIMEOUT_MS,
            ) ?: device.wait(
                Until.findObject(By.res(TARGET_PACKAGE_NAME, HOME_CONVERSATION_ITEM_TAG)),
                UI_TIMEOUT_MS,
            ) ?: error("Target conversation was not found on home screen.")

            targetConversation.click()

            check(
                device.wait(
                    Until.hasObject(By.res(TARGET_PACKAGE_NAME, CHAT_SCREEN_TAG)),
                    UI_TIMEOUT_MS,
                ),
            ) {
                "Chat screen did not appear within ${UI_TIMEOUT_MS}ms."
            }
        }
    }

    private fun seedBenchmarkData(device: UiDevice) {
        val packageOutput = device.executeShellCommand(
            "pm path $TARGET_PACKAGE_NAME || true",
        ).trim()
        val receiverOutput = device.executeShellCommand(
            "cmd package query-receivers --brief " +
                "-a $SEED_ACTION $TARGET_PACKAGE_NAME",
        )
        check(
            receiverOutput.contains(BENCHMARK_RECEIVER_CLASS) ||
                receiverOutput.contains(BENCHMARK_RECEIVER_COMPONENT),
        ) {
            "Benchmark seed receiver is missing. " +
                "package=$packageOutput receivers=${receiverOutput.trim()}"
        }

        val broadcastOutput = device.executeShellCommand(
            "am broadcast --include-stopped-packages " +
                "-a $SEED_ACTION " +
                "-n $TARGET_PACKAGE_NAME/$BENCHMARK_RECEIVER_CLASS",
        )
        check(broadcastOutput.contains("Broadcast completed")) {
            "Benchmark seed broadcast did not complete successfully."
        }
    }

    private fun waitForHomeScreen(device: UiDevice) {
        check(
            device.wait(
                Until.hasObject(By.res(TARGET_PACKAGE_NAME, HOME_SCREEN_TAG)),
                UI_TIMEOUT_MS,
            ) || device.wait(
                Until.hasObject(By.res(HOME_SCREEN_TAG)),
                UI_TIMEOUT_MS,
            ) || device.wait(
                Until.hasObject(By.text(TARGET_CONVERSATION_TITLE)),
                UI_TIMEOUT_MS,
            ),
        ) {
            "Home screen did not appear within ${UI_TIMEOUT_MS}ms."
        }
    }

    companion object {
        private const val TARGET_PACKAGE_NAME = "ai.oriveo.community"
        private const val TARGET_CONVERSATION_TITLE = "Rendering cost on the chat screen"
        private const val HOME_SCREEN_TAG = "home_screen"
        private const val HOME_CONVERSATION_ITEM_TAG = "home_conversation_item"
        private const val CHAT_SCREEN_TAG = "chat_screen"
        private const val SEED_ACTION = "ai.oriveo.community.action.SEED_BENCHMARK_DATA"
        private const val BENCHMARK_RECEIVER_CLASS =
            "ai.oriveo.community.benchmark.BenchmarkSeedReceiver"
        private const val BENCHMARK_RECEIVER_COMPONENT =
            "ai.oriveo.community/.benchmark.BenchmarkSeedReceiver"
        private const val UI_TIMEOUT_MS = 10_000L
    }
}
