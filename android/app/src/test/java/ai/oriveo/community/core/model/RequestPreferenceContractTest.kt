package ai.oriveo.community.core.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.contentOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths


class RequestPreferenceContractTest {

    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun ownedPatchCompilerConsumesSharedFixtureAndPreservesNestedDelta() {
        val fixture = json.parseToJsonElement(contractText("owned_patch_compiler.v1.json")) as JsonObject
        assertEquals("owned_patch_compiler.v1", fixture["contractId"]!!.jsonPrimitive.content)
        for (raw in fixture["cases"]!!.jsonArray) {
            val item = raw as JsonObject
            val operations = (item["operations"] as JsonArray).map { rawOp ->
                val op = rawOp as JsonObject
                RequestPreferenceResolver.OverlayOperation(op["owner"]!!.jsonPrimitive.content, op["op"]!!.jsonPrimitive.content, op["pointer"]!!.jsonPrimitive.content, op["value"])
            }
            val contributions = (item["contributions"] as JsonArray).map { rawContribution ->
                val c = rawContribution as JsonObject
                RequestPreferenceResolver.ToolContribution(c["owner"]!!.jsonPrimitive.content, c["target"]!!.jsonPrimitive.content, c["operation"]!!.jsonPrimitive.content, c["identity"]!!.jsonPrimitive.content, c["value"])
            }
            val base = (item["base"] as JsonObject).mapValues { (_, values) -> values.jsonArray }
            val conflicts = (item["declaredConflicts"] as? JsonArray)?.map { pair -> pair.jsonArray[0].jsonPrimitive.content to pair.jsonArray[1].jsonPrimitive.content }.orEmpty()
            val result = RequestPreferenceResolver.compileOwnedPatches(RequestPreferenceResolver.OverlayIntent("body_fragment", RequestPreferenceResolver.OverlayMetrics(32, 2, 2), (item["declaredOwners"] as JsonObject).mapValues { it.value.jsonPrimitive.content }, operations), conflicts, base, contributions)
            val expected = item["expect"] as JsonObject
            assertEquals(item["caseId"]!!.jsonPrimitive.content, expected["accepted"]!!.jsonPrimitive.boolean, result.accepted)
            assertEquals(item["caseId"]!!.jsonPrimitive.content, expected["reason"]?.jsonPrimitive?.contentOrNull, result.reason)
            expected["delta"]?.let { assertEquals(item["caseId"]!!.jsonPrimitive.content, it, result.delta) }
            expected["preview"]?.let { assertEquals(item["caseId"]!!.jsonPrimitive.content, it, result.preview) }
        }
    }

    // ==================================================================
    
    // ==================================================================

    @Test
    fun resolutionCasesMatchScopePriorityAndTerminalStates() {
        val contract = loadPreferenceContract()
        assertTrue("fixture must be non-empty", contract.fixtures.resolutionCases.isNotEmpty())
        for (case in contract.fixtures.resolutionCases) {
            val layers = case.layers.map {
                RequestPreferenceResolver.ScopeLayer(
                    scope = it.scope,
                    override = RequestPreferenceResolver.Override(
                        state = RequestPreferenceResolver.OverrideState.valueOf(it.override.state.uppercase()),
                        value = it.override.value,
                    ),
                )
            }
            val outcome = RequestPreferenceResolver.resolveLayers(layers)
            assertEquals(case.caseId, case.expect.state, outcome.state.name.lowercase())
            assertEquals(case.caseId, case.expect.value, outcome.value)
            assertEquals(case.caseId, case.expect.source, outcome.source)
            assertEquals(case.caseId, case.expect.reason, outcome.reason)
        }
    }

    @Test
    fun selectionCasesNeverConfusePresetAndCustomOnly() {
        val contract = loadPreferenceContract()
        for (case in contract.fixtures.selectionCases) {
            val intent = RequestPreferenceResolver.SelectionIntent(
                availability = RequestPreferenceResolver.ControlAvailability.valueOf(case.intent.availability.uppercase()),
                selection = RequestPreferenceResolver.ValueMode.valueOf(case.intent.selection.uppercase()),
                access = RequestPreferenceResolver.ConnectionAccess.valueOf(case.intent.access.uppercase()),
            )
            val result = RequestPreferenceResolver.resolveSelection(intent)
            assertEquals(case.caseId, case.expect.allowed, result.allowed)
            assertEquals(case.caseId, case.expect.reason, result.reason)
        }
    }

