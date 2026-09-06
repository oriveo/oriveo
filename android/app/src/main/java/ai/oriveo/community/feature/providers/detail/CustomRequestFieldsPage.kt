package ai.oriveo.community.feature.providers.detail

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.outlined.Book
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.PhoneAndroid
import androidx.compose.material.icons.outlined.TrackChanges
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import android.widget.Toast
import ai.oriveo.community.R
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.ProviderRecipeExecution
import ai.oriveo.community.core.provider.capabilityCustomFragmentAvailable
import ai.oriveo.community.core.provider.previewCapabilityRuntimeCustomFragment
import ai.oriveo.community.core.provider.safeCustomAllowedPaths
import ai.oriveo.community.core.util.openExternalUrl
import ai.oriveo.community.feature.chat.composer.ModelControlInlineAction
import ai.oriveo.community.feature.chat.composer.ModelControlNote
import ai.oriveo.community.feature.chat.composer.modelControlOwnerOrder
import ai.oriveo.community.feature.chat.composer.modelControlSurface
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.modelControlTextButtonColors

@Composable
internal fun CustomRequestFieldsPage(
    provider: Provider,
    model: AIModel,
    canonicalModelId: String,
    conversationId: String?,
    transportIdentity: String,
    finalTransport: String?,
    activeProfile: GenerationProfileRef?,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val colors = OriveoTheme.colors
    val store = remember(context) { LocalCapabilityCustomFragmentStore.from(context) }

    val snapshot = remember(provider.id, canonicalModelId, conversationId, transportIdentity, finalTransport) {
        loadCustomRequestFieldSections(
            store = store,
            provider = provider,
            model = model,
            canonicalModelId = canonicalModelId,
            conversationId = conversationId,
            transportIdentity = transportIdentity,
            finalTransport = finalTransport,
            activeProfile = activeProfile,
        )
    }
    var drafts by remember(snapshot) { mutableStateOf(snapshot.drafts) }

    var legacyEmptyCustomOwners by remember(snapshot) { mutableStateOf(snapshot.legacyEmptyCustomOwners) }
    var pendingRemovalOwner by remember(snapshot) { mutableStateOf<String?>(null) }

    fun persist(owner: String) {
        val namespace = LocalCapabilityCustomFragmentStore.namespaceForOwner(owner) ?: return
        val raw = drafts[owner].orEmpty()
        val enabled = raw.isNotBlank() || owner in legacyEmptyCustomOwners
        store.setConfiguration(
            LocalCapabilityCustomFragmentStore.Configuration(enabled = enabled, rawJSON = raw),
            providerID = provider.id,
            modelID = canonicalModelId,
            conversationID = conversationId,
            transportIdentity = transportIdentity,
            namespace = namespace,
        )
    }

    pendingRemovalOwner?.let { owner ->
        val ownerTitle = stringResource(customRequestFieldSectionTitleRes(owner))
        AlertDialog(
            onDismissRequest = { pendingRemovalOwner = null },
            title = { Text(stringResource(R.string.model_control_remove_custom_fields_title)) },

            text = {
                Text(
                    stringResource(
                        if (conversationId != null) {
                            R.string.model_control_custom_delete_conversation
                        } else {
                            R.string.model_control_custom_delete_connection
                        },
                        ownerTitle,
                    ),
                )
            },
            confirmButton = {
                TextButton(
                    colors = ButtonDefaults.textButtonColors(contentColor = colors.danger),
                    onClick = {
                        drafts = drafts + (owner to "")
                        legacyEmptyCustomOwners = legacyEmptyCustomOwners - owner
                        persist(owner)
                        pendingRemovalOwner = null
                    },
                ) { Text(stringResource(R.string.model_control_remove_custom_fields)) }
            },
            dismissButton = {
                TextButton(
                    colors = modelControlTextButtonColors(),
                    onClick = { pendingRemovalOwner = null },
                ) { Text(stringResource(R.string.model_control_keep_custom_fields)) }
            },
        )
    }

    Column(modifier = modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextButton(colors = modelControlTextButtonColors(), onClick = onBack) {
                Text(stringResource(R.string.back))
            }
            Text(
                text = stringResource(R.string.model_control_custom_request_fields),
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 18.dp)
                .padding(top = 6.dp, bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            if (snapshot.sections.isEmpty()) {
                Column(modifier = Modifier.fillMaxWidth().modelControlSurface().padding(18.dp)) {
                    ModelControlNote(R.string.model_control_custom_fields_need_schema, Icons.Outlined.Info)
                }
            } else {
                snapshot.sections.forEach { owner ->
                    CustomRequestFieldsOwnerCard(
                        provider = provider,
                        model = model,
                        owner = owner,
                        raw = drafts[owner].orEmpty(),
                        hasSchema = owner in snapshot.schemaOwners,
                        isLegacyEmptyCustom = owner in legacyEmptyCustomOwners,
                        conversationId = conversationId,
                        finalTransport = finalTransport,
                        activeProfile = activeProfile,
                        onRawChange = { next ->
                            drafts = drafts + (owner to next)
                            persist(owner)
                        },
                        onSwitchBackToAutomatic = {
                            legacyEmptyCustomOwners = legacyEmptyCustomOwners - owner
                            persist(owner)
                        },
                        onRequestRemoval = { pendingRemovalOwner = owner },
                    )
                }
            }
            ModelControlNote(R.string.model_control_custom_fields_footer, Icons.Outlined.PhoneAndroid)
        }
    }
}

