package ai.oriveo.community.core.error

import androidx.test.core.app.ApplicationProvider
import ai.oriveo.community.R
import ai.oriveo.community.core.error.LocalRequestRejectionCopy.Code
import ai.oriveo.community.core.error.LocalRequestRejectionCopy.Text
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.provider.AdditionalRequestBody
import ai.oriveo.community.core.provider.ProviderRecipeExecution
import ai.oriveo.community.feature.chat.recovery.MessageRecoveryActionKind
import ai.oriveo.community.feature.chat.recovery.resolveMessageRecoveryCardActionLayout
import ai.oriveo.community.feature.chat.recovery.titleRes
import ai.oriveo.community.core.model.ChatMessageState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Safe code of a local rejection to error card copy: inputs are rejections the production validation really throws, never hand-built codes. */
@RunWith(RobolectricTestRunner::class)
class LocalRequestRejectionCopyTest {

    @Test
    fun `protected field rejected by the production validator maps to the field sentence`() {
        val error = additionalBodyRejection("""{"model":"x"}""")
        val code = LocalRequestRejectionCopy.parse(error.technicalDetail)
        assertEquals(Code(AdditionalRequestBody.OWNER, "protected_field", field = "model"), code)
        assertEquals(R.string.additional_body_check, LocalRequestRejectionCopy.title(code!!))
        assertEquals(
            Text(
                R.string.local_request_body_format,
                listOf(Text(R.string.additional_body_reason_protected_field, listOf("model")), Text(R.string.local_request_not_sent)),
            ),
            LocalRequestRejectionCopy.body(code),
        )
    }

    @Test
    fun `syntax error keeps the line from the production scanner and renders one sentence`() {
        val error = additionalBodyRejection("{\n  \"a\": 1,\n")
        val code = LocalRequestRejectionCopy.parse(error.technicalDetail)!!
        assertEquals("invalid_json", code.reason)
        assertEquals(error.line, code.line)
        assertTrue("scanner must report a line for truncated JSON", (code.line ?: 0) > 0)
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        assertEquals(
            "Line ${code.line}: The additional request body isn’t valid JSON. This message wasn’t sent.",
            LocalRequestRejectionCopy.render(LocalRequestRejectionCopy.body(code), context),
        )
    }

    @Test
    fun `every additional body reason has its own sentence`() {
        val cases = mapOf(
            "[1]" to R.string.additional_body_reason_not_object,
            "{" + "\"a\":{".repeat(40) + "}".repeat(41) to R.string.additional_body_reason_too_deep,
            """{"a":{"__proto__":1}}""" to R.string.additional_body_reason_blocked_segment,
            "{\"a\":\"" + "x".repeat(70_000) + "\"}" to R.string.additional_body_reason_too_large,
        )
        cases.forEach { (raw, res) ->
            val code = LocalRequestRejectionCopy.parse(additionalBodyRejection(raw).technicalDetail)!!
            val located = LocalRequestRejectionCopy.body(code).args.first() as Text
            assertEquals(raw.take(20), res, located.res)
        }
    }

    @Test
    fun `field names containing separators survive the round trip`() {
        val code = LocalRequestRejectionCopy.parse(additionalBodyRejection("""{"a:b@3":{"constructor":1}}""").technicalDetail)!!
        assertEquals("constructor", code.field)
        val detail = ProviderServiceError.LocalRequestRejected(AdditionalRequestBody.OWNER, "protected_field", fieldName = "x:y@7").technicalDetail
        assertEquals(Code(AdditionalRequestBody.OWNER, "protected_field", field = "x:y@7"), LocalRequestRejectionCopy.parse(detail))
    }

