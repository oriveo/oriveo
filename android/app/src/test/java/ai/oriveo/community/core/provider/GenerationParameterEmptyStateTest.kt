package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.w3c.dom.Element

/**
 * In-app assertions for the four empty states of the generation-parameter container and for the
 * Relay "unverified" badge.
 *
 * Every assertion's input comes from a production code path: an official profile is parsed by
 * the production `MetadataClient` out of catalog-shaped metadata JSON and assembled into an
 * `AIModel` by the production `CatalogModelBuilder`, while a Relay profile is synthesised by the
 * production `LocalEngineGenerationProfiles`. The test never hand-writes a
 * `GenerationProfileRef`.
 */
class GenerationParameterEmptyStateTest {

    private lateinit var history: GenerationParameterProfileHistory

    @Before
    fun setUp() {
        history = freshHistory()
    }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    // --- The four empty states ---

    @Test
    fun `state A when this device has never seen a non-empty profile`() {
        val provider = officialProvider(modelWithoutProfile())
        val model = provider.models.first()
        val projection = generationProjection(provider, model)

        assertFalse(history.hasSeenNonEmptyProfile(provider.id, model.id))
        assertEquals(
            GenerationParameterEmptyState.NotVerified,
            GenerationParameterPanelPresentation.emptyState(
                provider = provider,
                model = model,
                scope = GenerationParameterEntryScope.ConnectionDefaults,
                access = GenerationAccess(canManageRuntime = true),
                hasSeenNonEmptyProfile = history.hasSeenNonEmptyProfile(provider.id, model.id),
                capabilityProjection = projection,
            ),
        )
    }

    @Test
    fun `state B after a previously seen profile was withdrawn, and it degrades to A once history is cleared`() {
        // The "has seen a non-empty one" step really runs the production parse chain and gets a
        // non-empty profile out of it, rather than just setting the flag.
        val seen = officialProvider(modelFromProductionMetadata(listOf(ParameterSpec("temperature", "supported"))))
        val model = seen.models.first()
        val declared = GenerationParameterAvailability.profile(seen, model)?.parameters?.size ?: 0
        assertTrue("the production parse chain must really produce a non-empty profile", declared > 0)
        history.recordSeenProfile(seen.id, model.id, declared)

        // The catalog withdraws it: same connection, same model, profile back to null.
        MetadataTestFixtures.clear()
        val withdrawn = seen.copy(models = listOf(modelWithoutProfile()))
        val withdrawnModel = withdrawn.models.first()
        val withdrawnProjection = generationProjection(withdrawn, withdrawnModel)
        assertEquals(
            GenerationParameterEmptyState.CatalogManaged,
            GenerationParameterPanelPresentation.emptyState(
                provider = withdrawn,
                model = withdrawnModel,
                scope = GenerationParameterEntryScope.ConnectionDefaults,
                access = GenerationAccess(canManageRuntime = true),
                hasSeenNonEmptyProfile = history.hasSeenNonEmptyProfile(withdrawn.id, withdrawnModel.id),
                capabilityProjection = withdrawnProjection,
            ),
        )

        // The known limitation: once the local history is wiped (reinstall, new device, cleared
        // cache), B degrades into A.
        history.reset()
        assertEquals(
            GenerationParameterEmptyState.NotVerified,
            GenerationParameterPanelPresentation.emptyState(
                provider = withdrawn,
                model = withdrawnModel,
                scope = GenerationParameterEntryScope.ConnectionDefaults,
                access = GenerationAccess(canManageRuntime = true),
                hasSeenNonEmptyProfile = history.hasSeenNonEmptyProfile(withdrawn.id, withdrawnModel.id),
                capabilityProjection = withdrawnProjection,
            ),
        )
    }

