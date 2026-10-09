import XCTest
@testable import Oriveo

/// Pins every route's declaration. The provider, image placeholder and wrapper format equal what each build point passed by hand before route descriptions existed;
/// native file upload is enabled per route afterwards (`NativeFileUploadSwitch`), and every enabled route is registered here.
final class AttachmentTransportTests: XCTestCase {

    /// The arguments each build point passed to `AttachmentDelivery.deliver` before route descriptions existed.
    private struct HandPassed {
        let provider: ProviderKind
        let nativeFiles: NativeFileMode
        let imagePlaceholderText: String?
        /// Whether the builder has a branch that consumes `delivery.native` to assemble native file blocks.
        let builderEmitsNativeParts: Bool
    }

    /// Exhaustive switch: adding a route without registering it here does not compile.
    private func handPassed(_ transport: AttachmentTransport) -> HandPassed {
        func row(
            _ provider: ProviderKind,
            native: NativeFileMode = .off,
            placeholder: String? = nil,
            emitsNative: Bool = false
        ) -> HandPassed {
            HandPassed(
                provider: provider,
                nativeFiles: native,
                imagePlaceholderText: placeholder,
                builderEmitsNativeParts: emitsNative
            )
        }
        switch transport {
        case .openAIChat, .relayOpenAIChat: return row(.openAI)
        // Previously this skipped the delivery decision and dropped files entirely; now it follows the OpenAI-compatible route's text injection declaration.
        case .relayLlamaCppNative: return row(.openAI, placeholder: textOnlyRouteImagePlaceholder)
        // The four direct routes have been verified against the real provider and go native by allow-list; subscription and Relay routes of the same protocol route the same way and fall back to text when the upstream rejects them.
        case .openAIResponses: return row(.openAI, native: .always, emitsNative: true)
        case .codexSubscription, .relayOpenAIResponses:
            return row(.openAI, native: .alwaysWithTextFallback, emitsNative: true)
        case .anthropicMessages: return row(.anthropic, native: .always, emitsNative: true)
        case .relayAnthropicMessages: return row(.anthropic, native: .alwaysWithTextFallback, emitsNative: true)
        case .geminiGenerateContent: return row(.gemini, native: .always, emitsNative: true)
        case .relayGeminiGenerateContent: return row(.gemini, native: .alwaysWithTextFallback, emitsNative: true)
        // Previously this skipped the delivery decision and dropped files entirely; now it only injects text, and the builder has no native file block branch.
        case .geminiInteractions: return row(.gemini, placeholder: textOnlyRouteImagePlaceholder)
        case .openRouterChat: return row(.openRouter, native: .always, emitsNative: true)
        case .grokChat, .grokResponses, .grokSubscription: return row(.grok)
        // Routes that send only a string content: images arrive as a placeholder instead of being dropped silently.
        case .miniMaxChat, .miniMaxAnthropicWeb: return row(.miniMax, placeholder: textOnlyRouteImagePlaceholder)
        case .deepSeekChat: return row(.deepseek, placeholder: "[Image omitted: unsupported by DeepSeek]")
        case .qwenChat: return row(.qwen)
        case .moonshotChat: return row(.moonshot)
        case .zhipuChat: return row(.zhipu)
        case .siliconFlowChat: return row(.siliconFlow)
        case .mistralChat: return row(.mistral)
        case .groqChat: return row(.groq)
        case .togetherChat: return row(.together)
        case .fireworksChat: return row(.fireworks)
        // The OpenRouter leg sends Chat Completions, so files are not downgraded to text just because tools are on.
        case .toolLoop(.openRouter): return row(.openRouter, native: .always, emitsNative: true)
        case .toolLoop(let provider): return row(provider)
        }
    }

