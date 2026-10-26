package ai.oriveo.community.core.capability

import ai.oriveo.community.R
import ai.oriveo.community.core.capability.truth.InputCapabilityProjections
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.provider.AttachmentInputGate
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade.InputCapabilityConnection
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade.InputCapabilityProjection
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade.InputCapabilityVerdict
import ai.oriveo.community.feature.chat.composer.ComposerAttachmentEntryModel
import ai.oriveo.community.feature.chat.recovery.MessageRecoveryActionKind
import ai.oriveo.community.feature.chat.recovery.resolveMessageRecoveryCardActionLayout
import ai.oriveo.community.feature.chat.recovery.titleRes
import java.io.File
import java.time.Instant
import java.util.zip.GZIPInputStream
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * Shared fixture `shared/test-fixtures/capability/rejection-recovery.v1.json`: the one-tap action after an official
 * input is rejected comes only from the result the failed message recorded itself ([InputRejectionFlow.recordOfficial] /
 * [InputRejectionFlow.recordOfficialParameter] -> [InputRejectionFlow.recoveryCode] -> failed-card layout) and
 * generalizes by capabilityKey; no match, or a negative-cache entry alone, offers no action.
 * Kill-switch reasons have three copies, one per media type. Each case is one `REJECTION_RECOVERY_<id>`.
 *
 * Signature table: the image case uses the real DashScope entry from the APK asset; the shared table has no file / video
 * entries yet, so one is built through the same parse entry. The verdict comes from the real qwen entry in the bundled snapshot.
 */
@RunWith(RobolectricTestRunner::class)
class RejectionRecoveryCapabilityContractTest {
    private val now: Instant = Instant.parse("2026-10-19T00:00:00Z")
    private val cache = InputNegativeCache(InputNegativeCache.MemoryStore()) { now.epochSecond }
    private val qwen = Provider(id = "official-qwen", kind = ProviderKind.Qwen)
    private val openAI = Provider(id = "official-openai", kind = ProviderKind.OpenAI)
    private val qwenPlus = AIModel(id = "qwen-plus", name = "qwen-plus")
    private val client: MetadataClient by lazy { qwenClient() }
    private val assetTable: RejectionSignatureTable by lazy {
        requireNotNull(RejectionSignatures.load(RuntimeEnvironment.getApplication())) { "the signature table asset should be packaged with the APK" }
    }

    private val fixture: JsonObject by lazy { readJson("shared/test-fixtures/capability/rejection-recovery.v1.json") }
    private val actionCases: Map<String, JsonObject> by lazy { casesOf("actionCases") }
    private val killSwitchCases: Map<String, JsonObject> by lazy { casesOf("killSwitchCopyCases") }

    @Test
    fun `fixture ids are exactly the REJECTION_RECOVERY tests`() {
        val tests = javaClass.declaredMethods.map { it.name }.filter { it.startsWith("REJECTION_RECOVERY_") }
            .map { it.removePrefix("REJECTION_RECOVERY_") }.toSet()
        assertEquals(actionCases.keys + killSwitchCases.keys, tests)
        assertEquals(actionCases.size + killSwitchCases.size, tests.size)
    }

    @Test fun REJECTION_RECOVERY_vision_rejected_resend_without_images() = assertActionCase("vision_rejected_resend_without_images")
    @Test fun REJECTION_RECOVERY_file_rejected_resend_without_files() = assertActionCase("file_rejected_resend_without_files")
    @Test fun REJECTION_RECOVERY_video_rejected_resend_without_videos() = assertActionCase("video_rejected_resend_without_videos")
    @Test fun REJECTION_RECOVERY_param_rejected_resend_without_param() = assertActionCase("param_rejected_resend_without_param")
    @Test fun REJECTION_RECOVERY_no_match_no_media_action() = assertActionCase("no_match_no_media_action")
    @Test fun REJECTION_RECOVERY_cached_state_alone_offers_nothing() = assertActionCase("cached_state_alone_offers_nothing")

    @Test fun REJECTION_RECOVERY_kill_switch_image() = assertKillSwitchCase("kill_switch_image")
    @Test fun REJECTION_RECOVERY_kill_switch_file() = assertKillSwitchCase("kill_switch_file")
    @Test fun REJECTION_RECOVERY_kill_switch_video() = assertKillSwitchCase("kill_switch_video")

