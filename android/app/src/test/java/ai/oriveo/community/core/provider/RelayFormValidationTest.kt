package ai.oriveo.community.core.provider

import ai.oriveo.community.R
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayKindDefaults
import ai.oriveo.community.core.model.RelayRequestedConfig
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * Regression lock over the form definition shared by the add and edit screens, plus the
 * pure validation functions, against the cross-client contract in
 * `shared/test-fixtures/relay/form-validation.v1.json`.
 *
 * No case builds its draft by hand. The fixture's protocol fields go first through the
 * production kotlinx decoding path for `RelayRequestedConfig` -- the same inbound decode
 * used for sync and backup payloads, including enum fallback rules such as
 * [ai.oriveo.community.core.model.RelayAuthModeSerializer] -- and the decoded config is then
 * assembled by the production `RelayFormDraft(requested, endpoint, apiKey,
 * hasSavedCredential)` factory. A test that hand-rolled its own draft would only be testing
 * itself.
 *
 * Labels work the same way: instead of hard-coding English strings, the resource id named by
 * the production definition is reverse-looked-up to a resource name, and the English value is
 * parsed out of `values/strings.xml` to compare against the fixture's `labelEN`.
 */
class RelayFormValidationTest {

    private val json = Json { ignoreUnknownKeys = true }

    // Form layout definition

    @Test
    fun `field order group and label wording match the cross-end fixture`() {
        val contract = contract()
        assertEquals(1, contract.version)
        assertEquals(contract.form.fields.size, RelayFormValidation.fields.size)

        contract.form.fields.forEachIndexed { index, expected ->
            val actual = RelayFormValidation.fields[index]
            assertEquals(
                "field $index drifted -- both flows share one layout order and must not evolve apart",
                expected.field,
                actual.field.value,
            )
            assertEquals("${expected.field} group drifted", expected.group, actual.group.value)
            assertEquals("${expected.field} revalidation trigger drifted", expected.revalidation, actual.revalidation.value)
            assertEquals("${expected.field} placeholder drifted", expected.placeholder, actual.placeholder)
            assertEquals(
                "${expected.field} label drifted: the Android English value must equal the shared labelEN",
                expected.labelEN,
                actual.labelRes?.let { englishStrings.getValue(resourceName(it)) },
            )
        }
    }

    @Test
    fun `security mode has a visible connection type label`() {
        val definition = RelayFormValidation.definition(RelayFormValidation.Field.SecurityMode)
        assertNotNull(definition)
        assertEquals(R.string.relay_security_mode_label, definition!!.labelRes)
        RelayFormValidation.fields.forEach { assertNotNull("${it.field.value} has no label", it.labelRes) }
    }

    @Test
    fun `endpoint and api key placeholders match the shipped string resources`() {
        assertEquals(
            RelayFormValidation.definition(RelayFormValidation.Field.Endpoint)?.placeholder,
            englishStrings["relay_endpoint_placeholder"],
        )
        assertEquals(
            RelayFormValidation.definition(RelayFormValidation.Field.ApiKey)?.placeholder,
            englishStrings["relay_api_key_placeholder"],
        )
    }

    @Test
    fun `every issue code ships copy in all 16 locales and required-only issues stay silent`() {
        val names = RelayFormValidation.IssueCode.entries.map { resourceName(it.messageRes) } +
            // The finer-grained reasons an endpoint can be rejected need every locale too.
            resourceName(
                RelayFormValidation.FieldIssue(
                    field = RelayFormValidation.Field.Endpoint,
                    code = RelayFormValidation.IssueCode.EndpointRejected,
                    detail = "embedded_query",
                ).messageRes,
            )
        val missing = mutableListOf<String>()
        localeStrings.forEach { (locale, byName) ->
            names.forEach { name ->
                if (byName[name].isNullOrBlank()) missing += "$locale/$name"
            }
        }
        assertTrue("Missing issue copy: $missing", missing.isEmpty())

        assertTrue(RelayFormValidation.IssueCode.EndpointRequired.isSilentRequirement)
        assertTrue(RelayFormValidation.IssueCode.CredentialRequired.isSilentRequirement)
        assertFalse(RelayFormValidation.IssueCode.EndpointRejected.isSilentRequirement)
        assertFalse(RelayFormValidation.IssueCode.SecurityModeSchemeMismatch.isSilentRequirement)
        assertFalse(RelayFormValidation.IssueCode.CleartextCredentials.isSilentRequirement)
        assertFalse(RelayFormValidation.IssueCode.CredentialInvalidCharacters.isSilentRequirement)
    }

