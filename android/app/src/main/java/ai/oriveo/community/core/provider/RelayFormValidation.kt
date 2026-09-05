package ai.oriveo.community.core.provider

import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.hasStoredCredential
import ai.oriveo.community.core.model.requiresCredential

/**
 * A declarative definition of the custom-endpoint form, plus pure-function validation for it.
 *
 * Why this file exists: the add page and the edit sheet each used to carry their own answer to
 * "can this be saved", and the same rule drifted apart three times. The add page only checked
 * that the endpoint was non-empty and a key was present, so an `http://` address on the local
 * network could be saved under a `remote_https` configuration - it saved fine and then every
 * send was hard-rejected by the send-time policy. The edit sheet measured the address against a
 * default of `remote_https`, so a local engine on `http://` was judged invalid forever and the
 * user could not even rename the connection. Field order and labels drifted independently too.
 *
 * There may be exactly one home for each judgement: endpoint legality is delegated to
 * [RelayEndpointPolicy] (the save path calls the very same
 * [RelayEndpointPolicy.requireConfigured]), and credential state to
 * `RelayAuthMode.requiresCredential` and [hasStoredCredential]. This file owns only the
 * form-level layout and combination rules; it never reimplements an underlying predicate.
 *
 * Cross-platform cases are pinned in `shared/test-fixtures/relay/form-validation.v1.json`.
 *
 * What this deliberately does not do: merge the add page and the edit sheet into one ViewModel.
 * The two state machines are genuinely different - add has probe-generation guards, single-token
 * validation and an empty-directory exit, while edit has "leave blank to keep" and directory
 * invalidation - and merging them would only smear both into one.
 */
object RelayFormValidation {

    // Field layout, declared once.

    /**
     * A form field. One-to-one with the fields of [RelayFormDraft].
     *
     * The display name is not among them: in the add flow it is an optional label, in the edit
     * flow it goes through its own rename entry point, it takes part in no validation, and it is
     * therefore not part of "the same form".
     */
    enum class Field(val value: String) {
        Endpoint("endpoint"),
        SecurityMode("security_mode"),
        ApiKey("api_key"),
        ModelId("model_id"),
        Transport("transport"),
        AuthMode("auth_mode"),
        Headers("headers"),
        QueryParams("query_params"),
    }

    /** Field groups. The order here is the order the groups appear in the form. */
    enum class Group(val value: String) {
        /** Connection: address, connection mode, key, default model. */
        Connection("connection"),

        /** Protocol: the wire protocol and the authentication mode. */
        Protocol("protocol"),

        /** Advanced HTTP: custom headers and query parameters. */
        AdvancedHttp("advanced_http"),
    }

    /** Whether changing this field invalidates the current probe or validation round. */
    enum class RevalidationTrigger(val value: String) {
        /** Any change invalidates it: address, key, connection mode, protocol, authentication
         *  mode, headers and query parameters. */
        Always("always"),

        /** Never invalidates. */
        Never("never"),

        /**
         * Default model only: picking another entry from the directory that was already probed
         * does not invalidate anything - the protocol has been verified against that same
         * directory, and clearing the result would make the model picker itself disappear.
         * Typing an id that is not in the directory does mean the user changed target.
         */
        UnlessWithinDiscoveredCatalog("unless_within_discovered_catalog"),
    }

    data class FieldDefinition(
        val field: Field,
        val group: Group,
        /**
         * String resource for the label.
         *
         * `null` means the field is not part of the visible form. `securityMode` has its own
         * always-present read-only summary row, so it must reference the real connection-mode
         * resource rather than hiding behind a null.
         */
        @StringRes val labelRes: Int?,
        /**
         * Placeholder text. Address, key and key/value rows use unlocalised example literals;
         * the default-model placeholder is dynamic (it shows a flagship model id from the
         * catalog), so it is `null` here.
         */
        val placeholder: String?,
        val revalidation: RevalidationTrigger,
    )

