import XCTest
@testable import Oriveo

final class AttachmentDeliveryTests: XCTestCase {

    private static let docxMime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

    private func textFile(_ name: String, content: String = "hello") -> Attachment {
        Attachment(
            id: UUID(),
            kind: .file,
            fileName: name,
            mimeType: "text/plain",
            base64Data: Data(content.utf8).base64EncodedString(),
            extractedSizeBytes: content.utf8.count
        )
    }

    private func docx(_ name: String, content: String = "docx text") -> Attachment {
        Attachment(
            id: UUID(),
            kind: .file,
            fileName: name,
            mimeType: Self.docxMime,
            base64Data: Data(content.utf8).base64EncodedString(),
            extractedSizeBytes: 5_000,
            originalBase64Data: "ZmFrZQ=="
        )
    }

    private func model(
        nativeFileMimes: [String] = [],
        extraction: AttachmentExtractionLimits? = nil
    ) -> AIModel {
        AIModel(
            id: "gpt-5",
            name: "gpt-5",
            capabilities: [.text, .image, .file],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: true,
            priceTier: "premium",
            attachmentExtraction: extraction,
            nativeFileMimes: nativeFileMimes
        )
    }

    private func profile(
        _ provider: ProviderKind,
        native: Bool = false,
        imagePlaceholderText: String? = nil
    ) -> AttachmentTransportProfile {
        .forTesting(
            provider: provider,
            wrapper: AttachmentWrapperVersion.resolve(provider: provider),
            supportsNativeFiles: native,
            nativeFiles: native ? .always : .off,
            imagePlaceholderText: imagePlaceholderText
        )
    }

    func testPlanSplitsNativeTextAndSkipped() {
        let native = docx("native.docx")
        let files = [textFile("a.txt"), native, textFile("b.txt"), textFile("c.txt"), textFile("d.txt")]

        let plan = AttachmentDelivery.plan(
            userText: "question",
            attachments: files,
            transport: profile(.openAI, native: true),
            model: model(nativeFileMimes: [Self.docxMime])
        )

        XCTAssertEqual(plan.native.map(\.fileName), ["native.docx"])
        XCTAssertEqual(plan.textPayload.map(\.fileName), ["a.txt", "b.txt", "c.txt", "d.txt"])
        XCTAssertEqual(plan.skipped.map(\.attachment.fileName), ["d.txt"])
        XCTAssertEqual(plan.skipped.first?.reason, .tooManyFiles)
        XCTAssertEqual(plan.skipped.first?.attachment.id, files[4].id)
        XCTAssertTrue(plan.injectedText.hasPrefix("question"))
        XCTAssertTrue(plan.injectedText.contains("<FILE_NAME>c.txt</FILE_NAME>"))
        XCTAssertFalse(plan.injectedText.contains("d.txt"))
        XCTAssertFalse(plan.injectedText.contains("native.docx"))
    }

    func testNativeDisabledSendsEverythingAsTextEvenWhenModelDeclaresNativeMimes() {
        let files = [docx("report.docx"), textFile("a.txt")]

        let plan = AttachmentDelivery.plan(
            userText: "",
            attachments: files,
            transport: profile(.openAI),
            model: model(nativeFileMimes: [Self.docxMime])
        )

        XCTAssertTrue(plan.native.isEmpty)
        XCTAssertEqual(plan.textPayload.map(\.fileName), ["report.docx", "a.txt"])
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertTrue(plan.injectedText.contains("<FILE_NAME>report.docx</FILE_NAME>"))
        XCTAssertTrue(plan.injectedText.contains("docx text"))
    }

    func testNilModelSendsEverythingAsTextWithDefaultLimits() {
        let plan = AttachmentDelivery.plan(
            userText: "",
            attachments: [docx("report.docx")],
            transport: profile(.openAI, native: true),
            model: nil
        )

        XCTAssertTrue(plan.native.isEmpty)
        XCTAssertTrue(plan.injectedText.contains("<FILE_NAME>report.docx</FILE_NAME>"))
    }