    // Four-state credential matrix x {create, edit}

    @Test
    fun `every fixture case runs through the production decode path and the shared validator`() {
        val contract = contract()
        assertEquals(15, contract.cases.size)

        contract.cases.forEach { item ->
            val draft = productionDraft(item.draft)
            val mode = if (item.mode == "edit") {
                RelayFormValidation.FormMode.Edit
            } else {
                RelayFormValidation.FormMode.Create
            }
            val issues = RelayFormValidation.validate(draft, mode)

            assertEquals(
                "${item.caseId} expected valid=${item.expect.valid}, actual issues=${issues.map { it.code.value }}",
                item.expect.valid,
                issues.isEmpty(),
            )
            assertEquals(
                "${item.caseId} issue is attributed to the wrong field",
                item.expect.issues.map { it.field },
                issues.map { it.field.value },
            )
            assertEquals(
                "${item.caseId} issue code drifted",
                item.expect.issues.map { it.code },
                issues.map { it.code.value },
            )
            item.expect.issues.zip(issues).forEach { (expected, actual) ->
                expected.detail?.let {
                    assertEquals("${item.caseId}: detail for ${expected.code} drifted", it, actual.detail)
                }
            }
        }
    }

    @Test
    fun `each credential matrix state is covered in both create and edit`() {
        val contract = contract()
        assertEquals(4, contract.credentialMatrix.size)
        contract.credentialMatrix.forEach { state ->
            val modes = contract.cases.filter { it.matrixState == state.state }.map { it.mode }.sorted()
            assertEquals("matrix state ${state.state} does not cover both create and edit", listOf("create", "edit"), modes)
        }
    }

    // Delegation of the verdicts, so the underlying rules are never reimplemented here

    @Test
    fun `credential gate is delegated to requiresCredential using the production template factory`() {
        // The same template factory the add flow actually persists through.
        val bearer = RelayKindDefaults.makeRequested(RelayKind.OpenAICompatible)
        val keyless = RelayKindDefaults.makeRequested(
            RelayKind.Custom,
            preserving = RelayRequestedConfig(authMode = RelayAuthMode.None),
        ).copy(authMode = RelayAuthMode.None)

        val bearerDraft = RelayFormDraft(requested = bearer, endpoint = "https://relay.example.com/v1")
        val keylessDraft = RelayFormDraft(requested = keyless, endpoint = "https://relay.example.com/v1")

        assertEquals(
            listOf(RelayFormValidation.IssueCode.CredentialRequired),
            RelayFormValidation.validate(bearerDraft, RelayFormValidation.FormMode.Create).map { it.code },
        )
        assertTrue(
            RelayFormValidation.validate(keylessDraft, RelayFormValidation.FormMode.Create).isEmpty(),
        )
        // Editing never treats the key as required: leaving it blank means keep the stored one.
        assertTrue(RelayFormValidation.validate(bearerDraft, RelayFormValidation.FormMode.Edit).isEmpty())
    }