@androidx.annotation.StringRes
internal fun customRequestFieldSectionTitleRes(owner: String): Int = when (owner) {
    "web" -> R.string.model_control_web_search
    "reasoning" -> R.string.model_control_thinking
    else -> R.string.generation_parameters_section
}

internal sealed interface CustomRequestFieldRejection {

    data object InvalidJson : CustomRequestFieldRejection

    data object TooLarge : CustomRequestFieldRejection

    data class NotAllowed(val allowedPaths: List<String>) : CustomRequestFieldRejection

    data object ConflictsManaged : CustomRequestFieldRejection
}

internal fun customRequestFieldRejection(
    reason: String?,
    allowedPaths: List<String>,
): CustomRequestFieldRejection = when (reason) {
    "invalid_json", "duplicate_json_key" -> CustomRequestFieldRejection.InvalidJson
    "too_large", "depth_exceeded", "node_limit_exceeded" -> CustomRequestFieldRejection.TooLarge
    // unknown_path / cross_owner / forbidden_root / forbidden_channel / forbidden_key /

    else -> if (allowedPaths.isEmpty()) {
        CustomRequestFieldRejection.ConflictsManaged
    } else {
        CustomRequestFieldRejection.NotAllowed(allowedPaths)
    }
}

internal data class CustomRequestFieldsSnapshot(
    val sections: List<String>,
    val schemaOwners: Set<String>,
    val drafts: Map<String, String>,
    val legacyEmptyCustomOwners: Set<String>,
)