    func testModelLimitsDriveSkippedAndSameNamedFilesMapBackByPosition() {
        let files = [textFile("same.txt", content: "one"), textFile("same.txt", content: "two")]

        let plan = AttachmentDelivery.plan(
            userText: "",
            attachments: files,
            transport: profile(.deepseek),
            model: model(extraction: AttachmentExtractionLimits(maxAttachments: 1))
        )

        XCTAssertEqual(plan.skipped.map(\.attachment.id), [files[1].id])
        XCTAssertTrue(plan.injectedText.contains("one"))
        XCTAssertFalse(plan.injectedText.contains("two"))
    }

    func testInjectedTextMatchesInjectAllByteForByte() {
        let image = Attachment(id: UUID(), kind: .image, fileName: "p.png", mimeType: "image/png", base64Data: nil)
        let failed = Attachment(
            id: UUID(),
            kind: .file,
            fileName: "scan.pdf",
            mimeType: "application/pdf",
            base64Data: nil,
            extractedSizeBytes: 12_345,
            extractionErrorCode: ExtractionErrorCode.scannedPdf.rawValue
        )
        let big = textFile("big.txt", content: String(repeating: "x", count: 150_000))
        let big2 = textFile("big2.txt", content: String(repeating: "y", count: 150_000))
        let small = textFile("small.md", content: "line1\nline2")
        let attachments = [image, failed, big, big2, small]

        for provider in [ProviderKind.openAI, .deepseek] {
            let plan = AttachmentDelivery.plan(
                userText: "question",
                attachments: attachments,
                transport: profile(provider, imagePlaceholderText: "[image]"),
                model: nil
            )

            let expected = AttachmentInjector.injectAll(
                intoUserText: "question\n\n[image]",
                fileAttachments: [
                    ("scan.pdf", "application/pdf", 12_345, nil, .scannedPdf),
                    ("big.txt", "text/plain", 150_000,
                     ExtractedText(content: String(repeating: "x", count: 150_000), totalLines: 1, truncated: false, truncationReason: nil, sizeBytes: 150_000), nil),
                    ("big2.txt", "text/plain", 150_000,
                     ExtractedText(content: String(repeating: "y", count: 150_000), totalLines: 1, truncated: false, truncationReason: nil, sizeBytes: 150_000), nil),
                    ("small.md", "text/plain", 11,
                     ExtractedText(content: "line1\nline2", totalLines: 2, truncated: false, truncationReason: nil, sizeBytes: 11), nil),
                ],
                limits: .default,
                wrapper: AttachmentWrapperVersion.resolve(provider: provider)
            )

            XCTAssertEqual(plan.injectedText, expected.text)
            XCTAssertEqual(plan.skipped.map(\.attachment.fileName), expected.skipped.map(\.fileName))
            XCTAssertEqual(plan.skipped.map(\.attachment.fileName), ["big2.txt"])
            XCTAssertEqual(plan.skipped.first?.reason, .totalCapExceeded)
        }
    }

    // MARK: - Blocking: the message being sent has files that cannot go into the request

    func testDeliverBlocksOnlyTheOutgoingTurn() throws {
        let files = ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"].map { textFile($0) }

        XCTAssertThrowsError(try AttachmentDelivery.deliver(
            isOutgoingTurn: true, userText: "q", attachments: files,
            transport: .openAIChat, model: model()
        )) { error in
            guard case let .attachmentTextOverLimit(fileNames, fileCountLimit)? = error as? ProviderServiceError else {
                return XCTFail("unexpected error: \(error)")
            }
            // Only the count is over: no file is named.
            XCTAssertEqual(fileNames, [])
            XCTAssertEqual(fileCountLimit, FileExtractionLimits.default.maxFiles)
        }

        let history = try AttachmentDelivery.deliver(
            isOutgoingTurn: false, userText: "q", attachments: files,
            transport: .openAIChat, model: model()
        )
        XCTAssertEqual(history.skipped.map(\.attachment.fileName), ["d.txt", "e.txt"])
        XCTAssertEqual(
            history.injectedText,
            AttachmentDelivery.plan(
                userText: "q", attachments: files, transport: AttachmentTransport.openAIChat.profile, model: model()
            ).injectedText
        )

        let withinLimit = try AttachmentDelivery.deliver(
            isOutgoingTurn: true, userText: "q", attachments: Array(files.prefix(3)),
            transport: .openAIChat, model: model()
        )
        XCTAssertTrue(withinLimit.skipped.isEmpty)
    }

