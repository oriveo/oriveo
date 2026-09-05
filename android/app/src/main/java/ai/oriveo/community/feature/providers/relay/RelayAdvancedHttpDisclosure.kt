package ai.oriveo.community.feature.providers.relay

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.ui.theme.OriveoTheme


@Composable
internal fun RelayAdvancedHttpDisclosure(
    expanded: Boolean,
    onToggle: () -> Unit,
    customUserAgent: String,
    onUserAgentChange: (String) -> Unit,
    headers: List<RelayKeyValue>,
    onHeadersChange: (List<RelayKeyValue>) -> Unit,
    queryParams: List<RelayKeyValue>,
    onQueryParamsChange: (List<RelayKeyValue>) -> Unit,
) {
    val colors = OriveoTheme.colors
    val httpTint = colors.warning
    Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClick = onToggle)
                .padding(horizontal = 2.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
        ) {
            Box(
                modifier = Modifier
                    .size(18.dp)
                    .clip(RoundedCornerShape(5.dp))
                    .background(httpTint.copy(alpha = 0.14f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Filled.Build,
                    contentDescription = null,
                    tint = httpTint,
                    modifier = Modifier.size(11.dp),
                )
            }
            Text(
                text = stringResource(R.string.relay_section_advanced_http).uppercase(),
                style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textSecondary,
                letterSpacing = 0.4.sp,
                modifier = Modifier.weight(1f),
            )
            Icon(
                imageVector = if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                contentDescription = null,
                tint = colors.textTertiary,
                modifier = Modifier.size(16.dp),
            )
        }

        if (expanded) {
            RelayRowGroup {
                RelayInlineTextRow(
                    title = stringResource(R.string.relay_advanced_user_agent),
                    text = customUserAgent,
                    onValueChange = onUserAgentChange,
                    placeholder = stringResource(R.string.relay_advanced_user_agent_placeholder),
                )
            }
            RelayKvSection(
                title = stringResource(R.string.relay_advanced_headers),
                rows = headers,
                onRowsChange = onHeadersChange,
                keyPlaceholder = "X-Internal-Token",
                addLabel = stringResource(R.string.relay_advanced_headers_add),
            )
            RelayKvSection(
                title = stringResource(R.string.relay_advanced_query_params),
                rows = queryParams,
                onRowsChange = onQueryParamsChange,
                keyPlaceholder = "tenant",
                addLabel = stringResource(R.string.relay_advanced_query_params_add),
            )
        }
    }
}

