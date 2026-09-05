package ai.oriveo.community.core.performance

import android.os.Build
import android.os.StrictMode
import android.util.Log
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

private const val TAG = "DebugMainThread"
private const val APP_PACKAGE_PREFIX = "ai.oriveo.community"

object DebugMainThreadDiagnostics {
    private val listenerExecutor: ExecutorService by lazy {
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "debug-strict-mode").apply { isDaemon = true }
        }
    }

    fun install() {
        val threadPolicy = StrictMode.ThreadPolicy.Builder()
            .detectDiskReads()
            .detectDiskWrites()
            .detectNetwork()
            .penaltyLog()

        val vmPolicy = StrictMode.VmPolicy.Builder()
            .detectActivityLeaks()
            .detectLeakedClosableObjects()
            .detectLeakedRegistrationObjects()
            .penaltyLog()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            threadPolicy.penaltyListener(listenerExecutor) { violation ->
                reportViolation("thread", violation)
            }
            vmPolicy.penaltyListener(listenerExecutor) { violation ->
                reportViolation("vm", violation)
            }
        }

        StrictMode.setThreadPolicy(threadPolicy.build())
        StrictMode.setVmPolicy(vmPolicy.build())
    }

    private fun reportViolation(kind: String, violation: Throwable) {
        val touchesAppCode = violation.stackTrace.any { it.className.startsWith(APP_PACKAGE_PREFIX) }
        if (!touchesAppCode) return

        val name = violation.javaClass.simpleName.ifBlank { "Violation" }
        val message = "StrictMode $kind violation: $name"
        Log.w(TAG, message, violation)
    }
}