internal fun loadCustomRequestFieldSections(
    store: LocalCapabilityCustomFragmentStore,
    provider: Provider,
    model: AIModel,
    canonicalModelId: String,
    conversationId: String?,
    transportIdentity: String,
    finalTransport: String?,
    activeProfile: GenerationProfileRef?,
): CustomRequestFieldsSnapshot {
    val sections = mutableListOf<String>()
    val schemaOwners = linkedSetOf<String>()
    val drafts = linkedMapOf<String, String>()
    val legacyEmpty = linkedSetOf<String>()

    modelControlOwnerOrder.forEach { owner ->
        val namespace = LocalCapabilityCustomFragmentStore.namespaceForOwner(owner) ?: return@forEach

        val configuration = store.effectiveConfiguration(
            providerID = provider.id,
            modelID = canonicalModelId,
            conversationID = conversationId,
            transportIdentity = transportIdentity,
            namespace = namespace,
            forwardPort = LocalCapabilityCustomFragmentStore.ForwardPortContext(
                providerKind = provider.kind,
                schemaModelID = model.id,
                activeProfile = activeProfile,
            ),
        )
        drafts[owner] = configuration.rawJSON
        val hasContent = configuration.rawJSON.isNotBlank()
        if (configuration.enabled && !hasContent) legacyEmpty += owner
        if (capabilityCustomFragmentAvailable(
                providerKind = provider.kind,
                modelID = model.id,
                finalTransport = finalTransport,
                activeProfile = activeProfile,
                owner = owner,
            )
        ) {
            schemaOwners += owner
        }

        if (owner in schemaOwners || hasContent || owner in legacyEmpty) sections += owner
    }
    return CustomRequestFieldsSnapshot(sections, schemaOwners, drafts, legacyEmpty)
}

@Composable
private fun CustomRequestFieldsOwnerCard(
    provider: Provider,
    model: AIModel,
    owner: String,
    raw: String,
    hasSchema: Boolean,
    isLegacyEmptyCustom: Boolean,
    conversationId: String?,
    finalTransport: String?,
    activeProfile: GenerationProfileRef?,
    onRawChange: (String) -> Unit,
    onSwitchBackToAutomatic: () -> Unit,
    onRequestRemoval: () -> Unit,
) {
    val context = LocalContext.current
    val colors = OriveoTheme.colors
    val trimmed = raw.trim()
    val jsonLabel = stringResource(R.string.model_control_custom_json_a11y)

    Column(
        modifier = Modifier.fillMaxWidth().modelControlSurface().padding(18.dp),
        verticalArrangement = Arrangement.spacedBy(13.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = stringResource(customRequestFieldSectionTitleRes(owner)),
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.SemiBold,
                color = colors.textPrimary,
                modifier = Modifier.weight(1f),
            )

            if (trimmed.isNotEmpty()) {
                Spacer(Modifier.width(8.dp))
                Text(
                    text = stringResource(R.string.generation_parameter_custom_fields_in_use),
                    style = MaterialTheme.typography.labelMedium,
                    color = colors.textSecondary,
                )
            }
        }

        if (!hasSchema) {
            ModelControlNote(R.string.model_control_custom_fields_no_schema_for_control, Icons.Outlined.Info)
        }

        if (trimmed.isEmpty() && isLegacyEmptyCustom) {
            ModelControlNote(
                R.string.model_control_custom_empty_but_selected,
                Icons.Outlined.Warning,
                tone = colors.danger,
            )
            TextButton(
                colors = ButtonDefaults.textButtonColors(contentColor = colors.danger),
                onClick = onSwitchBackToAutomatic,
            ) { Text(stringResource(R.string.model_control_switch_back_to_automatic)) }
        }

        OutlinedTextField(
            value = raw,

            onValueChange = onRawChange,
            modifier = Modifier
                .fillMaxWidth()
                .semantics { contentDescription = jsonLabel },

            textStyle = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
            minLines = 6,
            singleLine = false,
        )

        val preview = remember(raw, owner, provider.id, model.id, finalTransport) {
            if (trimmed.isEmpty() || finalTransport.isNullOrBlank()) {
                null
            } else {
                previewCapabilityRuntimeCustomFragment(
                    raw = raw,
                    providerKind = provider.kind,
                    modelID = model.id,
                    finalTransport = finalTransport,
                    activeProfile = activeProfile,
                    owner = owner,
                )
            }
        }
        CustomRequestFieldsValidation(
            provider = provider,
            model = model,
            owner = owner,
            finalTransport = finalTransport,
            activeProfile = activeProfile,
            preview = preview,
        )

        MetadataClient.instance
            .capabilityCustomControlAuthority(provider.kind, model.id, finalTransport.orEmpty(), owner)
            ?.riskTiers
            .orEmpty()
            .forEach { tier ->
                val privacy = tier == "privacy_impacting"
                ModelControlNote(
                    textRes = if (privacy) R.string.model_control_risk_privacy else R.string.model_control_risk_cost,
                    icon = if (privacy) Icons.Filled.PanTool else Icons.Filled.CreditCard,
                    tone = colors.warningText,
                )
            }

        val documentationURL = finalTransport?.takeIf { provider.kind != ProviderKind.Relay }?.let { transport ->
            MetadataClient.instance
                .capabilityOfficialGenerationDocumentationURL(provider.kind, model.id, transport)
        }
        if (documentationURL != null) {
            ModelControlInlineAction(
                title = stringResource(R.string.model_control_open_official_docs),
                icon = Icons.Outlined.Book,
                onClick = {
                    if (!openExternalUrl(context, documentationURL)) {
                        Toast.makeText(context, R.string.link_open_failed_message, Toast.LENGTH_LONG).show()
                    }
                },
            )
        } else if (provider.kind == ProviderKind.Relay) {

            ModelControlNote(R.string.model_control_relay_docs, Icons.Outlined.Book)
        }

        ModelControlNote(
            textRes = if (conversationId != null) {
                R.string.model_control_custom_scope_conversation
            } else {
                R.string.model_control_custom_scope_connection_model
            },
            icon = Icons.Outlined.TrackChanges,
        )

        TextButton(
            colors = ButtonDefaults.textButtonColors(contentColor = colors.danger),
            enabled = trimmed.isNotEmpty() || isLegacyEmptyCustom,
            onClick = onRequestRemoval,
        ) {
            Icon(
                imageVector = Icons.Outlined.Delete,
                contentDescription = null,
                modifier = Modifier.padding(end = 6.dp),
            )
            Text(stringResource(R.string.model_control_remove_custom_fields))
        }
    }
}

