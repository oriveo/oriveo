package ai.oriveo.community.feature.providers

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import ai.oriveo.community.ui.component.oriveoGradientPanel

@Composable
fun ProvidersListCluster(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .oriveoGradientPanel(radius = 22.dp)
            .padding(vertical = 6.dp),
    ) {
        content()
    }
}