    /**
     * The canonical layout order: this list is the top-to-bottom render order, and both the add
     * page and the edit sheet follow it. [Field.SecurityMode] sits directly after the address -
     * say what the address is first, then how to reach it.
     */
    val fields: List<FieldDefinition> = listOf(
        FieldDefinition(
            field = Field.Endpoint,
            group = Group.Connection,
            labelRes = R.string.relay_field_endpoint,
            placeholder = "https://api.example.com/v1",
            revalidation = RevalidationTrigger.Always,
        ),
        FieldDefinition(
            field = Field.SecurityMode,
            group = Group.Connection,
            labelRes = R.string.relay_security_mode_label,
            placeholder = null,
            revalidation = RevalidationTrigger.Always,
        ),
        FieldDefinition(
            field = Field.ApiKey,
            group = Group.Connection,
            labelRes = R.string.api_key,
            placeholder = "sk-...",
            revalidation = RevalidationTrigger.Always,
        ),
        FieldDefinition(
            field = Field.ModelId,
            group = Group.Connection,
            labelRes = R.string.relay_default_model_label,
            placeholder = null,
            revalidation = RevalidationTrigger.UnlessWithinDiscoveredCatalog,
        ),
        FieldDefinition(
            field = Field.Transport,
            group = Group.Protocol,
            labelRes = R.string.relay_advanced_transport,
            placeholder = null,
            revalidation = RevalidationTrigger.Always,
        ),
        FieldDefinition(
            field = Field.AuthMode,
            group = Group.Protocol,
            labelRes = R.string.relay_advanced_auth_mode,
            placeholder = null,
            revalidation = RevalidationTrigger.Always,
        ),
        FieldDefinition(
            field = Field.Headers,
            group = Group.AdvancedHttp,
            labelRes = R.string.relay_advanced_headers,
            placeholder = "X-Internal-Token",
            revalidation = RevalidationTrigger.Always,
        ),
        FieldDefinition(
            field = Field.QueryParams,
            group = Group.AdvancedHttp,
            labelRes = R.string.relay_advanced_query_params,
            placeholder = "tenant",
            revalidation = RevalidationTrigger.Always,
        ),
    )

    fun definition(field: Field): FieldDefinition? = fields.firstOrNull { it.field == field }

    // Validation results.

    enum class IssueCode(
        val value: String,
        @StringRes val messageRes: Int,
        /**
         * A "required" issue only keeps the primary button disabled. An empty field is already
         * the hint, and floating a red line on open is noise. Everything else means the user
         * has filled something in and got it wrong, which has to be explained on the spot -
         * otherwise the button is greyed out and they cannot tell why.
         */
        val isSilentRequirement: Boolean,
    ) {
        /** The address is empty. */
        EndpointRequired("endpoint_required", R.string.relay_no_endpoint_set, true),

        /** [RelayEndpointPolicy] rejected the address; `detail` carries its reason slug. */
        EndpointRejected("endpoint_rejected", R.string.relay_setup_invalid_endpoint_message, false),

        /** Credential material is being carried over a cleartext transport (a key, a sensitive
         *  header, or a sensitive query parameter). */
        CleartextCredentials("cleartext_credentials", R.string.relay_credentials_cleartext_blocked, false),

        /**
         * The connection mode is incompatible with the address scheme. The mode is deliberately
         * never auto-adjusted to fit the address; the user has to change it explicitly.
         */
        SecurityModeSchemeMismatch(
            "security_mode_scheme_mismatch",
            R.string.relay_security_mode_scheme_mismatch,
            false,
        ),

        /** This connection needs a key and the form has none at all. */
        CredentialRequired("credential_required", R.string.error_api_key_required, true),

        /** The key contains non-printable ASCII, most often a full-width space or a newline
         *  dragged in by copy and paste. */
        CredentialInvalidCharacters(
            "credential_invalid_characters",
            R.string.provider_api_key_illegal_chars,
            false,
        ),
    }

    data class FieldIssue(
        val field: Field,
        val code: IssueCode,
        /** Machine-readable extra detail; for a rejected endpoint this is
         *  [RelayEndpointPolicy]'s reason slug. Never shown in the UI. */
        val detail: String? = null,
    ) {
        /**
         * The message to show. A rejected address is broken down by [RelayEndpointPolicy]'s
         * reason slug: "the address has a query string embedded in it" and "this is not HTTPS"
         * call for two completely different actions, and answering both with "enter a valid
         * HTTPS address" hides a cause we already know.
         */
        @get:StringRes
        val messageRes: Int get() = when {
            code == IssueCode.EndpointRejected && detail == "embedded_query" ->
                R.string.relay_quick_embedded_query
            else -> code.messageRes
        }
    }