    private static let allTransports: [AttachmentTransport] = [
        .openAIChat, .openAIResponses, .codexSubscription, .relayOpenAIChat, .relayOpenAIResponses,
        .relayLlamaCppNative,
        .anthropicMessages, .relayAnthropicMessages,
        .geminiGenerateContent, .relayGeminiGenerateContent, .geminiInteractions,
        .openRouterChat,
        .grokChat, .grokResponses, .grokSubscription,
        .miniMaxChat, .miniMaxAnthropicWeb,
        .deepSeekChat, .qwenChat, .moonshotChat, .zhipuChat, .siliconFlowChat,
        .mistralChat, .groqChat, .togetherChat, .fireworksChat,
    ] + ProviderKind.allCases.map(AttachmentTransport.toolLoop)

    func testEveryTransportDeclaresWhatItsBuildPointUsedToPassByHand() {
        XCTAssertEqual(Set(Self.allTransports).count, Self.allTransports.count)

        for transport in Self.allTransports {
            let profile = transport.profile
            let expected = handPassed(transport)

            XCTAssertEqual(profile.provider, expected.provider, "\(transport)")
            XCTAssertEqual(profile.effectiveNativeFiles, expected.nativeFiles, "\(transport)")
            XCTAssertEqual(profile.imagePlaceholderText, expected.imagePlaceholderText, "\(transport)")
            XCTAssertEqual(profile.supportsNativeFiles, expected.builderEmitsNativeParts, "\(transport)")
            // The wrapper format used to be derived from the provider.
            XCTAssertEqual(
                profile.wrapper,
                AttachmentWrapperVersion.resolve(provider: expected.provider),
                "\(transport)"
            )
        }
    }

    func testNativeFilesAreOnlyEnabledWhereTheBuilderCanEmitThem() {
        for transport in Self.allTransports {
            let profile = transport.profile
            if profile.nativeFiles != .off {
                XCTAssertTrue(profile.supportsNativeFiles, "\(transport)")
            }
        }
        XCTAssertEqual(
            Self.allTransports.filter { $0.profile.effectiveNativeFiles == .always },
            [.openAIResponses, .anthropicMessages, .geminiGenerateContent, .openRouterChat, .toolLoop(.openRouter)]
        )
        XCTAssertEqual(
            Self.allTransports.filter { $0.profile.effectiveNativeFiles == .alwaysWithTextFallback },
            [.codexSubscription, .relayOpenAIResponses, .relayAnthropicMessages, .relayGeminiGenerateContent]
        )
    }

    /// Each route's switch is its own line: the route declaration reads exactly its own constant.
    func testEachNativeCapableTransportReadsItsOwnSwitch() {
        let switches: [(AttachmentTransport, NativeFileMode)] = [
            (.openAIResponses, NativeFileUploadSwitch.openAIResponses),
            (.codexSubscription, NativeFileUploadSwitch.codexSubscription),
            (.relayOpenAIResponses, NativeFileUploadSwitch.relayOpenAIResponses),
            (.anthropicMessages, NativeFileUploadSwitch.anthropicMessages),
            (.relayAnthropicMessages, NativeFileUploadSwitch.relayAnthropicMessages),
            (.geminiGenerateContent, NativeFileUploadSwitch.geminiGenerateContent),
            (.relayGeminiGenerateContent, NativeFileUploadSwitch.relayGeminiGenerateContent),
            (.openRouterChat, NativeFileUploadSwitch.openRouterChat),
            (.toolLoop(.openRouter), NativeFileUploadSwitch.openRouterToolLoop),
        ]
        XCTAssertEqual(
            Set(switches.map(\.0)),
            Set(Self.allTransports.filter { $0.profile.supportsNativeFiles })
        )
        for (transport, mode) in switches {
            XCTAssertEqual(transport.profile.nativeFiles, mode, "\(transport)")
        }
        // Subscription and Relay routes not verified against the real provider: routed like direct ones, with a text fallback.
        XCTAssertEqual(NativeFileUploadSwitch.codexSubscription, .alwaysWithTextFallback)
        XCTAssertEqual(NativeFileUploadSwitch.relayOpenAIResponses, .alwaysWithTextFallback)
        XCTAssertEqual(NativeFileUploadSwitch.relayAnthropicMessages, .alwaysWithTextFallback)
        XCTAssertEqual(NativeFileUploadSwitch.relayGeminiGenerateContent, .alwaysWithTextFallback)
    }

