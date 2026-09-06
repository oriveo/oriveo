package ai.oriveo.community.core.provider

import ai.oriveo.community.R
import ai.oriveo.community.core.model.GenerationParameterRef
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Eight engineering states collapsed into three user-visible classes.
 *
 * The single source of truth for the table is the shared contract at
 * `generation_parameter_contract.v1.json#presentationClasses`, and this reconciles the Android projection against it
 * entry by entry. **Every `support` value the contract has ever carried must belong to one of the classes**: a ninth
 * state added upstream has to fail here at test time rather than fall silently into the default and read as "no
 * information yet".
 */
class GenerationParameterSupportPresentationContractTest {
    private val json = Json { ignoreUnknownKeys = true }

    private val contract: JsonObject by lazy {
        json.parseToJsonElement(
            workspaceFile("shared/model-contracts/generation_parameter_contract.v1.json").readText(),
        ).jsonObject
    }

    private val presentation: JsonObject by lazy { contract["presentationClasses"]!!.jsonObject }

    /** The three properties of a class (renders, control, whether it carries a primary action) are matched to the contract word for word. */
    @Test
    fun `every presentation class mirrors the shared contract`() {
        val classes = presentation["classes"]!!.jsonArray.map { it.jsonObject }
        assertEquals(
            "the number of classes and their ids must match the contract",
            classes.map { it["classId"]!!.jsonPrimitive.content },
            GenerationParameterSupportPresentation.PresentationClass.entries.map { it.id },
        )
        classes.forEach { declared ->
            val classId = declared["classId"]!!.jsonPrimitive.content
            // Look the Entry up through a support value that really lands on this class, so the projection under test is the same class.
            val support = presentation["supportMap"]!!.jsonObject.entries
                .first { it.value.jsonObject["class"]!!.jsonPrimitive.content == classId }
                .key
            val entry = GenerationParameterSupportPresentation.entryForRegistered(support)
            assertNotNull("$support is not registered", entry)
            assertEquals(classId, entry!!.presentationClass.id)
            assertEquals(
                "$classId renders",
                declared["renders"]!!.jsonPrimitive.content.toBoolean(),
                entry.renders,
            )
            assertEquals(
                "$classId control",
                declared["control"]!!.jsonPrimitive.content,
                entry.control.id,
            )
            // `renders: false` has no label key; the other three classes must each point at a real resource.
            if (entry.renders) assertNotNull("$classId is missing its class-level label", entry.labelRes)
            else assertNull("$classId is the silent normal state and must not carry a label", entry.labelRes)
            // A greyed-out control has to come with a primary action, or it is another dead end for the user.
            val hasPrimaryAction = declared["primaryAction"] != null
            assertEquals("$classId primaryAction", hasPrimaryAction, entry.primaryActionRes != null)
        }
    }

    /** Every engineering state in the contract's `supportMap` has to land on one class and bring its own detail copy. */
    @Test
    fun `every support value in the contract has a home in the android table`() {
        val supportMap = presentation["supportMap"]!!.jsonObject
        assertEquals(
            "the engineering states in the contract and the Android table must match exactly (a ninth state turns red here)",
            supportMap.keys,
            GenerationParameterSupportPresentation.registeredSupports,
        )
        supportMap.forEach { (support, raw) ->
            val declared = raw.jsonObject
            val entry = GenerationParameterSupportPresentation.entryForRegistered(support)
            assertNotNull("$support is not registered", entry)
            assertEquals(support, declared["class"]!!.jsonPrimitive.content, entry!!.presentationClass.id)
            val hasDetail = declared["detailKey"] != null
            assertEquals("$support detailKey", hasDetail, entry.detailRes != null)
        }
        // The support surface declared by the schema must not be wider than supportMap either: anything wider is exactly what
        // would silently degrade to "unknown".
        val schemaSupport = contract["schema"]!!.jsonObject["support"]!!.jsonArray
            .map { it.jsonPrimitive.content }
            .toSet()
        assertEquals("schema.support and supportMap must cover the same set", schemaSupport, supportMap.keys)
    }