    /** Which flow the form is in. The only real difference is that the edit flow knows a key is
     *  already in the keystore. */
    enum class FormMode { Create, Edit }

    /**
     * Whether the save action may treat the API key as a required field.
     *
     * - [FormMode.Create]: required only when the auth mode `requiresCredential` and no
     *   credential exists yet. Otherwise creating an `auth=none` connection would be pushed off
     *   to some parallel entry point with different capabilities.
     * - [FormMode.Edit]: always `false`. Leaving the input blank means "do not change it", not
     *   "clear it", and editing a non-credential field must never be gated on retyping the key.
     *   A genuinely missing credential is reported by the credential state instead.
     */
    fun credentialInputRequired(
        mode: FormMode,
        authMode: RelayAuthMode?,
        hasStoredKey: Boolean,
    ): Boolean = when (mode) {
        FormMode.Create -> (authMode ?: RelayAuthMode.Auto).requiresCredential && !hasStoredKey
        FormMode.Edit -> false
    }

    // Validation.

    /**
     * The form validation pure function. No side effects, no network, no global state.
     *
     * The returned order always matches the layout order in [fields], and one field can produce
     * more than one issue (address first, then credential).
     */
    fun validate(draft: RelayFormDraft, mode: FormMode): List<FieldIssue> {
        val issues = mutableListOf<FieldIssue>()
        val trimmedEndpoint = draft.endpoint.trim()
        val trimmedKey = draft.apiKey.trim()
        // Edit knows a key is already in the keystore: a blank input means "unchanged", not
        // "clear it". Create has no keystore, only whatever the user just typed.
        val hasCredential = hasStoredCredential(trimmedKey) ||
            (mode == FormMode.Edit && draft.hasSavedCredential)

        // 1. Address.
        if (trimmedEndpoint.isEmpty()) {
            issues += FieldIssue(Field.Endpoint, IssueCode.EndpointRequired)
        } else {
            if (hasSchemeModeMismatch(trimmedEndpoint, draft.securityMode)) {
                issues += FieldIssue(Field.SecurityMode, IssueCode.SecurityModeSchemeMismatch)
            }
            // The save path calls this same requireConfigured, so form validation and saving
            // cannot reach different conclusions.
            runCatching {
                RelayEndpointPolicy.requireConfigured(
                    baseUrl = trimmedEndpoint,
                    securityMode = draft.securityMode,
                    credentials = RelayEndpointPolicy.credentialsOf(
                        requested = draft.requestedConfigForPolicy(),
                        hasKey = hasCredential,
                    ),
                )
            }.onFailure { error ->
                val reason = reasonOf(error)
                if (reason == "cleartext_credentials") {
                    issues += FieldIssue(
                        field = cleartextOffendingField(draft, hasCredential),
                        code = IssueCode.CleartextCredentials,
                        detail = reason,
                    )
                } else {
                    issues += FieldIssue(Field.Endpoint, IssueCode.EndpointRejected, reason)
                }
            }
        }

        // 2. Credential required. The only predicate lives in requiresCredential; no threshold
        // is copied here.
        if (credentialInputRequired(mode, draft.authMode, hasCredential)) {
            issues += FieldIssue(Field.ApiKey, IssueCode.CredentialRequired)
        }

        // 3. Key character set. An empty string is legal for auth=none and for leaving the edit
        // field blank, so only a non-empty value is checked.
        if (trimmedKey.isNotEmpty() && !ProviderKeyInput.isPrintableAsciiKey(trimmedKey)) {
            issues += FieldIssue(Field.ApiKey, IssueCode.CredentialInvalidCharacters)
        }

        val order = fields.map { it.field }
        return issues.sortedBy { order.indexOf(it.field).takeIf { index -> index >= 0 } ?: order.size }
    }

    /**
     * The normalised address, once validation passes. `null` when it does not - both paths share
     * the one classification instead of computing it twice, and no caller is handed an address
     * that merely looks usable to write into storage.
     */
    fun normalizedEndpoint(draft: RelayFormDraft, mode: FormMode): String? {
        if (validate(draft, mode).isNotEmpty()) return null
        val hasCredential = hasStoredCredential(draft.apiKey.trim()) ||
            (mode == FormMode.Edit && draft.hasSavedCredential)
        return runCatching {
            RelayEndpointPolicy.requireConfigured(
                baseUrl = draft.endpoint.trim(),
                securityMode = draft.securityMode,
                credentials = RelayEndpointPolicy.credentialsOf(
                    requested = draft.requestedConfigForPolicy(),
                    hasKey = hasCredential,
                ),
            )
        }.getOrNull()
    }

