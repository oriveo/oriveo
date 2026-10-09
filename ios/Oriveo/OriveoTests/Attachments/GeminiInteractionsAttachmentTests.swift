import XCTest
@testable import Oriveo

/// Attachment delivery on the Gemini Interactions (`/v1/interactions`) route: the request format has no native file blocks,
/// files go through text injection, and a message being sent that does not fit is not sent with a body that is missing files.
final class GeminiInteractionsAttachmentTests: XCTestCase {

    private func recipe() throws -> MetadataClient.CapabilityRecipe {
        let raw = """
        {"id":"gemini.interactions.web.v1","providerKind":"gemini",
         "transport":{"protocol":"gemini_interactions","endpointClass":"interactions","requiredHeaders":[],"streaming":"optional"},
         "capability":"web","executionKind":"endpoint_route",
         "requestOps":[{"op":"append","pointer":"/tools/-","value":{"type":"google_search"}}],
         "route":{"protocol":"gemini_interactions","endpointClass":"interactions","path":"/v1/interactions","requestMapper":"gemini_interactions_v1"},
         "responseParserKind":"gemini_google_search_v1","continuationKind":"previous_id","controlRefs":[],
         "fallbackPolicy":"remove_auto_patch_once_pre_token","sourceRefs":["gemini.interactions"],"reviewedAt":"2026-08-11"}
        """
        return try JSONDecoder().decode(MetadataClient.CapabilityRecipe.self, from: Data(raw.utf8))
    }

    private func textFile(_ name: String, content: String) -> Attachment {
        Attachment(
            id: UUID(), kind: .file, fileName: name, mimeType: "text/plain",
            base64Data: Data(content.utf8).base64EncodedString(),
            extractedSizeBytes: content.utf8.count
        )
    }

    private func message(_ role: ChatRole, _ text: String, attachments: [Attachment]? = nil) -> ChatMessage {
        var message = ChatMessage(
            id: UUID(), role: role, text: text, providerKind: .gemini,
            providerName: "Gemini", modelName: "gemini-3-flash", state: .delivered
        )
        message.attachments = attachments
        return message
    }

    private func inputTexts(_ request: URLRequest) throws -> [String] {
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        return input.map { (($0["parts"] as? [[String: Any]])?.first?["text"] as? String) ?? "" }
    }

    func testFileAttachmentReachesTheRequestAsInjectedText() throws {
        let file = textFile("notes.txt", content: "interactions-file-body")
        let request = try GeminiService().buildInteractionsRequest(
            modelID: "gemini-3-flash",
            messages: [message(.user, "summarize", attachments: [file])],
            apiKey: "fixture-key", stream: false, recipe: try recipe()
        )
        let texts = try inputTexts(request)
        XCTAssertEqual(texts.count, 1)
        XCTAssertTrue(texts[0].hasPrefix("summarize"), texts[0])
        XCTAssertTrue(texts[0].contains("interactions-file-body"), texts[0])
        XCTAssertTrue(texts[0].contains("notes.txt"), texts[0])
        // Byte for byte identical to the delivery decision: xml wrapper, per Gemini's route declaration.
        XCTAssertEqual(
            texts[0],
            AttachmentDelivery.plan(
                userText: "summarize", attachments: [file],
                transport: AttachmentTransport.geminiInteractions.profile, model: nil
            ).injectedText
        )
        XCTAssertTrue(texts[0].contains("<FILE_NAME>notes.txt</FILE_NAME>"), texts[0])
    }

    private func model(extraction: AttachmentExtractionLimits? = nil) -> AIModel {
        AIModel(
            id: "gemini-3-flash", name: "gemini-3-flash",
            capabilities: [.text, .image, .file],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true,
            priceTier: "premium",
            attachmentExtraction: extraction,
            // Even with a native allow-list on the model nothing is routed natively: this route's builder never assembles native file blocks.
            nativeFileMimes: ["application/pdf", "text/plain"],
            pdfNativeDefault: true
        )
    }