    func testOutgoingTurnIsTheLastUserMessageOfAChatSend() {
        func message(_ role: ChatRole) -> ChatMessage {
            ChatMessage(id: UUID(), role: role, text: "t", providerKind: .openAI, providerName: "OpenAI",
                        modelID: "gpt-5", modelName: "gpt-5", state: .delivered)
        }
        let messages = [message(.user), message(.assistant), message(.user), message(.assistant)]

        XCTAssertEqual(AttachmentDelivery.outgoingTurnIndex(in: messages, isChatSend: true), 2)
        XCTAssertNil(AttachmentDelivery.outgoingTurnIndex(in: messages, isChatSend: false))
        XCTAssertEqual(
            AttachmentDelivery.mapTurns(messages, isChatSend: true) { _, isOutgoing in isOutgoing },
            [false, false, true, false]
        )
    }

    func testOverLimitErrorIsALocalRejectionNotAConnectionFailure() {
        let error = ProviderServiceError.attachmentTextOverLimit(fileNames: ["report.pdf", "notes.txt"])

        XCTAssertFalse(error.marksConnectionFailed)
        XCTAssertEqual(error.diagnosticCode, "attachment_text_over_limit")
        XCTAssertEqual(error.titleKey, "Attachment Not Accepted")
        XCTAssertEqual(error.messageKey, "file_extraction_send_blocked_text_budget")
        // File names are user content: they appear only in the immediately displayed message, never in the persisted detail.
        XCTAssertEqual(error.technicalDetail, "attachment_text_over_limit")
        XCTAssertEqual(ChatFailurePresentation.persistedDetail(for: error), "attachment_text_over_limit")
        XCTAssertTrue(error.message.contains("report.pdf, notes.txt"), error.message)
        XCTAssertFalse(error.message.contains("%@"))
        XCTAssertNotEqual(error.message, error.messageKey)
    }

    /// Both reasons read their message from the error `deliver` actually throws: a count overflow says "at most N", and a text-total overflow names the files.
    func testFileCountOverLimitUsesTheCountCopyAndTextBudgetKeepsItsOwn() throws {
        func thrown(_ files: [Attachment], model: AIModel?) -> ProviderServiceError? {
            do {
                _ = try AttachmentDelivery.deliver(
                    isOutgoingTurn: true, userText: "q", attachments: files, transport: .openAIChat, model: model
                )
                return nil
            } catch {
                return error as? ProviderServiceError
            }
        }

        let overCount = try XCTUnwrap(thrown(
            ["a.txt", "b.txt", "c.txt"].map { textFile($0) },
            model: model(extraction: AttachmentExtractionLimits(maxAttachments: 2))
        ))
        XCTAssertEqual(overCount.messageKey, "file_attachment_count_limit_reached")
        XCTAssertEqual(
            overCount.message,
            String(format: L10n.tr("file_attachment_count_limit_reached", table: .chat), 2)
        )
        XCTAssertTrue(overCount.message.contains("2"), overCount.message)
        XCTAssertNotEqual(overCount.message, overCount.messageKey)
        XCTAssertFalse(overCount.message.contains("%"), overCount.message)
        XCTAssertFalse(overCount.message.contains("c.txt"), overCount.message)
        // A count overflow has its own stable code.
        XCTAssertEqual(overCount.diagnosticCode, "attachment_count_over_limit")
        XCTAssertEqual(overCount.technicalDetail, "attachment_count_over_limit")
        XCTAssertEqual(ChatFailurePresentation.persistedDetail(for: overCount), "attachment_count_over_limit")
        XCTAssertEqual(overCount.titleKey, "Attachment Not Accepted")

        let overText = try XCTUnwrap(thrown(
            [textFile("big.txt", content: String(repeating: "x", count: 150_000)),
             textFile("big2.txt", content: String(repeating: "y", count: 150_000))],
            model: nil
        ))
        guard case let .attachmentTextOverLimit(fileNames, fileCountLimit) = overText else {
            return XCTFail("unexpected error: \(overText)")
        }
        XCTAssertEqual(fileNames, ["big2.txt"])
        XCTAssertNil(fileCountLimit)
        XCTAssertEqual(overText.messageKey, "file_extraction_send_blocked_text_budget")
        XCTAssertTrue(overText.message.contains("big2.txt"), overText.message)
        XCTAssertEqual(overText.technicalDetail, "attachment_text_over_limit")
    }

