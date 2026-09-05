package ai.oriveo.community.core.security

import java.net.URI

internal fun isSafeExternalUrl(raw: String): Boolean = runCatching {
    val uri = URI(raw.trim())
    uri.scheme.equals("https", ignoreCase = true) &&
        !uri.host.isNullOrBlank() &&
        uri.userInfo == null
}.getOrDefault(false)