    @Test
    fun conflictCasesRejectInsteadOfLastWriteWins() {
        val contract = loadPreferenceContract()
        for (case in contract.fixtures.conflictCases) {
            val assignments = case.assignments.map { RequestPreferenceResolver.Assignment(it.owner, it.pointer) }
            val declared = case.declaredConflicts.map { it[0] to it[1] }
            val result = RequestPreferenceResolver.validateAssignments(assignments, declared)
            assertEquals(case.caseId, case.expect.accepted, result.accepted)
            assertEquals(case.caseId, case.expect.reason, result.reason)
        }
    }

    @Test
    fun safeOverlayCasesEnforceOwnershipAndHardening() {
        val contract = loadPreferenceContract()
        for (case in contract.fixtures.safeOverlayCases) {
            val intent = RequestPreferenceResolver.OverlayIntent(
                channel = case.intent.channel,
                metrics = RequestPreferenceResolver.OverlayMetrics(
                    bytes = case.intent.metrics.bytes,
                    depth = case.intent.metrics.depth,
                    nodes = case.intent.metrics.nodes,
                ),
                declaredOwners = case.intent.declaredOwners,
                operations = case.intent.operations.map {
                    RequestPreferenceResolver.OverlayOperation(it.owner, it.op, it.pointer, it.value)
                },
            )
            val result = RequestPreferenceResolver.validateOverlay(intent)
            assertEquals(case.caseId, case.expect.accepted, result.accepted)
            assertEquals(case.caseId, case.expect.reason, result.reason)
        }
    }

    @Test
    fun toolContributionCasesOnlyAllowTypedAppendOnly() {
        val contract = loadPreferenceContract()
        for (case in contract.fixtures.toolContributionCases) {
            val contributions = case.contributions.map {
                RequestPreferenceResolver.ToolContribution(it.owner, it.target, it.operation, it.identity, it.value)
            }
            val result = RequestPreferenceResolver.composeContributions(case.base, contributions)
            assertEquals(case.caseId, case.expect.accepted, result.accepted)
            assertEquals(case.caseId, case.expect.identities, result.identities)
            assertEquals(case.caseId, case.expect.reason, result.reason)
        }
    }

    @Test
    fun resultCasesKeepRequestedAndObservedSeparate() {
        val contract = loadPreferenceContract()
        for (case in contract.fixtures.resultCases) {
            val intent = RequestPreferenceResolver.ResultIntent(
                wireApplied = case.intent.wireApplied,
                providerAccepted = case.intent.providerAccepted,
                evidenceKinds = case.intent.evidenceKinds,
                recovered = case.intent.recovered,
            )
            val result = RequestPreferenceResolver.classifyResult(intent)
            assertEquals(case.caseId, case.expect.state, result.state)
            assertEquals(case.caseId, case.expect.requested, result.requested)
            assertEquals(case.caseId, case.expect.observed, result.observed)
        }
    }

    @Test
    fun continuationCasesAreBoundedPerKind() {
        val contract = loadPreferenceContract()
        val covered = mutableSetOf<String>()
        for (case in contract.fixtures.continuationCases) {
            val intent = RequestPreferenceResolver.ContinuationIntent(
                kind = case.intent.kind,
                variant = case.intent.variant,
                step = case.intent.step,
                state = case.intent.state,
            )
            val result = RequestPreferenceResolver.validateContinuation(intent)
            assertEquals(case.caseId, case.expect.accepted, result.accepted)
            assertEquals(case.caseId, case.expect.reason, result.reason)
            if (result.accepted) covered += case.intent.kind
        }
        
        assertEquals(setOf("none", "previous_id", "replay_blocks", "replay_reasoning", "tool_loop"), covered)
    }