    /** The issues that deserve an explanation on the spot (see [IssueCode.isSilentRequirement]). */
    fun displayableIssues(issues: List<FieldIssue>): List<FieldIssue> =
        issues.filterNot { it.code.isSilentRequirement }

    // Internal predicates.

    /**
     * Consistency between the connection mode and the address scheme. This is a form-level check,
     * not something discovered at submit time.
     *
     * It only judges the case where the user wrote a scheme **explicitly**: with no scheme, the
     * address policy supplies one from the current mode and the result is always compatible.
     * The other half - an `http://` address under a mode that requires encryption - is reported
     * by [RelayEndpointPolicy] as `cleartext_not_allowed`. This covers what that cannot see:
     * an encrypted address under a mode that declares cleartext.
     */
    private fun hasSchemeModeMismatch(
        endpoint: String,
        securityMode: RelayConnectionSecurityMode,
    ): Boolean {
        if (securityMode != RelayConnectionSecurityMode.LocalHttp &&
            securityMode != RelayConnectionSecurityMode.PrivateVpn
        ) {
            return false
        }
        return endpoint.lowercase().startsWith("https://")
    }

    /** Which piece of credential material actually crossed the line on a cleartext transport.
     *  Attributed in layout order so the user gets something they can tap. */
    private fun cleartextOffendingField(draft: RelayFormDraft, hasCredential: Boolean): Field {
        if (draft.authMode.requiresCredential || hasCredential) return Field.ApiKey
        if (draft.headers.any { RelayEndpointPolicy.isSensitiveName(it.key) }) return Field.Headers
        return Field.QueryParams
    }

    private fun reasonOf(error: Throwable): String =
        (error as? ProviderServiceError.InvalidConfiguration)?.detail ?: "invalid_url"
}

/**
 * The form draft. The add page and the edit sheet each run their own state machine, but both
 * collapse their state into this one draft before handing it to validation.
 */
data class RelayFormDraft(
    val endpoint: String = "",
    val apiKey: String = "",
    val authMode: RelayAuthMode = RelayAuthMode.Auto,
    val securityMode: RelayConnectionSecurityMode = RelayConnectionSecurityMode.RemoteHttps,
    val transport: RelayTransport = RelayTransport.Auto,
    val modelID: String = "",
    val headers: List<RelayKeyValue> = emptyList(),
    val queryParams: List<RelayKeyValue> = emptyList(),
    /** A non-empty key is already stored in the keystore. Always `false` for Create, which has
     *  no keystore yet. */
    val hasSavedCredential: Boolean = false,
) {
    /**
     * The configuration handed to [RelayEndpointPolicy]. It carries only the fields the security
     * boundary cares about, rather than assembling a shadow object that is almost the stored
     * configuration.
     */
    fun requestedConfigForPolicy(): RelayRequestedConfig = RelayRequestedConfig(
        transport = transport,
        authMode = authMode,
        securityMode = securityMode,
        headers = headers.ifEmpty { null },
        queryParams = queryParams.ifEmpty { null },
    )
}

/**
 * Opens a form from an already-stored custom-endpoint configuration. Both the edit sheet and the
 * add page's "prefill from a template" path go through here, so the protocol fields in the draft
 * always come from the same place as the stored ones.
 */
fun RelayFormDraft(
    requested: RelayRequestedConfig?,
    endpoint: String,
    apiKey: String = "",
    hasSavedCredential: Boolean = false,
): RelayFormDraft = RelayFormDraft(
    endpoint = endpoint,
    apiKey = apiKey,
    authMode = requested?.authMode ?: RelayAuthMode.Auto,
    securityMode = requested?.securityMode ?: RelayConnectionSecurityMode.RemoteHttps,
    transport = requested?.transport ?: RelayTransport.Auto,
    modelID = requested?.modelID.orEmpty(),
    headers = requested?.headers.orEmpty(),
    queryParams = requested?.queryParams.orEmpty(),
    hasSavedCredential = hasSavedCredential,
)
