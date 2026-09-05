package ai.oriveo.community.ui.component

import android.content.Context
import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import ai.oriveo.community.R
import ai.oriveo.community.core.util.openExternalUrl
import ai.oriveo.community.ui.theme.OriveoTheme

const val ORIVEO_REPOSITORY_URL = "https://github.com/oriveo/oriveo"

/**
 * The pages this app can send the user to. There is no separate website: everything lives in
 * the public repository, so the terms are the licence file and the privacy note is the community
 * page that describes what stays on the device.
 */
enum class OriveoWebDestination(val url: String) {
    PrivacyPolicy("$ORIVEO_REPOSITORY_URL/blob/main/COMMUNITY.md"),
    TermsOfService("$ORIVEO_REPOSITORY_URL/blob/main/LICENSE"),
    Changelog("$ORIVEO_REPOSITORY_URL/releases"),
    SourceCode(ORIVEO_REPOSITORY_URL),
    Issues("$ORIVEO_REPOSITORY_URL/issues"),
}

fun Context.openOriveoWebPage(destination: OriveoWebDestination) {
    if (!openExternalUrl(this, destination.url)) {
        Toast.makeText(this, R.string.link_open_failed_message, Toast.LENGTH_LONG).show()
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun OriveoLegalLinksFooter(
    modifier: Modifier = Modifier,
    onOpen: (OriveoWebDestination) -> Unit,
) {
    Column(
        modifier = modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
    ) {
        Text(
            text = stringResource(R.string.legal_consent_notice),
            style = OriveoTheme.typography.caption,
            color = OriveoTheme.colors.textTertiary,
        )

        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.lg),
            verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.xs),
        ) {
            OriveoTextButton(
                text = stringResource(R.string.terms_of_service),
                onClick = { onOpen(OriveoWebDestination.TermsOfService) },
            )
            OriveoTextButton(
                text = stringResource(R.string.privacy_policy),
                onClick = { onOpen(OriveoWebDestination.PrivacyPolicy) },
            )
        }
    }
}