    /** The three non-normal classes each say their own thing; no two states may share a sentence, which is precisely the shape that used to describe three different situations as "unknown". */
    @Test
    fun `unsupported future_supported and unknown are three different sentences`() {
        val unsupported = GenerationParameterSupportPresentation.entryForRegistered("unsupported")!!
        val unknown = GenerationParameterSupportPresentation.entryForRegistered("unknown")!!
        val future = GenerationParameterSupportPresentation.entryForRegistered("future_supported")!!
        assertNotEquals("'this parameter is not accepted' must not share a sentence with 'no information'", unsupported.detailRes, unknown.detailRes)
        assertNotEquals("'announced but not available' must not share a sentence with 'no information'", future.detailRes, unknown.detailRes)
        assertNotEquals(unsupported.labelRes, unknown.labelRes)
        // 'not adjustable' has to actually grey the control out and offer a primary action.
        assertEquals(GenerationParameterSupportPresentation.Control.Disabled, unsupported.control)
        assertEquals(R.string.model_control_view_supported_models, unsupported.primaryActionRes)
        assertEquals(GenerationParameterSupportPresentation.Control.Disabled, future.control)
        assertEquals(R.string.model_control_view_supported_models, future.primaryActionRes)
        // The normal state says nothing at all.
        listOf("supported", "accepted").forEach {
            val entry = GenerationParameterSupportPresentation.entryForRegistered(it)!!
            assertTrue("$it must stay silent in the normal state", !entry.renders && entry.labelRes == null)
        }
    }

    /**
     * Reachability of `accepted_unverified`, which used to be dead code.
     *
     * The evidence facade flattens it to `unknown` before it ever reaches the UI
     * ([CapabilityEvidenceFacade.normalizeGenerationParameter]), so as long as the presentation layer reads the evidence
     * support directly this label is structurally unreachable. The fix is to let **evidence only veto and downgrade**,
     * while the engineering state itself keeps coming from the profile declaration.
     */
    @Test
    fun `accepted_unverified is reachable because evidence only vetoes and downgrades`() {
        val identity = CapabilityEvidenceFacade.CandidateIdentity(
            providerKind = "openAI",
            modelId = "gpt",
            effectiveTransport = "openai_chat",
        )
        val normalized = CapabilityEvidenceFacade.normalizeGenerationParameter(
            raw = GenerationParameterRef(id = "top_p", support = "accepted_unverified"),
            identity = identity,
        )
        // Prove the premise: the facade really does flatten it, so this test is not assuming a conveniently shaped input.
        assertEquals("unknown", normalized?.support)

        assertEquals(
            "accepted_unverified",
            GenerationParameterSupportPresentation.effectiveSupport("accepted_unverified", normalized?.support),
        )
        assertEquals(
            R.string.generation_parameter_class_unverified,
            GenerationParameterSupportPresentation.entry(
                GenerationParameterSupportPresentation.effectiveSupport("accepted_unverified", "unknown"),
            ).labelRes,
        )
    }

    /** The decision table for `effectiveSupport`. */
    @Test
    fun `effective support lets evidence veto but never invent a positive verdict`() {
        // Authoritative evidence of explicit non-support is a hard boundary and always wins.
        assertEquals("unsupported", GenerationParameterSupportPresentation.effectiveSupport("supported", "unsupported"))
        assertEquals("fixed", GenerationParameterSupportPresentation.effectiveSupport("fixed", "unsupported"))
        // An explicit negative is asserted by the profile directly and keeps its precise explanation.
        assertEquals("fixed", GenerationParameterSupportPresentation.effectiveSupport("fixed", "unknown"))
        assertEquals(
            "mode_dependent",
            GenerationParameterSupportPresentation.effectiveSupport("mode_dependent", "unknown"),
        )
        // Measured support is support, and the normal state says nothing.
        assertEquals("supported", GenerationParameterSupportPresentation.effectiveSupport("accepted", "supported"))
        // When we do not know, a positive claim in the profile cannot be used as a verdict; it drops to 'will be sent, effect unverified'.
        assertEquals("accepted_unverified", GenerationParameterSupportPresentation.effectiveSupport("supported", "unknown"))
        assertEquals("accepted", GenerationParameterSupportPresentation.effectiveSupport("accepted", null))
        // The remaining engineering states are already honest, so they pass through unchanged; an unregistered literal is
        // handled in the most conservative way, as 'no information yet'.
        assertEquals("future_supported", GenerationParameterSupportPresentation.effectiveSupport("future_supported", "unknown"))
        assertEquals("unknown", GenerationParameterSupportPresentation.effectiveSupport(null, null))
        assertEquals("unknown", GenerationParameterSupportPresentation.effectiveSupport("brand_new_ninth_state", "  "))
        // An unregistered literal still has to be surfaced at test time by entryForRegistered returning null.
        assertNull(GenerationParameterSupportPresentation.entryForRegistered("brand_new_ninth_state"))
    }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("cannot find $relative")
    }
}