    @Test
    fun `state C wins over D when access is what emptied the panel`() {
        val provider = officialProvider(
            modelFromProductionMetadata(listOf(ParameterSpec("n_probs", "supported", group = "engine_runtime"))),
        )
        val model = provider.models.first()
        val projection = generationProjection(provider, model)

        // Access open, so there are visible parameters and this is not an empty state at all.
        assertNull(
            GenerationParameterPanelPresentation.emptyState(
                provider = provider,
                model = model,
                scope = GenerationParameterEntryScope.ConnectionDefaults,
                access = GenerationAccess(canManageRuntime = true),
                hasSeenNonEmptyProfile = false,
                capabilityProjection = projection,
            ),
        )

        val state = GenerationParameterPanelPresentation.emptyState(
            provider = provider,
            model = model,
            scope = GenerationParameterEntryScope.ConnectionDefaults,
            access = GenerationAccess(canManageRuntime = false),
            hasSeenNonEmptyProfile = false,
            capabilityProjection = projection,
        )
        assertEquals(GenerationParameterEmptyState.AllUnsupported, state)
        assertFalse(state!!.showsUpgradeAction)
    }

    @Test
    fun `state D when the session has no actionable row`() {
        val provider = officialProvider(
            modelFromProductionMetadata(listOf(ParameterSpec("temperature", "unsupported"))),
        )
        val model = provider.models.first()
        val projection = generationProjection(provider, model)
        assertTrue((GenerationParameterAvailability.profile(provider, model)?.parameters?.size ?: 0) > 0)

        listOf(true, false).forEach { entitled ->
            assertEquals(
                "an all-unsupported profile is not actionable in the session scope, so both access states must be D",
                GenerationParameterEmptyState.AllUnsupported,
                GenerationParameterPanelPresentation.emptyState(
                    provider = provider,
                    model = model,
                    scope = GenerationParameterEntryScope.Session,
                    access = GenerationAccess(canManageRuntime = entitled),
                    hasSeenNonEmptyProfile = false,
                    capabilityProjection = projection,
                ),
            )
        }
    }

