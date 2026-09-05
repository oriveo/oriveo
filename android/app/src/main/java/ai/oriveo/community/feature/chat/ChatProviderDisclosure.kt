package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.QuoteContext

data class ProviderDisclosurePrompt(
    val kind: ProviderKind,
    val displayName: String,
    val privacyPolicyUrl: String?,
)

internal data class PendingDisclosurePayload(
    val providerId: String,
    val modelId: String,
    val text: String,
    val attachments: List<Attachment>?,
    val quoteContext: QuoteContext? = null,
)