    @Test
    fun retryCasesNeverAutoRetryAndOnlyOfferOneLocatedExplicitResend() {
        val contract = loadPreferenceContract()
        for (case in contract.fixtures.retryCases) {
            val intent = RequestPreferenceResolver.RetryIntent(
                source = case.intent.source,
                status = case.intent.status,
                errorClass = case.intent.errorClass,
                owner = case.intent.owner,
                locatedPointers = case.intent.locatedPointers,
                preToken = case.intent.preToken,
                streamStarted = case.intent.streamStarted,
                sideEffects = case.intent.sideEffects,
                automaticRetryCount = case.intent.automaticRetryCount,
            )
            val result = RequestPreferenceResolver.resolveRetry(intent)
            assertEquals(case.caseId, case.expect.retry, result.retry)
            assertEquals(case.caseId, case.expect.action, result.action)
        }
    }

    @Test
    fun p5SharedRecoveryMatrixConsumesServerDefinitionsAndFailsClosedWithoutExactMatcher() {
        val root = json.parseToJsonElement(contractText("provider_recipe_result_facts.v1.json")) as JsonObject
        val resultDefinitions = json.parseToJsonElement(serverResultDefinitionsText()) as JsonObject
        val definitions = resultDefinitions["responseEvidenceDefinitions"] as? JsonObject
            ?: throw AssertionError("Server P5 result definitions must carry responseEvidenceDefinitions")
        val runtime = json.parseToJsonElement(serverRuntimeText()) as JsonObject
        val recipes = runtime["recipes"] as? JsonObject ?: throw AssertionError("Server runtime must carry recipes")
        
        
        
        val recipeBindings = resultDefinitions["recipeBindings"] as? JsonObject
            ?: throw AssertionError("Server P5 result definitions must carry recipeBindings")
        val locatorRules = (resultDefinitions["errorRecoveryDefinitions"] as? JsonObject)
            ?.get("locatorRules") as? JsonObject
            ?: throw AssertionError("Server P5 definitions must carry structured locatorRules")
        val coverage = root["providerResultCoverage"]!!.jsonArray
        val cases = root["recoveryCases"]!!.jsonArray
        assertEquals("one shared result case per official provider", 15, coverage.size)
        val providers = coverage.map { (it as JsonObject)["providerKind"]!!.jsonPrimitive.content }.toSet()
        assertEquals("provider coverage rows must not duplicate a provider", coverage.size, providers.size)
        coverage.forEach { raw ->
            val item = raw as JsonObject
            val recipeRef = item["recipeRef"]!!.jsonPrimitive.content
            assertTrue(recipeRef.isNotBlank())
            assertTrue(item["producerFixture"]!!.jsonPrimitive.content.isNotBlank())
            
            
            val capability = (recipes[recipeRef] as? JsonObject)?.get("capability")?.jsonPrimitive?.contentOrNull
            assertEquals(
                "$recipeRef capability=$capability expectation",
                capability == "generation",
                item["expected"]!!.jsonPrimitive.content == "no_execution_fact",
            )
        }
        assertTrue("shared P5 recovery matrix must be non-empty", cases.isNotEmpty())
        val consumed = linkedSetOf<String>()
        for (raw in cases) {
            val item = raw as JsonObject
            val caseId = item["caseId"]!!.jsonPrimitive.content
            val source = item["source"]!!.jsonPrimitive.content
            val recipeRef = item["recipeRef"]!!.jsonPrimitive.content
            recipes[recipeRef] as? JsonObject ?: throw AssertionError("$caseId recipe missing from Server runtime")
            val binding = recipeBindings[recipeRef] as? JsonObject
                ?: throw AssertionError("$caseId recipe carries no P5 binding on Server")
            val evidenceRef = binding["responseEvidenceRef"]?.jsonPrimitive?.contentOrNull
            assertTrue("$caseId must bind recovery to an exact response evidence definition", !evidenceRef.isNullOrBlank())
            assertTrue("$caseId evidence definition missing", definitions.containsKey(evidenceRef))
            
            assertEquals(caseId, evidenceRef, binding["errorRecoveryRef"]?.jsonPrimitive?.contentOrNull)
            // All recovery permissions are Server-owned; no Android error-class heuristic is
            // consulted. Empty locators are the current baseline; any future non-empty rule also
            // remains fail-closed until a reviewed exact matcher is introduced in production.
            
            assertFalse(caseId, locatorRules.containsKey(evidenceRef))
            
            
            assertTrue(caseId, item["automaticRetryCount"]!!.jsonPrimitive.content.toInt() <= 1)
            assertEquals(
                caseId,
                if (source == "custom") "user_confirmed_resend_without_located_setting" else "surface_error",
                item["expected"]!!.jsonPrimitive.content,
            )
            consumed += caseId
        }
        assertEquals(cases.size, consumed.size)
    }