    // ── action cases ──

    private fun assertActionCase(id: String) {
        val case = actionCases.getValue(id)
        assertEquals(id, "official", case.string("connection"))
        val match = case["match"]?.takeUnless { it is JsonNull }?.jsonObject
        val expect = case.getValue("expect").jsonObject
        val cachedBefore = case.bool("negativeCacheAlreadyHit") == true
        if (cachedBefore) {
            // An earlier rejection already left a negative-cache entry: this time no signature matches, so the failed card must not offer an action because of the cache state.
            cache.record(qwen.id, qwenPlus.id, "openai_chat.image_url", CapabilityEvidenceFacade.VISION_INPUT, "dashscope.unexpected_item_type", null)
        }
        val entriesBefore = cache.entries().size

        val code = when (match?.string("kind")) {
            "input_rejected" -> recordInput(id, match.getValue("capabilityKey").jsonPrimitive.content)
            "param_rejected" -> recordParameter(id, match.getValue("parameter").jsonPrimitive.content)
            null -> recordNoMatch(id)
            else -> error("unknown match kind in $id")
        }

        val layout = resolveMessageRecoveryCardActionLayout(
            state = ChatMessageState.Failed,
            shouldOfferModelSwitch = false,
            customRetryWithoutFieldsCode = code,
        )
        assertEquals(id, expect.string("action"), contractAction(layout.primary))
        val secondary = expect.string("secondaryAction")
        if (secondary != null) {
            // With a one-tap action there are exactly two buttons: the action first, then switch model (regardless of shouldOfferModelSwitch), and no edit-message button.
            assertEquals(id, "switch_model", secondary)
            assertEquals(
                id,
                listOf(layout.primary, MessageRecoveryActionKind.SwitchModel),
                listOfNotNull(layout.primary, layout.secondary, layout.tertiary),
            )
            // Even when the relay has a switchable key, no third button is added.
            val withSwitchKey = resolveMessageRecoveryCardActionLayout(
                state = ChatMessageState.Failed,
                shouldOfferModelSwitch = false,
                customRetryWithoutFieldsCode = code,
                offersSwitchKey = true,
            )
            assertEquals(
                id,
                listOf(layout.primary, MessageRecoveryActionKind.SwitchModel),
                listOfNotNull(withSwitchKey.primary, withSwitchKey.secondary, withSwitchKey.tertiary),
            )
        }
        if (expect.string("action") == null) {
            assertNull(id, code)
            assertEquals(id, MessageRecoveryActionKind.Retry, layout.primary)
        }
        val wroteCache = cache.entries().size > entriesBefore
        assertEquals(id, expect.bool("negativeCache"), wroteCache)
    }

    /** Official qwen sends that media, upstream rejects it by a narrow signature -> production records it -> the failed message gets its code. */
    private fun recordInput(id: String, capabilityKey: String): String? {
        val (model, attachment, table, error) = when (capabilityKey) {
            CapabilityEvidenceFacade.VISION_INPUT -> InputCase(
                qwenPlus,
                Attachment(id = "a1", kind = AttachmentKind.Image, fileName = "a.png", mimeType = "image/png", base64Data = PNG_BASE64),
                assetTable,
                upstream400("invalid_parameter_error", DASHSCOPE_REJECTION_BODY),
            )
            CapabilityEvidenceFacade.FILE_INPUT -> InputCase(
                qwenPlus.copy(nativeFileMimes = listOf("application/pdf"), pdfNativeDefault = true),
                Attachment(id = "f1", kind = AttachmentKind.File, fileName = "a.pdf", mimeType = "application/pdf", originalBase64Data = "JVBERi0xLjQ="),
                syntheticTable("test.native_file_rejected", "file input is not supported", capabilityKey),
                upstream400("invalid_request_error", """{"error":{"message":"file input is not supported"}}"""),
            )
            CapabilityEvidenceFacade.VIDEO_INPUT -> InputCase(
                qwenPlus,
                Attachment(id = "v1", kind = AttachmentKind.Video, fileName = "a.mp4", mimeType = "video/mp4", base64Data = "AAAA"),
                syntheticTable("test.video_rejected", "video input is not supported", capabilityKey),
                upstream400("invalid_request_error", """{"error":{"message":"video input is not supported"}}"""),
            )
            else -> error("unknown capabilityKey in $id")
        }
        val result = InputRejectionFlow.recordOfficial(
            provider = qwen,
            model = model,
            messages = listOf(userMessage(listOf(attachment))),
            error = error,
            outputStarted = false,
            table = table,
            negativeCache = cache,
            metadataClient = client,
        )
        assertNotNull(id, result)
        assertEquals(id, capabilityKey, result!!.capabilityKey)
        assertEquals(id, listOf(capabilityKey), cache.entries().map { it.first.capabilityKey })
        return InputRejectionFlow.recoveryCode(result, rejectedParameter = null)
    }

