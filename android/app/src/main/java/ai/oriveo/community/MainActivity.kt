package ai.oriveo.community

import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.core.app.AppViewModel
import ai.oriveo.community.core.data.database.DatabaseHealth
import ai.oriveo.community.core.data.database.DatabaseHealthProbe
import ai.oriveo.community.core.navigation.OriveoNavHost
import ai.oriveo.community.core.model.ThemeOption
import ai.oriveo.community.core.performance.AppJankStats
import ai.oriveo.community.core.reachability.ServiceReachabilityMonitor
import ai.oriveo.community.feature.storage.DatabaseBlockedDialog
import ai.oriveo.community.feature.storage.StorageSettingsLauncher
import ai.oriveo.community.ui.theme.OriveoScreenBackground
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.launch
import org.koin.android.ext.android.inject
import org.koin.androidx.compose.koinViewModel

class MainActivity : AppCompatActivity() {

    private var appJankStats: AppJankStats? = null
    private val reachabilityMonitor: ServiceReachabilityMonitor by inject()
    private val databaseHealthProbe: DatabaseHealthProbe by inject()

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)

        setContent {
            val appViewModel: AppViewModel = koinViewModel()
            val theme by appViewModel.theme.collectAsStateWithLifecycle()
            val hasCompletedOnboarding by appViewModel.hasCompletedOnboarding.collectAsStateWithLifecycle()
            val databaseHealth by databaseHealthProbe.health.collectAsStateWithLifecycle()
            val databaseBlocked = databaseHealth as? DatabaseHealth.Blocked

            LaunchedEffect(appViewModel) {
                appViewModel.markUiReady()
            }

            OriveoTheme(
                darkTheme = resolveDarkTheme(theme),
            ) {
                Box(modifier = Modifier.fillMaxSize()) {
                    if (hasCompletedOnboarding == null || databaseBlocked != null) {
                        OriveoScreenBackground()
                    } else {
                        OriveoNavHost(
                            appViewModel = appViewModel,
                            hasCompletedOnboarding = hasCompletedOnboarding == true,
                        )
                    }
                }

                if (databaseBlocked != null) {
                    var isChecking by remember { mutableStateOf(false) }
                    val retryScope = rememberCoroutineScope()
                    DatabaseBlockedDialog(
                        reason = databaseBlocked.reason,
                        isChecking = isChecking,
                        onRetry = {
                            if (!isChecking) {
                                isChecking = true
                                retryScope.launch {
                                    databaseHealthProbe.retry()
                                    isChecking = false
                                }
                            }
                        },
                        onFreeUpSpace = { StorageSettingsLauncher.openStorageSettings(this@MainActivity) },
                        onContactSupport = { StorageSettingsLauncher.openSupport(this@MainActivity) },
                    )
                }
            }
        }

        window.decorView.post {
            appJankStats = AppJankStats(window)
            reachabilityMonitor.start()
        }
    }

    override fun onResume() {
        super.onResume()
        appJankStats?.onResume()
    }

    override fun onPause() {
        appJankStats?.onPause()
        super.onPause()
    }
}

@Composable
private fun resolveDarkTheme(theme: ThemeOption): Boolean = when (theme) {
    ThemeOption.System -> isSystemInDarkTheme()
    ThemeOption.Light -> false
    ThemeOption.Dark -> true
}
