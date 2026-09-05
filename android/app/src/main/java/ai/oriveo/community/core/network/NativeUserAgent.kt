package ai.oriveo.community.core.network

import android.os.Build
import ai.oriveo.community.BuildConfig

object NativeUserAgent {
    fun current(): String = build(
        versionName = BuildConfig.VERSION_NAME,
        systemRelease = Build.VERSION.RELEASE.orEmpty().ifBlank { "unknown" },
    )

    fun build(versionName: String, systemRelease: String): String =
        "Oriveo/$versionName (Android $systemRelease)"
}
