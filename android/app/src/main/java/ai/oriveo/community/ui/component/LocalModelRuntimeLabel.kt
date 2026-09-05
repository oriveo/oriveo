package ai.oriveo.community.ui.component

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.LocalModelLoadState
import ai.oriveo.community.core.model.ModelExecutionLocality
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
fun LocalModelRuntimeLabel(model: AIModel) {
    val resource = when {
        model.executionLocality == ModelExecutionLocality.ProxiedCloud -> R.string.local_model_via_ollama_cloud
        model.localLoadState == LocalModelLoadState.Loading -> R.string.local_model_loading
        model.localLoadState == LocalModelLoadState.Unloaded -> R.string.local_model_unloaded
        model.localLoadState == LocalModelLoadState.Unknown -> R.string.local_model_state_unknown
        else -> null
    }
    resource?.let {
        Text(
            text = stringResource(it),
            style = OriveoTheme.typography.caption,
            color = if (model.executionLocality == ModelExecutionLocality.ProxiedCloud) OriveoTheme.colors.warning else OriveoTheme.colors.textSecondary,
        )
    }
}