    @Test
    fun `web and thinking custom fields name the section and the line from the lossless parser`() {
        val truncated = ProviderRecipeExecution.compileSafeCustom("{\n  \"enable_search\": true,\n", "web", emptyMap())
        assertEquals("invalid_json", truncated.reason)
        assertEquals(3, truncated.line)
        val duplicate = ProviderRecipeExecution.compileSafeCustom("{\n  \"a\": 1,\n  \"a\": 2\n}", "reasoning", emptyMap())
        assertEquals("duplicate_json_key", duplicate.reason)
        assertEquals(3, duplicate.line)
        // A rejection that is not a syntax error has no definite line, so none is invented.
        val unknown = ProviderRecipeExecution.compileSafeCustom("""{"x":1}""", "web", emptyMap())
        assertEquals("unknown_path", unknown.reason)
        assertNull(unknown.line)

        val detail = ProviderServiceError.LocalRequestRejected("web", truncated.reason!!, line = truncated.line).technicalDetail
        val code = LocalRequestRejectionCopy.parse(detail)!!
        assertEquals(R.string.model_control_custom_request_fields, LocalRequestRejectionCopy.title(code))
        assertEquals(
            Text(
                R.string.local_request_body_format,
                listOf(
                    Text(R.string.local_request_custom_line_format, listOf(Text(R.string.model_control_web_search), 3, Text(R.string.model_control_custom_invalid_json))),
                    Text(R.string.local_request_not_sent),
                ),
            ),
            LocalRequestRejectionCopy.body(code),
        )
        val noLine = LocalRequestRejectionCopy.parse(
            ProviderServiceError.LocalRequestRejected("reasoning", "unknown_path").technicalDetail,
        )!!
        assertEquals(
            Text(R.string.local_request_custom_format, listOf(Text(R.string.model_control_thinking), Text(R.string.model_control_custom_conflicts_managed))),
            LocalRequestRejectionCopy.body(noLine).args.first(),
        )
    }

    @Test
    fun `error title and message are localized from the persisted safe code`() {
        val error = additionalBodyRejection("[1]")
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        assertEquals("Check the additional request body", ErrorMapper.localizeProviderErrorTitle(error.title, context))
        assertEquals(
            "Request with additional request body was rejected",
            ErrorMapper.localizeProviderErrorTitle(ai.oriveo.community.core.data.repository.ADDITIONAL_BODY_REJECTED_UPSTREAM_TITLE, context),
        )
        assertTrue(ErrorMapper.hasLocalizedProviderMessage(error.technicalDetail))
        assertEquals(
            "The additional request body must be a JSON object wrapped in { }. This message wasn’t sent.",
            ErrorMapper.localizeProviderErrorMessage(error.technicalDetail, context),
        )
        assertEquals(ErrorMapper.localizeProviderErrorMessage(error.technicalDetail, context), ErrorMapper.map(error, context).message)
        assertFalse(LocalRequestRejectionCopy.isCode("additional_body_rejected:"))
        assertNull(LocalRequestRejectionCopy.parse("custom_request_fields_rejected:web"))
    }

    @Test
    fun `retry offer for the additional body uses its own action label`() {
        val layout = resolveMessageRecoveryCardActionLayout(
            state = ChatMessageState.Failed,
            shouldOfferModelSwitch = false,
            customRetryWithoutFieldsAvailable = true,
            customRetryWithoutFieldsCode = "local_fields_retry_offer:${AdditionalRequestBody.OWNER}",
        )
        assertEquals(MessageRecoveryActionKind.RetryWithoutAdditionalBody, layout.primary)
        assertEquals(R.string.additional_body_retry_without, layout.primary.titleRes())
        val web = resolveMessageRecoveryCardActionLayout(
            state = ChatMessageState.Failed,
            shouldOfferModelSwitch = false,
            customRetryWithoutFieldsAvailable = true,
            customRetryWithoutFieldsCode = "local_fields_retry_offer:web",
        )
        assertEquals(MessageRecoveryActionKind.RetryWithoutLocalCustomFields, web.primary)
    }

    private fun additionalBodyRejection(raw: String): ProviderServiceError.LocalRequestRejected = try {
        AdditionalRequestBody.apply("{}", raw)
        fail("expected a local rejection for ${raw.take(40)}")
        error("unreachable")
    } catch (error: ProviderServiceError.LocalRequestRejected) {
        error
    }
}