    private fun recordParameter(id: String, parameter: String): String? {
        val error = upstream400("invalid_request_error", """{"error":{"message":"Unsupported parameter: '$parameter'"}}""")
        val table = RejectionSignatures.parse(
            """{"byProtocol":{"openai_chat":[{"signatureId":"test.${parameter}_unsupported","httpStatus":400,""" +
                """"messagePattern":"Unsupported parameter: '$parameter'","kind":"param_rejected","parameter":"$parameter"}]}}""",
        )
        val input = InputRejectionFlow.recordOfficial(
            provider = openAI, model = AIModel(id = "gpt-test", name = "gpt-test"), messages = listOf(userMessage(null)),
            error = error, outputStarted = false, table = table, negativeCache = cache, metadataClient = client,
        )
        assertNull(id, input)
        val recorded = InputRejectionFlow.recordOfficialParameter(
            provider = openAI,
            model = AIModel(id = "gpt-test", name = "gpt-test"),
            error = error,
            outputStarted = false,
            dispatchTransport = "openai_chat",
            table = table,
            negativeCache = cache,
            metadataClient = client,
        )
        assertEquals(id, parameter, recorded)
        assertEquals(id, listOf("param:$parameter"), cache.entries().map { it.first.capabilityKey })
        val code = InputRejectionFlow.recoveryCode(input, recorded)
        assertEquals(id, R.string.retry_without_this_setting, resolveMessageRecoveryCardActionLayout(
            state = ChatMessageState.Failed,
            shouldOfferModelSwitch = false,
            customRetryWithoutFieldsCode = code,
        ).primary.titleRes())
        return code
    }

    /** An image was sent but the error is not in the signature table: both the input and the parameter records return null and the failed message gets no code. */
    private fun recordNoMatch(id: String): String? {
        val error = upstream400("invalid_request_error", """{"error":{"type":"invalid_request_error","message":"Invalid image."}}""")
        val image = Attachment(id = "a1", kind = AttachmentKind.Image, fileName = "a.png", mimeType = "image/png", base64Data = PNG_BASE64)
        val input = InputRejectionFlow.recordOfficial(
            provider = qwen, model = qwenPlus, messages = listOf(userMessage(listOf(image))),
            error = error, outputStarted = false, table = assetTable, negativeCache = cache, metadataClient = client,
        )
        val parameter = InputRejectionFlow.recordOfficialParameter(
            provider = qwen, model = qwenPlus, error = error, outputStarted = false, dispatchTransport = "openai_chat",
            table = assetTable, negativeCache = cache, metadataClient = client,
        )
        assertNull(id, input)
        assertNull(id, parameter)
        return InputRejectionFlow.recoveryCode(input, parameter)
    }

    private fun contractAction(kind: MessageRecoveryActionKind): String? = when (kind) {
        MessageRecoveryActionKind.ResendWithoutImage -> "resend_without_images"
        MessageRecoveryActionKind.ResendWithoutFile -> "resend_without_files"
        MessageRecoveryActionKind.ResendWithoutVideo -> "resend_without_videos"
        MessageRecoveryActionKind.ResendWithoutParameter -> "resend_without_parameter"
        else -> null
    }

    // ── kill switch copy ──