    func testOutgoingTurnOverTextBudgetIsRejectedBeforeTheRequestIsBuilt() throws {
        let files = [textFile("a.txt", content: "aaaa"), textFile("b.txt", content: String(repeating: "b", count: 64))]
        let limits = AttachmentExtractionLimits(totalCap: 32)
        XCTAssertThrowsError(try GeminiService().buildInteractionsRequest(
            modelID: "gemini-3-flash",
            messages: [message(.user, "q", attachments: files)],
            apiKey: "fixture-key", stream: true, recipe: try recipe(),
            capabilityEvidenceModel: model(extraction: limits)
        )) { error in
            guard case let .attachmentTextOverLimit(fileNames, fileCountLimit)? = error as? ProviderServiceError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(fileNames, ["b.txt"])
            XCTAssertNil(fileCountLimit)
        }
    }

    func testOutgoingTurnOverFileCountReportsTheCountLimit() throws {
        let files = ["a.txt", "b.txt", "c.txt", "d.txt"].map { textFile($0, content: "x") }
        XCTAssertThrowsError(try GeminiService().buildInteractionsRequest(
            modelID: "gemini-3-flash",
            messages: [message(.user, "q", attachments: files)],
            apiKey: "fixture-key", stream: false, recipe: try recipe(),
            capabilityEvidenceModel: model()
        )) { error in
            guard case let .attachmentTextOverLimit(fileNames, fileCountLimit)? = error as? ProviderServiceError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(fileNames, [])
            XCTAssertEqual(fileCountLimit, FileExtractionLimits.default.maxFiles)
        }
    }

    func testHistoryTurnOverLimitDoesNotBlockAndNativeWhitelistIsIgnored() throws {
        let overLimit = ["a.txt", "b.txt", "c.txt", "d.txt"].map { textFile($0, content: "old") }
        let current = textFile("now.txt", content: "current-body")
        let request = try GeminiService().buildInteractionsRequest(
            modelID: "gemini-3-flash",
            messages: [
                message(.user, "earlier", attachments: overLimit),
                message(.assistant, "answer"),
                message(.user, "next", attachments: [current]),
            ],
            apiKey: "fixture-key", stream: false, recipe: try recipe(),
            capabilityEvidenceModel: model()
        )
        let texts = try inputTexts(request)
        XCTAssertEqual(texts.count, 3)
        XCTAssertEqual(texts[1], "answer")
        XCTAssertTrue(texts[2].contains("current-body"), texts[2])
    }

    func testContinuationSendsOnlyTheLastTurnWithItsFile() throws {
        let file = textFile("now.txt", content: "continued-body")
        let request = try GeminiService().buildInteractionsRequest(
            modelID: "gemini-3-flash",
            messages: [
                message(.user, "earlier"),
                message(.assistant, "answer"),
                message(.user, "next", attachments: [file]),
            ],
            apiKey: "fixture-key", stream: false, recipe: try recipe(),
            previousResponseID: "interaction-1",
            capabilityEvidenceModel: model()
        )
        let texts = try inputTexts(request)
        XCTAssertEqual(texts.count, 1)
        XCTAssertTrue(texts[0].hasPrefix("next"), texts[0])
        XCTAssertTrue(texts[0].contains("continued-body"), texts[0])
    }

    /// This route has a single text part per message: images stay out of the request, and a placeholder in the body tells the model an image was not delivered.
    func testImagesAreReplacedByAPlaceholderOnThisRoute() throws {
        let image = Attachment(
            id: UUID(), kind: .image, fileName: "photo.png", mimeType: "image/png", base64Data: "aGk="
        )
        let request = try GeminiService().buildInteractionsRequest(
            modelID: "gemini-3-flash",
            messages: [message(.user, "look", attachments: [image])],
            apiKey: "fixture-key", stream: false, recipe: try recipe(),
            capabilityEvidenceModel: model()
        )
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        let parts = try XCTUnwrap((body["input"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0]["text"] as? String, "look\n\n[Image omitted: this route sends text only]")
        XCTAssertFalse(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self).contains("aGk="))
    }
}