    // ==================================================================
    
    // ==================================================================

    @Test
    fun runtimeEnvelopeCasesFailSafeWithoutBreakingChat() {
        val contract = loadShapeContract()
        for (case in contract.fixtures.runtimeEnvelopeCases) {
            val result = RequestPreferenceResolver.validateEnvelope(case.payload)
            assertEquals(case.caseId, case.expect.applied, result.applied)
            assertEquals(case.caseId, case.expect.action, result.action)
            assertEquals(case.caseId, case.expect.reason, result.reason)
            assertEquals(case.caseId, case.expect.chatContinues, result.chatContinues)
        }
    }

    @Test
    fun controlResolutionCasesDegradePerKeyInsteadOfPartialApply() {
        val contract = loadShapeContract()
        val sourceIndexKeys = contract.fixtures.sharedSourceIndex.keys
        val definitionOwners = contract.fixtures.controlDefinitionOwners()
        for (case in contract.fixtures.controlResolutionCases) {
            val controls = case.capabilityControls.mapValues { (_, entry) -> entry.toResolverEntry() }
            val resolution = RequestPreferenceResolver.resolveControls(case.providerKind, controls, case.recipes, sourceIndexKeys, definitionOwners)
            assertControlsResolutionMatches(case.caseId, case.expect, resolution)
        }
    }

    @Test
    fun reasoningIntentCasesStaySubsetOrderedNeverGapFilled() {
        val contract = loadShapeContract()
        for (case in contract.fixtures.reasoningIntentCases) {
            val result = RequestPreferenceResolver.validateIntents(case.capability, case.intents)
            assertEquals(case.caseId, case.expect.valid, result.valid)
            assertEquals(case.caseId, case.expect.reason, result.reason)
            assertEquals(case.caseId, case.expect.intents, result.intents)
        }
    }

    @Test
    fun providerUniverseCasesCoverAllSeventeenProviderKinds() {
        val contract = loadShapeContract()
        val sourceIndexKeys = contract.fixtures.sharedSourceIndex.keys
        val definitionOwners = contract.fixtures.controlDefinitionOwners()
        val covered = mutableSetOf<String>()
        for (case in contract.fixtures.providerUniverseCases) {
            val controls = case.capabilityControls.mapValues { (_, entry) -> entry.toResolverEntry() }
            val resolution = RequestPreferenceResolver.resolveControls(case.providerKind, controls, case.recipes, sourceIndexKeys, definitionOwners)
            assertControlsResolutionMatches(case.caseId, case.expect, resolution)
            covered += case.providerKind
        }
        assertEquals(16, covered.size)
        assertEquals(
            setOf(
                "openRouter", "openAI", "anthropic", "gemini", "groq", "deepseek", "siliconFlow",
                "togetherAI", "fireworksAI", "miniMax", "zhipu", "qwen", "grok", "moonshot", "mistral",
                "relay",
            ),
            covered,
        )
    }

    private fun assertControlsResolutionMatches(
        caseId: String,
        expect: ControlsExpectDto,
        actual: RequestPreferenceResolver.ControlsResolution,
    ) {
        assertEquals(caseId, expect.unknownCapabilities, actual.unknownCapabilities)
        assertEquals(caseId, expect.results.keys, actual.results.keys)
        for ((capability, expectedResult) in expect.results) {
            val actualResult = actual.results.getValue(capability)
            assertEquals("$caseId:$capability", expectedResult.valid, actualResult.valid)
            assertEquals("$caseId:$capability", expectedResult.state, actualResult.state)
            assertEquals("$caseId:$capability", expectedResult.action, actualResult.action)
            assertEquals("$caseId:$capability", expectedResult.reason, actualResult.reason)
        }
    }

    private fun ControlEntryDto.toResolverEntry() = RequestPreferenceResolver.ControlEntry(
        state = state,
        recipeRef = recipeRef,
        reasonCode = reasonCode,
        sourceRefs = sourceRefs,
        availableIntents = availableIntents,
        customControlRefs = customControlRefs,
    )

    
    private fun ShapeFixtures.controlDefinitionOwners(): Map<String, String> =
        sharedControlDefinitions.mapNotNull { (ref, raw) ->
            val owner = ((raw as? JsonObject)?.get("owner") as? JsonPrimitive)?.contentOrNull ?: return@mapNotNull null
            ref to owner
        }.toMap()