    private fun assertKillSwitchCase(id: String) {
        val case = killSwitchCases.getValue(id)
        val key = case.getValue("key").jsonPrimitive.content
        val copyId = case.getValue("expect").jsonObject.getValue("copyId").jsonPrimitive.content
        val killed = InputCapabilityProjection.project(
            verdict = InputCapabilityVerdict(state = "unavailable", reasonCode = "provider_kill_switch"),
            endImplements = true,
            override = null,
            negativeCacheHit = false,
            connection = InputCapabilityConnection.OFFICIAL,
        )
        val entry = ComposerAttachmentEntryModel.from(
            projections = InputCapabilityProjections(vision = killed, file = killed, video = killed),
            gate = AttachmentInputGate(),
        )
        val item = when (key) {
            CapabilityEvidenceFacade.VISION_INPUT -> entry.image
            CapabilityEvidenceFacade.FILE_INPUT -> entry.file
            CapabilityEvidenceFacade.VIDEO_INPUT -> entry.video
            else -> error("unknown key in $id")
        }
        // copyId `disabled.kill_switch.<media>` maps to this platform's string key `capability_input_disabled_kill_switch_<media>`.
        val expectedKey = "capability_input_" + copyId.replace('.', '_')
        assertEquals(id, expectedKey, item.disabledReasonKey)
        val expectedRes = when (copyId) {
            "disabled.kill_switch.image" -> R.string.capability_input_disabled_kill_switch_image
            "disabled.kill_switch.file" -> R.string.capability_input_disabled_kill_switch_file
            "disabled.kill_switch.video" -> R.string.capability_input_disabled_kill_switch_video
            else -> error("unknown copyId in $id")
        }
        assertEquals(id, expectedRes, item.disabledReasonRes)
        // One copy per media type; the image copy is not shared.
        assertEquals(id, 3, listOf(entry.image, entry.file, entry.video).mapNotNull { it.disabledReasonRes }.toSet().size)
    }

    // ── helpers ──

    private data class InputCase(
        val model: AIModel,
        val attachment: Attachment,
        val table: RejectionSignatureTable,
        val error: ProviderServiceError.Upstream,
    )

    private fun syntheticTable(signatureId: String, pattern: String, capabilityKey: String) = RejectionSignatures.parse(
        """{"byProtocol":{"openai_chat":[{"signatureId":"$signatureId","httpStatus":400,"messagePattern":"$pattern",""" +
            """"kind":"input_rejected","capabilityKey":"$capabilityKey"}]}}""",
    )

    private fun upstream400(detail: String, body: String) = ProviderServiceError.Upstream(400, detail).apply { rawBody = body }

    private fun userMessage(attachments: List<Attachment>?) = ChatMessage(
        id = "u1",
        role = ChatRole.User,
        text = "what is this",
        providerKind = ProviderKind.Qwen,
        providerName = "Qwen",
        modelName = "qwen-plus",
        state = ChatMessageState.Delivered,
        attachments = attachments,
    )

    private fun casesOf(key: String): Map<String, JsonObject> =
        fixture.getValue(key).jsonArray.associate { it.jsonObject.getValue("id").jsonPrimitive.content to it.jsonObject }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
    private fun JsonObject.bool(key: String): Boolean? = (this[key] as? JsonPrimitive)?.booleanOrNull

    /** Publishes the real qwen entry of the bundled snapshot to a separate client through the production decode / publish boundary. */
    private fun qwenClient(): MetadataClient {
        val providers = bundledPayload().getValue("providers").jsonObject
        val payload = buildJsonObject {
            put("version", 1)
            put("contractVersion", 1)
            put("providers", JsonObject(mapOf("qwen" to providers.getValue("qwen"))))
        }
        return MetadataClient().apply { loadNetworkPayloadForTesting(payload.toString(), "\"rejection-recovery\"") }
    }

    private fun bundledPayload(): JsonObject {
        val file = repoFile("shared/model-contracts/bundled-metadata.v2.json.gz")
        val text = GZIPInputStream(file.inputStream()).bufferedReader().use { it.readText() }
        return Json.parseToJsonElement(text).jsonObject
    }

    private fun readJson(path: String): JsonObject = Json.parseToJsonElement(repoFile(path).readText()).jsonObject

    private fun repoFile(path: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, path)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("$path not found")
    }

    private companion object {
        const val PNG_BASE64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        const val DASHSCOPE_REJECTION_BODY =
            """{"error":{"code":"invalid_parameter_error","message":"The provided messages input is invalid. The error info is [Unexpected item type in content]"}}"""
    }
}