@Composable
private fun CustomRequestFieldsValidation(
    provider: Provider,
    model: AIModel,
    owner: String,
    finalTransport: String?,
    activeProfile: GenerationProfileRef?,
    preview: ProviderRecipeExecution.CustomResult?,
) {
    val colors = OriveoTheme.colors
    when {
        preview == null -> ModelControlNote(R.string.model_control_custom_json_placeholder)
        preview.accepted -> Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = Icons.Outlined.CheckCircle,
                    contentDescription = null,
                    tint = colors.success,
                    modifier = Modifier.padding(end = 5.dp),
                )
                Text(
                    text = stringResource(R.string.model_control_redacted_delta_preview),
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.success,
                )
            }

            Text(
                text = preview.preview.orEmpty().keys.sorted().joinToString("\n") { "$it: <redacted>" },

                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                color = colors.textSecondary,
            )
        }
        else -> {
            val allowed = remember(provider.id, model.id, finalTransport, owner) {
                safeCustomAllowedPaths(
                    providerKind = provider.kind,
                    modelID = model.id,
                    finalTransport = finalTransport,
                    activeProfile = activeProfile,
                    owner = owner,
                )
            }
            val message = when (val rejection = customRequestFieldRejection(preview.reason, allowed)) {
                CustomRequestFieldRejection.InvalidJson ->
                    stringResource(R.string.model_control_custom_invalid_json)
                CustomRequestFieldRejection.TooLarge ->
                    stringResource(R.string.model_control_custom_too_large)
                CustomRequestFieldRejection.ConflictsManaged ->
                    stringResource(R.string.model_control_custom_conflicts_managed)
                is CustomRequestFieldRejection.NotAllowed -> stringResource(
                    R.string.model_control_custom_field_not_allowed,
                    rejection.allowedPaths.joinToString(" · "),
                )
            }
            ModelControlNote(text = message, icon = Icons.Outlined.Warning, tone = colors.danger)
        }
    }
}