    func testSupportedButDisabledTransportSendsNothingNatively() {
        let profile = AttachmentTransportProfile.forTesting(
            provider: .openAI, wrapper: .xmlV1, supportsNativeFiles: false, nativeFiles: .always
        )
        XCTAssertFalse(profile.sendsNativeFiles)
        XCTAssertEqual(profile.effectiveNativeFiles, .off)
        let disabled = AttachmentTransportProfile.forTesting(
            provider: .openAI, wrapper: .xmlV1, supportsNativeFiles: true, nativeFiles: .off
        )
        XCTAssertFalse(disabled.sendsNativeFiles)
    }

    /// Subscription and Relay routes route exactly like direct ones; during a text resend (or when the connection is known not to accept file blocks) the whole route goes as text.
    func testFallbackTransportsRouteLikeDirectOnesUntilTheyFallBack() throws {
        let docxMime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        let model = AIModel(
            id: "claude-sonnet", name: "claude-sonnet", capabilities: [.text, .image, .file],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "premium",
            nativeFileMimes: ["application/pdf", docxMime], pdfNativeDefault: true
        )
        func file(_ name: String, mime: String, text: String, errorCode: String? = nil) -> Attachment {
            Attachment(
                id: UUID(), kind: .file, fileName: name, mimeType: mime,
                base64Data: Data(text.utf8).base64EncodedString(),
                extractedSizeBytes: 5_000, extractionErrorCode: errorCode, originalBase64Data: "JVBERi0="
            )
        }
        let files = [
            file("text.pdf", mime: "application/pdf", text: "pdf body"),
            file("scan.pdf", mime: "application/pdf", text: "", errorCode: "scanned_pdf"),
            file("memo.docx", mime: docxMime, text: "docx body"),
        ]
        let direct = try AttachmentDelivery.deliver(
            isOutgoingTurn: true, userText: "Q", attachments: files, transport: .anthropicMessages, model: model
        )
        XCTAssertEqual(direct.native.map(\.fileName), ["text.pdf", "scan.pdf", "memo.docx"])

        for transport in [AttachmentTransport.relayAnthropicMessages, .relayOpenAIResponses, .relayGeminiGenerateContent, .codexSubscription] {
            let plan = try AttachmentDelivery.deliver(
                isOutgoingTurn: true, userText: "Q", attachments: files, transport: transport, model: model
            )
            XCTAssertEqual(plan.native.map(\.fileName), direct.native.map(\.fileName), "\(transport)")
            XCTAssertEqual(plan.injectedText, "Q", "\(transport)")

            let asText = try NativeFileFallback.$currentAttempt.withValue(.init(sendsTextOnly: true)) {
                try AttachmentDelivery.deliver(
                    isOutgoingTurn: true, userText: "Q", attachments: files, transport: transport, model: model
                )
            }
            XCTAssertTrue(asText.native.isEmpty, "\(transport)")
            XCTAssertTrue(asText.injectedText.contains("pdf body") && asText.injectedText.contains("docx body"), "\(transport)")
            XCTAssertTrue(asText.injectedText.contains("scanned_pdf"), "\(transport)")
        }
        // Direct routes are unaffected by the text resend state.
        let directDuringFallback = try NativeFileFallback.$currentAttempt.withValue(.init(sendsTextOnly: true)) {
            try AttachmentDelivery.deliver(
                isOutgoingTurn: true, userText: "Q", attachments: files, transport: .anthropicMessages, model: model
            )
        }
        XCTAssertEqual(directDuringFallback.native.count, 3)
    }
}