    @Test
    fun `endpoint gate matches the save path requireConfigured verdict`() {
        val requested = json.decodeFromString(
            RelayRequestedConfig.serializer(),
            """{"transport":"openai_chat_completions","authMode":"none","securityMode":"local_http"}""",
        )
        listOf(
            "http://192.168.1.20:1234/v1",
            "http://203.0.113.8:1234/v1",
            "http://user:pass@192.168.1.20:1234",
            "ftp://192.168.1.20:1234",
        ).forEach { endpoint ->
            val draft = RelayFormDraft(requested = requested, endpoint = endpoint)
            val formSaysOK =
                RelayFormValidation.validate(draft, RelayFormValidation.FormMode.Edit).isEmpty()
            val savePathSaysOK = runCatching {
                RelayEndpointPolicy.requireConfigured(
                    baseUrl = endpoint,
                    securityMode = RelayConnectionSecurityMode.LocalHttp,
                    credentials = RelayEndpointPolicy.credentialsOf(requested, hasKey = false),
                )
            }.isSuccess
            assertEquals("$endpoint: the form and the save path reached different verdicts", savePathSaysOK, formSaysOK)
        }
    }

    @Test
    fun `normalized endpoint is exactly what the save path would persist`() {
        val requested = json.decodeFromString(
            RelayRequestedConfig.serializer(),
            """{"transport":"openai_chat_completions","authMode":"none","securityMode":"local_http"}""",
        )
        val draft = RelayFormDraft(requested = requested, endpoint = "192.168.1.20:1234/v1/")
        assertEquals(
            "http://192.168.1.20:1234/v1",
            RelayFormValidation.normalizedEndpoint(draft, RelayFormValidation.FormMode.Edit),
        )
        // When validation fails there is no normalized result, so a caller can never take an
        // address that merely looks usable and write it to storage. The case below uses
        // userinfo in the URL, which is rejected unconditionally: a public IP is in fact not
        // catchable at the form stage, because for anything other than remote_https
        // requireConfigured is fed a structural 127.0.0.1 placeholder resolution and the real
        // DNS verdict only happens on the send path.
        val rejected = RelayFormDraft(requested = requested, endpoint = "http://user:pass@192.168.1.20:1234")
        assertNull(RelayFormValidation.normalizedEndpoint(rejected, RelayFormValidation.FormMode.Edit))
    }

    @Test
    fun `a cleartext lan endpoint saved as remote_https is the zombie config the form must block`() {
        // The add screen has no UI for picking a connection mode, so what it persists is
        // always remote_https. canSubmit used to check only "endpoint non-empty plus a key",
        // which let a cleartext LAN address be saved and then hard-rejected on every send.
        val requested = RelayKindDefaults.makeRequested(RelayKind.OpenAICompatible)
        val draft = RelayFormDraft(
            requested = requested,
            endpoint = "http://192.168.1.10:1234/v1",
            apiKey = "sk-relay-0123456789abcdef",
        )
        val issues = RelayFormValidation.validate(draft, RelayFormValidation.FormMode.Create)
        assertEquals(listOf(RelayFormValidation.IssueCode.EndpointRejected), issues.map { it.code })
        assertEquals("cleartext_not_allowed", issues.single().detail)
        // The same config is rejected on the save path: the form blocks exactly what the send
        // path would have hard-rejected.
        assertTrue(
            runCatching {
                RelayEndpointPolicy.requireConfigured(
                    baseUrl = "http://192.168.1.10:1234/v1",
                    securityMode = RelayConnectionSecurityMode.RemoteHttps,
                    credentials = RelayEndpointPolicy.credentialsOf(requested, hasKey = true),
                )
            }.isFailure,
        )
    }

    // Fixture loading

    /** The fixture's protocol fields go through the production decode path and then the production draft factory; the test never hand-writes a RelayRequestedConfig. */
    private fun productionDraft(raw: FixtureDraft): RelayFormDraft {
        val payload: JsonObject = buildJsonObject {
            put("transport", raw.transport)
            put("authMode", raw.authMode)
            put("securityMode", raw.securityMode)
            if (raw.modelId.isNotEmpty()) put("modelID", raw.modelId)
            if (raw.headers.isNotEmpty()) {
                put(
                    "headers",
                    buildJsonArray {
                        raw.headers.forEach {
                            add(
                                buildJsonObject {
                                    put("key", JsonPrimitive(it.key))
                                    put("value", JsonPrimitive(it.value))
                                },
                            )
                        }
                    },
                )
            }
            if (raw.queryParams.isNotEmpty()) {
                put(
                    "queryParams",
                    buildJsonArray {
                        raw.queryParams.forEach {
                            add(
                                buildJsonObject {
                                    put("key", JsonPrimitive(it.key))
                                    put("value", JsonPrimitive(it.value))
                                },
                            )
                        }
                    },
                )
            }
        }
        val requested = json.decodeFromJsonElement(RelayRequestedConfig.serializer(), payload)
        return RelayFormDraft(
            requested = requested,
            endpoint = raw.endpoint,
            apiKey = raw.apiKey,
            hasSavedCredential = raw.hasSavedCredential,
        )
    }

