import Foundation
import Testing
@testable import Oriveo

/// Attachment delivery for tool-loop legs: the chat history is converted to provider-neutral loop messages
/// through the same delivery decision as plain chat.
struct ToolLoopAttachmentDeliveryTests {

    private func makeModel() -> AIModel {
        TestFactories.makeModel(id: "gpt-4.1", capabilities: [.text, .image, .file], isDefault: true)
    }

    @Test("tool loop: the OpenRouter leg sends allow-listed files as file parts, other providers' legs stay text")
    func openRouterLegCarriesNativeFileParts() throws {
        var model = makeModel()
        model.nativeFileMimes = ["application/pdf"]
        model.pdfNativeDefault = true
        let pdf = Attachment(
            id: UUID(), kind: .file, fileName: "report.pdf", mimeType: "application/pdf",
            base64Data: Data("extracted pdf text".utf8).base64EncodedString(),
            extractedSizeBytes: 5_000, originalBase64Data: "JVBERi0="
        )
        func message(_ kind: ProviderKind) -> ChatMessage {
            ChatMessage(
                id: UUID(), role: .user, text: "Question", providerKind: kind, providerName: "P",
                modelID: model.id, modelName: model.name, state: .delivered, attachments: [pdf]
            )
        }

        let openRouter = try #require(try OpenAIChatToolLoopLegRunner.messages(
            from: [message(.openRouter)], providerKind: .openRouter, model: model, isChatSend: true
        ).first)
        let parts = try #require(openRouter.contentParts)
        #expect(parts.map(\.type) == ["text", "file"])
        #expect(parts.first?.text == "Question")
        #expect(parts.last?.file == .init(filename: "report.pdf", fileData: "data:application/pdf;base64,JVBERi0="))
        // Wire shape: the leg's request body is encoded straight from the neutral messages.
        let wire = try #require(
            try OpenAIChatToolAdapter().encodeConversation([openRouter]).messages.first as? [String: Any]
        )
        let wireParts = try #require(wire["content"] as? [[String: Any]])
        #expect(wireParts.last?["type"] as? String == "file")
        #expect((wireParts.last?["file"] as? [String: String]) == [
            "filename": "report.pdf", "file_data": "data:application/pdf;base64,JVBERi0=",
        ])
        #expect(wireParts.first?["file"] == nil)

        let openAI = try #require(try OpenAIChatToolLoopLegRunner.messages(
            from: [message(.openAI)], providerKind: .openAI, model: model, isChatSend: true
        ).first)
        #expect(openAI.contentParts == nil)
        #expect(openAI.content?.contains("extracted pdf text") == true)
    }

    @Test("tool loop: files over the text limit in the message being sent block it, the same files in history do not")
    func outgoingTurnOverAttachmentTextLimitIsBlocked() throws {
        let model = makeModel()
        let files = ["a.txt", "b.txt", "c.txt", "d.txt"].map { name in
            Attachment(
                id: UUID(), kind: .file, fileName: name, mimeType: "text/plain",
                base64Data: Data("notes in \(name)".utf8).base64EncodedString()
            )
        }
        func message(_ role: ChatRole, attachments: [Oriveo.Attachment]? = nil) -> ChatMessage {
            ChatMessage(
                id: UUID(), role: role, text: "Question", providerKind: .openAI, providerName: "OpenAI",
                modelID: model.id, modelName: model.name, state: .delivered, attachments: attachments
            )
        }

        do {
            _ = try OpenAIChatToolLoopLegRunner.messages(
                from: [message(.user, attachments: files)], providerKind: .openAI, model: model, isChatSend: true
            )
            Issue.record("the current turn over the text limit was not blocked")
        } catch let error as ProviderServiceError {
            guard case let .attachmentTextOverLimit(fileNames, fileCountLimit) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            // The 4th file is over the count limit: no file is named, and the limit is given.
            #expect(fileNames.isEmpty)
            #expect(fileCountLimit == FileExtractionLimits.default.maxFiles)
        }

        let history = try OpenAIChatToolLoopLegRunner.messages(
            from: [message(.user, attachments: files), message(.assistant), message(.user)],
            providerKind: .openAI, model: model, isChatSend: true
        )
        let first = try #require(history.first?.content)
        #expect(first.components(separatedBy: "<ATTACHMENT_FILE>").count - 1 == 3)
        #expect(!first.contains("d.txt"))
    }
}
