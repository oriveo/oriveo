package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.attachments.AttachmentTransportProfile.AnthropicMessages
import ai.oriveo.community.core.attachments.AttachmentTransportProfile.ChatCompletions
import ai.oriveo.community.core.attachments.AttachmentTransportProfile.DeepSeekChat
import ai.oriveo.community.core.attachments.AttachmentTransportProfile.GeminiGenerateContent
import ai.oriveo.community.core.attachments.AttachmentTransportProfile.OpenAIResponses
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Each route's declaration matches what its injection point passes: allowNative / provider / wrapper.
 *
 * The expected values are written out per route rather than derived from the declaration under test;
 * the `when` in [expected] has no else, so a new route does not compile until its expectation is written here.
 */
class AttachmentTransportProfileTest {

    private data class Declared(
        val nativeFiles: NativeFileMode,
        val wrapper: AttachmentWrapperVersion,
        val routingProvider: ProviderKind,
    )

    private val markdownProviders = setOf(
        ProviderKind.DeepSeek, ProviderKind.Qwen, ProviderKind.Moonshot,
        ProviderKind.Zhipu, ProviderKind.MiniMax, ProviderKind.SiliconFlow,
    )

    private fun expected(profile: AttachmentTransportProfile): Declared = when (profile) {
        is ChatCompletions -> Declared(
            nativeFiles = NativeFileMode.Off,
            wrapper = if (profile.provider in markdownProviders) AttachmentWrapperVersion.MarkdownV1 else AttachmentWrapperVersion.XmlV1,
            routingProvider = profile.provider,
        )
        DeepSeekChat -> Declared(NativeFileMode.Off, AttachmentWrapperVersion.MarkdownV1, ProviderKind.DeepSeek)
        // Listed separately it has its own native switch; its wrapper format and routing owner match ChatCompletions(OpenRouter), where it used to sit.
        AttachmentTransportProfile.OpenRouterChat -> Declared(NativeFileMode.Always, AttachmentWrapperVersion.XmlV1, ProviderKind.OpenRouter)
        OpenAIResponses -> Declared(NativeFileMode.Always, AttachmentWrapperVersion.XmlV1, ProviderKind.OpenAI)
        AnthropicMessages -> Declared(NativeFileMode.Always, AttachmentWrapperVersion.XmlV1, ProviderKind.Anthropic)
        // The MiniMax web search route goes through the Anthropic-compatible endpoint, but the wrapper format follows MiniMax, and document blocks are unverified.
        AttachmentTransportProfile.MiniMaxAnthropicMessages ->
            Declared(NativeFileMode.Off, AttachmentWrapperVersion.MarkdownV1, ProviderKind.MiniMax)
        // Relay and subscription routes take one row each: routing is the same as direct, and a rejection by the upstream falls back to text.
        AttachmentTransportProfile.SubscriptionResponses ->
            Declared(NativeFileMode.AlwaysWithTextFallback, AttachmentWrapperVersion.XmlV1, ProviderKind.OpenAI)
        AttachmentTransportProfile.RelayOpenAIResponses ->
            Declared(NativeFileMode.AlwaysWithTextFallback, AttachmentWrapperVersion.XmlV1, ProviderKind.OpenAI)
        AttachmentTransportProfile.RelayAnthropicMessages ->
            Declared(NativeFileMode.AlwaysWithTextFallback, AttachmentWrapperVersion.XmlV1, ProviderKind.Anthropic)
        AttachmentTransportProfile.RelayGeminiGenerateContent ->
            Declared(NativeFileMode.AlwaysWithTextFallback, AttachmentWrapperVersion.XmlV1, ProviderKind.Gemini)
        GeminiGenerateContent -> Declared(NativeFileMode.Always, AttachmentWrapperVersion.XmlV1, ProviderKind.Gemini)
        // These two routes carry no native blocks: files are injected as text.
        AttachmentTransportProfile.GeminiInteractions -> Declared(NativeFileMode.Off, AttachmentWrapperVersion.XmlV1, ProviderKind.Gemini)
        AttachmentTransportProfile.LlamaCppNative -> Declared(NativeFileMode.Off, AttachmentWrapperVersion.XmlV1, ProviderKind.Relay)
        is AttachmentTransportProfile.TextOnly -> Declared(NativeFileMode.Off, profile.base.wrapper, profile.base.routingProvider)
    }

    private val allProfiles: List<AttachmentTransportProfile> =
        ProviderKind.entries.map { ChatCompletions(it) } + listOf(
            DeepSeekChat, OpenAIResponses, AnthropicMessages, GeminiGenerateContent,
            AttachmentTransportProfile.GeminiInteractions, AttachmentTransportProfile.LlamaCppNative,
            AttachmentTransportProfile.OpenRouterChat,
            AttachmentTransportProfile.SubscriptionResponses, AttachmentTransportProfile.RelayOpenAIResponses,
            AttachmentTransportProfile.RelayAnthropicMessages, AttachmentTransportProfile.RelayGeminiGenerateContent,
            AttachmentTransportProfile.MiniMaxAnthropicMessages,
        )

    @Test
    fun `every transport declares what its injection point used to pass by hand`() {
        for (profile in allProfiles) {
            assertEquals(
                profile.toString(),
                expected(profile),
                Declared(profile.nativeFiles, profile.wrapper, profile.routingProvider),
            )
        }
    }

    @Test
    fun `dropping native files keeps the wrapper and only changes lines that had file blocks`() {
        for (profile in allProfiles) {
            val textOnly = profile.withoutNativeFiles()
            assertEquals(profile.toString(), false, textOnly.allowsNativeFiles)
            assertEquals(profile.toString(), profile.wrapper, textOnly.wrapper)
            if (!profile.allowsNativeFiles) assertEquals(profile, textOnly)
        }
    }

    @Test
    fun `a transport without native file blocks can never have native enabled`() {
        for (profile in allProfiles) {
            if (!profile.hasNativeFileBlocks) assertEquals(profile.toString(), NativeFileMode.Off, profile.nativeFiles)
        }
    }
}