    @Test
    fun `container never collapses - empty visible set always yields an empty state`() {
        // Each factory publishes and consumes one coherent metadata generation. Keeping old
        // models after another fixture publication would deliberately exercise a stale profile,
        // not the panel's empty-state invariant.
        val subjects = buildList<Pair<String, () -> Pair<Provider, AIModel>>> {
            add("official-no-profile" to {
                val provider = officialProvider(modelWithoutProfile())
                provider to provider.models.first()
            })
            listOf(
                "official-unsupported" to ParameterSpec("temperature", "unsupported"),
                "official-runtime-access-only" to ParameterSpec("n_probs", "supported", group = "engine_runtime"),
                "official-supported" to ParameterSpec("temperature", "supported"),
            ).forEach { (label, spec) ->
                add(label to {
                    val provider = officialProvider(modelFromProductionMetadata(listOf(spec)))
                    provider to provider.models.first()
                })
            }
            RELAY_TRANSPORTS.forEach { transport ->
                add("relay-${transport.value}" to {
                    val provider = relayProvider(transport = transport)
                    provider to provider.models.first()
                })
            }
        }

        val failures = mutableListOf<String>()
        subjects.forEach { (label, buildSubject) ->
            val (provider, model) = buildSubject()
            val projection = generationProjection(provider, model)
            GenerationParameterEntryScope.entries.forEach { scope ->
                listOf(true, false).forEach { entitled ->
                    val access = GenerationAccess(canManageRuntime = entitled)
                    val visible = GenerationParameterPanelPresentation
                        .visibleParameters(provider, model, scope, access, projection)
                    val state = GenerationParameterPanelPresentation.emptyState(
                        provider = provider,
                        model = model,
                        scope = scope,
                        access = access,
                        hasSeenNonEmptyProfile = false,
                        capabilityProjection = projection,
                    )
                    if (visible.isEmpty() && state == null) {
                        failures += "$label/$scope/entitled=$entitled: visible set is empty but there is no empty state (the container collapsed)"
                    }
                    if (visible.isNotEmpty() && state != null) {
                        failures += "$label/$scope/entitled=$entitled: there are visible parameters but an empty state was rendered"
                    }
                }
            }
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    // --- The Relay unverified badge ---

    @Test
    fun `every relay unknown parameter carries the unverified badge across transports and engine profiles`() {
        val failures = mutableListOf<String>()
        val engineProfiles = listOf(null, "llamacpp", "vllm", "openwebui")

        engineProfiles.forEach { engineProfile ->
            RELAY_TRANSPORTS.forEach { transport ->
                val provider = relayProvider(transport = transport, engineProfile = engineProfile)
                val model = provider.models.first()
                val profile = GenerationParameterAvailability.profile(provider, model)
                    ?: run {
                        failures += "relay/$engineProfile/${transport.value}: production profile synthesis returned null"
                        return@forEach
                    }
                val projection = generationProjection(provider, model)
                val rowBadges = profile.parameters.map { parameter ->
                    GenerationParameterPanelPresentation.showsUnverifiedBadge(parameter, projection)
                }
                if (profile.parameters.isNotEmpty() && rowBadges.none { it }) {
                    failures += "relay/$engineProfile/${transport.value}: accepted declaration lost every unverified badge"
                }
                assertEquals(
                    "relay/$engineProfile/${transport.value}: the group note must appear and disappear with the per-row badges of the production projection",
                    rowBadges.any { it },
                    GenerationParameterPanelPresentation.showsUnverifiedGroupNote(
                        profile.parameters,
                        projection,
                    ),
                )
            }
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun `official unknown is editable without a Relay declaration badge`() {
        val provider = officialProvider(modelFromProductionMetadata(listOf(ParameterSpec("temperature", "unknown"))))
        val model = provider.models.first()
        val profile = GenerationParameterAvailability.profile(provider, model)
        val parameters = profile?.parameters.orEmpty()
        assertTrue(parameters.isNotEmpty())
        val projection = generationProjection(provider, model)
        assertFalse(GenerationParameterPanelPresentation.showsUnverifiedGroupNote(parameters, projection))
        parameters.forEach {
            assertTrue(GenerationParameterAvailability.isEditable(provider, profile, it, projection))
            assertFalse(GenerationParameterPanelPresentation.showsUnverifiedBadge(it, projection))
        }
    }

    // --- Copy discipline ---

    @Test
    fun `empty state copy ships in all 16 locales and never renders a percentage`() {
        val res = File(androidRoot, "app/src/main/res")
        val localeDirs = res.listFiles().orEmpty()
            .filter { it.isDirectory && it.name.startsWith("values") && it.name != "values-night" }
            .filter { File(it, "strings.xml").exists() }
        assertEquals("Unexpected locale count", 16, localeDirs.size)

        val factory = DocumentBuilderFactory.newInstance()
        val missing = mutableListOf<String>()
        val forbidden = mutableListOf<String>()
        localeDirs.forEach { directory ->
            val nodes = factory.newDocumentBuilder().parse(File(directory, "strings.xml"))
                .getElementsByTagName("string")
            val byName = (0 until nodes.length)
                .map { nodes.item(it) as Element }
                .associate { it.getAttribute("name") to it.textContent.orEmpty() }
            EMPTY_STATE_KEYS.forEach { key ->
                val value = byName[key].orEmpty()
                if (value.isBlank()) missing += "${directory.name}/$key"
                // Never render a percentage or a progress number: that is evidence we do not have.
                if (value.contains('%')) forbidden += "${directory.name}/$key"
            }
        }
        assertTrue("Missing empty-state copy: $missing", missing.isEmpty())
        assertTrue("Empty-state copy must not render a percentage: $forbidden", forbidden.isEmpty())
    }

    // --- Local history ---

    @Test
    fun `history only records non-empty profiles`() {
        history.recordSeenProfile("provider", "model", parameterCount = 0)
        assertFalse(history.hasSeenNonEmptyProfile("provider", "model"))

        history.recordSeenProfile("provider", "model", parameterCount = 3)
        assertTrue(history.hasSeenNonEmptyProfile("provider", "model"))
        assertFalse(history.hasSeenNonEmptyProfile("provider", "other-model"))
    }

    // ── fixtures ───────────────────────────────────────────────────────────

    private data class ParameterSpec(val id: String, val support: String, val group: String? = null)

    private fun freshHistory(): GenerationParameterProfileHistory {
        var payload: String? = null
        return GenerationParameterProfileHistory(
            readPayload = { payload },
            writePayload = { payload = it },
        )
    }

    private fun modelWithoutProfile(): AIModel = AIModel(id = MODEL_ID, name = MODEL_ID)

    /** Goes through the production `MetadataClient` parse and the production
     *  `CatalogModelBuilder` assembly; the test never hand-writes a profile. */
    private fun modelFromProductionMetadata(parameters: List<ParameterSpec>): AIModel {
        val definitions = parameters.joinToString(",") { spec ->
            val group = spec.group?.let { "\"group\":\"$it\"," }.orEmpty()
            "\"${spec.id}\":{$group\"valueSchema\":\"number\"}"
        }
        val refs = parameters.joinToString(",") { spec ->
            "{\"id\":\"${spec.id}\",\"support\":\"${spec.support}\",\"source\":\"measured\"}"
        }
        val wire = parameters.joinToString(",") { "\"${it.id}\":\"${it.id}\"" }
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "profiles": {
                "generation": {
                  "version": 1,
                  "parameters": {$definitions},
                  "templates": {
                    "openai_chat_completions": {
                      "transport": "openai_chat",
                      "wire": {$wire}
                    }
                  }
                }
              },
              "providers": {
                "openAI": {
                  "defaultModelId": "$MODEL_ID",
                  "resolveMap": {"$MODEL_ID": "$MODEL_ID"},
                  "models": {
                    "$MODEL_ID": {
                      "displayName": "$MODEL_ID",
                      "canonicalModelId": "$MODEL_ID",
                      "transport": "openai_chat",
                      "profiles": {
                        "generation": {
                          "template": "openai_chat_completions",
                          "parameters": [$refs]
                        }
                      }
                    }
                  }
                }
              }
            }
            """.trimIndent(),
        )
        return CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.OpenAI,
            runtimeModelId = MODEL_ID,
            fallbackName = MODEL_ID,
        )
    }

    private fun officialProvider(model: AIModel): Provider = Provider(
        id = PROVIDER_ID,
        kind = ProviderKind.OpenAI,
        models = listOf(model),
    )

    private fun relayProvider(transport: RelayTransport, engineProfile: String? = null): Provider = Provider(
        id = PROVIDER_ID,
        kind = ProviderKind.Relay,
        models = listOf(modelWithoutProfile()),
        baseUrlText = "https://relay.example",
        relayRequested = RelayRequestedConfig(transport = transport, engineProfile = engineProfile),
    )

    private fun generationProjection(
        provider: Provider,
        model: AIModel,
    ) = CapabilityEvidenceProductionAdapter.generationParameterUiProjection(
        provider = provider,
        model = model,
        localIdentity = provider.takeIf { it.kind == ProviderKind.Relay }?.let {
            CapabilityEvidenceIdentity("test", it.id, "1", "1", ProviderKind.Relay.rawValue)
        },
        parameters = GenerationParameterAvailability.profile(provider, model)?.parameters.orEmpty(),
        values = ai.oriveo.community.core.model.GenerationParameterOverrides(),
    )

    private val androidRoot: File by lazy {
        var dir = File(System.getProperty("user.dir") ?: ".")
        repeat(8) {
            if (File(dir, "app/src/main/res/values/strings.xml").exists()) return@lazy dir
            dir = dir.parentFile ?: return@repeat
        }
        error("Cannot find Android project root")
    }

    private companion object {
        const val PROVIDER_ID = "11111111-1111-1111-1111-111111111111"
        const val MODEL_ID = "gpt-test"

        val RELAY_TRANSPORTS = listOf(
            RelayTransport.OpenAIChatCompletions,
            RelayTransport.OpenAIResponses,
            RelayTransport.AnthropicMessages,
            RelayTransport.GeminiGenerateContent,
        )

        val EMPTY_STATE_KEYS = listOf(
            "generation_parameters_section",
            "generation_empty_not_verified",
            "generation_empty_not_verified_detail",
            "generation_empty_catalog_managed",
            "generation_empty_runtime_locked",
            "generation_empty_all_unsupported",
            "generation_parameter_unverified_badge",
            "generation_parameter_unverified_group_note",
        )
    }
}