    /// Count and text total both over: both lines appear, and the text line names only the files that do not fit the total.
    func testMixedOverLimitSaysBothAndNamesOnlyTheTextBudgetFiles() throws {
        let files = [
            textFile("a.txt", content: String(repeating: "x", count: 150_000)),
            textFile("big.txt", content: String(repeating: "y", count: 150_000)),
            textFile("c.txt"),
            textFile("d.txt"),
            textFile("extra.txt"),
        ]
        var thrown: ProviderServiceError?
        XCTAssertThrowsError(try AttachmentDelivery.deliver(
            isOutgoingTurn: true, userText: "q", attachments: files, transport: .openAIChat, model: model()
        )) { thrown = $0 as? ProviderServiceError }
        let error = try XCTUnwrap(thrown)
        guard case let .attachmentTextOverLimit(fileNames, fileCountLimit) = error else {
            return XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(fileNames, ["big.txt"])
        XCTAssertEqual(fileCountLimit, 3)
        XCTAssertEqual(error.message, [
            String(format: L10n.tr("file_attachment_count_limit_reached", table: .chat), 3),
            String(format: L10n.tr("file_extraction_send_blocked_text_budget", table: .chat), "big.txt"),
        ].joined(separator: "\n"))
        XCTAssertFalse(error.message.contains("extra.txt"), error.message)
        XCTAssertEqual(error.technicalDetail, "attachment_text_over_limit")
        XCTAssertEqual(error.messageKey, "file_extraction_send_blocked_text_budget")
    }

    func testOverLimitFailureCardOffersEditThenRetryThenSwitchModel() {
        XCTAssertEqual(
            resolveMessageRecoveryCardActionLayout(
                for: .failed, shouldOfferModelSwitch: true, isAttachmentOverLimit: true
            ),
            .init(primary: .editMessage, secondary: .retry, tertiary: .switchModel)
        )
        XCTAssertEqual(
            resolveMessageRecoveryCardActionLayout(
                for: .failed, shouldOfferModelSwitch: false, isAttachmentOverLimit: true
            ),
            .init(primary: .editMessage, secondary: .retry, tertiary: nil)
        )
        // Any other failure keeps the default layout.
        XCTAssertEqual(
            resolveMessageRecoveryCardActionLayout(for: .failed, shouldOfferModelSwitch: true),
            .init(primary: .retry, secondary: .editMessage, tertiary: .switchModel)
        )
        // Both stable codes identify the over-limit failure.
        XCTAssertEqual(
            ProviderServiceError.attachmentOverLimitCodes,
            ["attachment_text_over_limit", "attachment_count_over_limit"]
        )
    }

    func testCopyIsRegisteredInTheChatTableForAllLocales() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Oriveo")
        func strings(_ table: String) throws -> [String: Any] {
            let catalog = try JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appendingPathComponent("\(table).xcstrings"))
            ) as? [String: Any]
            return try XCTUnwrap(catalog?["strings"] as? [String: Any])
        }
        let chat = try strings("Chat")

        XCTAssertNotNil(chat["Attachment Not Accepted"] as? NSDictionary)

        let body = try XCTUnwrap(chat["file_extraction_send_blocked_text_budget"] as? [String: Any])
        let localizations = try XCTUnwrap(body["localizations"] as? [String: Any])
        XCTAssertEqual(localizations.count, 16)
        for (locale, entry) in localizations {
            let unit = (entry as? [String: Any])?["stringUnit"] as? [String: Any]
            let value = try XCTUnwrap(unit?["value"] as? String, locale)
            XCTAssertEqual(value.components(separatedBy: "%@").count - 1, 1, "\(locale) should have exactly one file name placeholder")
            XCTAssertFalse(value.contains("{fileName}"), locale)
        }
    }
}