    // ------------------------------------------------------------------
    
    // ------------------------------------------------------------------

    private fun loadPreferenceContract(): PreferenceContractFile =
        json.decodeFromString(contractText("request_preference_contract.v2.json"))

    private fun loadShapeContract(): ShapeContractFile =
        json.decodeFromString(contractText("request_shape_contract.v2.json"))

    private fun contractText(fileName: String): String {
        val path = generateSequence(Paths.get("").toAbsolutePath()) { it.parent }
            .map { it.resolve("shared/model-contracts/$fileName") }
            .firstOrNull(Files::exists)
            ?: error("$fileName not found")
        return String(Files.readAllBytes(path), Charsets.UTF_8)
    }

    private fun serverResultDefinitionsText(): String {
        val suffix = "shared/capabilityrecipe/capability_result_definitions.v1.json"
        val path = generateSequence(Paths.get("").toAbsolutePath()) { it.parent }
            .map { it.resolve(suffix) }
            .firstOrNull(Files::exists)
            ?: error("Cannot locate Server P5 result definitions")
        return String(Files.readAllBytes(path), Charsets.UTF_8)
    }

    private fun serverRuntimeText(): String = serverCapabilityFileText("capability_runtime.v1.json")

    private fun serverCapabilityFileText(fileName: String): String {
        val suffix = "shared/capabilityrecipe/$fileName"
        val path = generateSequence(Paths.get("").toAbsolutePath()) { it.parent }
            .map { it.resolve(suffix) }
            .firstOrNull(Files::exists)
            ?: error("Cannot locate Server capability file $fileName")
        return String(Files.readAllBytes(path), Charsets.UTF_8)
    }

    // ------------------------------------------------------------------
    
    // ------------------------------------------------------------------

    @Serializable
    private data class PreferenceContractFile(val fixtures: PreferenceFixtures)

    @Serializable
    private data class PreferenceFixtures(
        val resolutionCases: List<ResolutionCase>,
        val selectionCases: List<SelectionCase>,
        val conflictCases: List<ConflictCase>,
        val safeOverlayCases: List<SafeOverlayCase>,
        val toolContributionCases: List<ToolContributionCase>,
        val resultCases: List<ResultCase>,
        val continuationCases: List<ContinuationCase>,
        val retryCases: List<RetryCase>,
    )

    @Serializable
    private data class ResolutionCase(val caseId: String, val owner: String, val layers: List<LayerDto>, val expect: ResolutionExpectDto)

    @Serializable
    private data class LayerDto(val scope: String, val override: OverrideDto)

    @Serializable
    private data class OverrideDto(val state: String, val value: JsonElement? = null)

    @Serializable
    private data class ResolutionExpectDto(val state: String, val value: JsonElement? = null, val source: String, val reason: String? = null)

    @Serializable
    private data class SelectionCase(val caseId: String, val intent: SelectionIntentDto, val expect: SelectionExpectDto)

    @Serializable
    private data class SelectionIntentDto(val availability: String, val selection: String, val access: String)

    @Serializable
    private data class SelectionExpectDto(val allowed: Boolean, val reason: String? = null)

    @Serializable
    private data class ConflictCase(
        val caseId: String,
        val assignments: List<AssignmentDto>,
        val declaredConflicts: List<List<String>>,
        val expect: ConflictExpectDto,
    )

    @Serializable
    private data class AssignmentDto(val owner: String, val pointer: String)

    @Serializable
    private data class ConflictExpectDto(val accepted: Boolean, val reason: String? = null)

    @Serializable
    private data class SafeOverlayCase(val caseId: String, val intent: OverlayIntentDto, val expect: OverlayExpectDto)

    @Serializable
    private data class OverlayIntentDto(
        val channel: String,
        val metrics: OverlayMetricsDto,
        val declaredOwners: Map<String, String>,
        val operations: List<OverlayOperationDto>,
    )

    @Serializable
    private data class OverlayMetricsDto(val bytes: Int, val depth: Int, val nodes: Int)

    @Serializable
    private data class OverlayOperationDto(val owner: String, val op: String, val pointer: String, val value: JsonElement? = null)

