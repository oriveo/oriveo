package ai.oriveo.community.ui.util

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper


tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