    private fun contract(): FormContract {
        var dir = File(System.getProperty("user.dir") ?: ".")
        repeat(8) {
            val candidate = File(dir, "shared/test-fixtures/relay/form-validation.v1.json")
            if (candidate.exists()) {
                return json.decodeFromString(FormContract.serializer(), candidate.readText())
            }
            dir = dir.parentFile ?: return@repeat
        }
        error("form-validation.v1.json not found")
    }

    /** Resource id to resource name. The reverse lookup anchors the assertion on the resource the production definition actually references, instead of copying the name out again. */
    private fun resourceName(id: Int): String = R.string::class.java.fields
        .firstOrNull { it.getInt(null) == id }
        ?.name
        ?: error("unknown string resource id: $id")

    private val localeStrings: Map<String, Map<String, String>> by lazy {
        val res = File(androidRoot, "app/src/main/res")
        val dirs = res.listFiles().orEmpty()
            .filter { it.isDirectory && it.name.startsWith("values") && it.name != "values-night" }
            .filter { File(it, "strings.xml").exists() }
        assertEquals("Unexpected locale count", 16, dirs.size)
        val factory = DocumentBuilderFactory.newInstance()
        dirs.associate { directory ->
            val nodes = factory.newDocumentBuilder()
                .parse(File(directory, "strings.xml"))
                .getElementsByTagName("string")
            directory.name to (0 until nodes.length)
                .map { nodes.item(it) as Element }
                .associate { it.getAttribute("name") to it.textContent.orEmpty() }
        }
    }

    private val englishStrings: Map<String, String> get() = localeStrings.getValue("values")

    private val androidRoot: File by lazy {
        var dir = File(System.getProperty("user.dir") ?: ".")
        repeat(8) {
            if (File(dir, "app/src/main/res/values/strings.xml").exists()) return@lazy dir
            dir = dir.parentFile ?: return@repeat
        }
        error("Cannot find Android project root")
    }

    @Serializable
    private data class FormContract(
        val version: Int,
        val form: FixtureForm,
        val credentialMatrix: List<FixtureMatrixState>,
        val cases: List<FixtureCase>,
    )

    @Serializable
    private data class FixtureForm(val fields: List<FixtureField>)

    @Serializable
    private data class FixtureField(
        val field: String,
        val group: String,
        val labelEN: String? = null,
        val placeholder: String? = null,
        val revalidation: String,
    )

    @Serializable
    private data class FixtureMatrixState(val state: String)

    @Serializable
    private data class FixtureCase(
        val caseId: String,
        val matrixState: String? = null,
        val mode: String,
        val draft: FixtureDraft,
        val expect: FixtureExpectation,
    )

    @Serializable
    private data class FixtureDraft(
        val endpoint: String,
        val apiKey: String,
        val authMode: String,
        val securityMode: String,
        val transport: String,
        val modelId: String,
        val headers: List<FixtureKeyValue> = emptyList(),
        val queryParams: List<FixtureKeyValue> = emptyList(),
        val hasSavedCredential: Boolean,
    )

    @Serializable
    private data class FixtureKeyValue(val key: String, val value: String)

    @Serializable
    private data class FixtureExpectation(
        val valid: Boolean,
        val issues: List<FixtureIssue> = emptyList(),
    )

    @Serializable
    private data class FixtureIssue(
        val field: String,
        val code: String,
        val detail: String? = null,
    )
}