    @Serializable
    private data class OverlayExpectDto(val accepted: Boolean, val reason: String? = null)

    @Serializable
    private data class ToolContributionCase(
        val caseId: String,
        val base: List<String>,
        val contributions: List<ToolContributionDto>,
        val expect: ToolContributionExpectDto,
    )

    @Serializable
    private data class ToolContributionDto(val owner: String, val target: String, val operation: String, val identity: String, val value: JsonElement? = null)

    @Serializable
    private data class ToolContributionExpectDto(val accepted: Boolean, val identities: List<String>? = null, val reason: String? = null)

    @Serializable
    private data class ResultCase(val caseId: String, val intent: ResultIntentDto, val expect: ResultExpectDto)

    @Serializable
    private data class ResultIntentDto(val wireApplied: Boolean, val providerAccepted: Boolean, val evidenceKinds: List<String>, val recovered: Boolean = false)

    @Serializable
    private data class ResultExpectDto(val state: String, val requested: Boolean, val observed: Boolean)

    @Serializable
    private data class ContinuationCase(val caseId: String, val intent: ContinuationIntentDto, val expect: ContinuationExpectDto)

    @Serializable
    private data class ContinuationIntentDto(val kind: String, val variant: String? = null, val step: Int, val state: Map<String, JsonElement> = emptyMap())

    @Serializable
    private data class ContinuationExpectDto(val accepted: Boolean, val reason: String? = null)

    @Serializable
    private data class RetryCase(val caseId: String, val intent: RetryIntentDto, val expect: RetryExpectDto)

    @Serializable
    private data class RetryIntentDto(
        val source: String,
        val status: Int? = null,
        val errorClass: String,
        val owner: String? = null,
        val locatedPointers: List<String>,
        val preToken: Boolean,
        val streamStarted: Boolean,
        val sideEffects: Boolean,
        val automaticRetryCount: Int,
    )

    @Serializable
    private data class RetryExpectDto(val retry: Boolean, val action: String)

    // ------------------------------------------------------------------
    
    // ------------------------------------------------------------------

    @Serializable
    private data class ShapeContractFile(val fixtures: ShapeFixtures)

    @Serializable
    private data class ShapeFixtures(
        val sharedSourceIndex: Map<String, JsonElement>,
        val sharedControlDefinitions: Map<String, JsonElement>,
        val runtimeEnvelopeCases: List<RuntimeEnvelopeCase>,
        val controlResolutionCases: List<ControlResolutionCase>,
        val reasoningIntentCases: List<ReasoningIntentCase>,
        val providerUniverseCases: List<ProviderUniverseCase>,
    )

    @Serializable
    private data class RuntimeEnvelopeCase(val caseId: String, val payload: JsonObject, val expect: EnvelopeExpectDto)

    @Serializable
    private data class EnvelopeExpectDto(val applied: Boolean, val action: String, val reason: String? = null, val chatContinues: Boolean)

    @Serializable
    private data class ControlResolutionCase(
        val caseId: String,
        val providerKind: String,
        val recipes: List<String> = emptyList(),
        val capabilityControls: Map<String, ControlEntryDto>,
        val expect: ControlsExpectDto,
    )

    @Serializable
    private data class ControlEntryDto(
        val state: String,
        val recipeRef: String? = null,
        val reasonCode: String? = null,
        val sourceRefs: List<String>? = null,
        val availableIntents: List<String>? = null,
        val customControlRefs: List<String>? = null,
    )

    @Serializable
    private data class ControlsExpectDto(val unknownCapabilities: List<String>, val results: Map<String, ControlResultExpectDto>)

    @Serializable
    private data class ControlResultExpectDto(val valid: Boolean, val state: String, val action: String, val reason: String? = null)

    @Serializable
    private data class ReasoningIntentCase(val caseId: String, val capability: String, val intents: List<String>, val expect: IntentsExpectDto)

    @Serializable
    private data class IntentsExpectDto(val valid: Boolean, val reason: String? = null, val intents: List<String>)

    @Serializable
    private data class ProviderUniverseCase(
        val caseId: String,
        val providerKind: String,
        val recipes: List<String> = emptyList(),
        val capabilityControls: Map<String, ControlEntryDto>,
        val expect: ControlsExpectDto,
    )
}
