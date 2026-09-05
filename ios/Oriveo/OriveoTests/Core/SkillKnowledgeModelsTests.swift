import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Oriveo

@Suite("Skill Knowledge Editing")
struct SkillKnowledgeModelsTests {

    @Test("saving skill edit preserves knowledgeBase manifest")
    func savingSkillEditPreservesKnowledgeBaseManifest() throws {
        let draft = SkillEditDraft(
            name: "Knowledge Skill",
            description: "desc",
            icon: "📚",
            color: "#4A90D9",
            systemPrompt: "Prompt",
            suggestedProviderId: "openai",
            suggestedModelId: "gpt-5.4",
            modelCapabilityHint: "any",
            starterMessages: ["", "Ask me anything"],
            knowledgeFiles: [
                SkillKnowledgeFile(name: "rules.md", content: "abc")
            ],
            knowledgeBase: SkillKnowledgeBase(
                provider: "openai",
                retrievalModel: "gpt-5.4-mini",
                vectorStoreId: "vs_123",
                expiresAfterDays: 90,
                files: [
                    SkillKnowledgeBaseFile(
                        id: "kb-1",
                        name: "manual.pdf",
                        mimeType: "application/pdf",
                        sizeBytes: 1024,
                        ingestionMode: .nativeFile,
                        extractedFrom: nil,
                        openAIFileId: "file_123",
                        status: .ready,
                        errorCode: nil,
                        createdAt: Date(timeIntervalSince1970: 1_712_705_600),
                        updatedAt: Date(timeIntervalSince1970: 1_712_705_600)
                    )
                ],
                updatedAt: Date(timeIntervalSince1970: 1_712_705_600)
            ),
            useMemory: true,
            temperature: 0.2,
            reasoningLevel: "medium",
            webSearchEnabled: true
        )

        let body = try SkillKnowledgeEditingSupport.buildSaveBody(from: draft)

        let starterMessages = try #require(body["starterMessages"] as? [String])
        #expect(starterMessages == ["Ask me anything"])

        let knowledgeBase = try #require(body["knowledgeBase"] as? [String: Any])
        #expect(knowledgeBase["retrievalModel"] as? String == "gpt-5.4-mini")
        #expect(knowledgeBase["vectorStoreId"] as? String == "vs_123")

        let knowledgeBaseFiles = try #require(knowledgeBase["files"] as? [[String: Any]])
        #expect(knowledgeBaseFiles.count == 1)
        #expect(knowledgeBaseFiles.first?["status"] as? String == "ready")
        #expect(knowledgeBaseFiles.first?["openAIFileId"] as? String == "file_123")

        let knowledgeFiles = try #require(body["knowledgeFiles"] as? [[String: Any]])
        #expect(knowledgeFiles.count == 1)
        #expect(knowledgeFiles.first?["charCount"] as? Int == 3)
    }

    @Test("knowledge file names are sanitized and keep extensions")
    func knowledgeFileNamesAreSanitizedAndKeepExtensions() {
        let sanitized = SkillKnowledgeEditingSupport.sanitizeFileName(
            "line1\n\t" + String(repeating: "a", count: 140) + ".txt"
        )

        #expect(!sanitized.contains("\n"))
        #expect(!sanitized.contains("\t"))
        #expect(sanitized.hasSuffix(".txt"))
        #expect(sanitized.count <= 120)
    }

    @Test("knowledge quota rejects too many files and oversized uploads")
    func knowledgeQuotaRejectsTooManyFilesAndOversizedUploads() {
        #expect(
            SkillKnowledgeEditingSupport.validateKnowledgeBaseQuota(
                existingCount: 5,
                existingBytes: 0,
                nextFileBytes: 10
            ) == .knowledgeTotalSizeExceeded
        )
        #expect(
            SkillKnowledgeEditingSupport.validateKnowledgeBaseQuota(
                existingCount: 0,
                existingBytes: 0,
                nextFileBytes: 21 * 1024 * 1024
            ) == .knowledgeFileTooLarge
        )
        #expect(
            SkillKnowledgeEditingSupport.validateKnowledgeBaseQuota(
                existingCount: 1,
                existingBytes: 95 * 1024 * 1024,
                nextFileBytes: 6 * 1024 * 1024
            ) == .knowledgeTotalSizeExceeded
        )
    }

    @Test("Importer Content Types Cover Reference And Knowledge Flows")
    func importerContentTypesCoverReferenceAndKnowledgeFlows() {
        let referenceTypes = SkillKnowledgeEditingSupport.referenceFileContentTypes
        #expect(referenceTypes.contains(where: { $0.identifier == UTType.content.identifier }))
        #expect(referenceTypes.contains(where: { $0.identifier == UTType.pdf.identifier }))
        #expect(referenceTypes.contains(where: { $0.identifier == UTType.plainText.identifier }))

        let knowledgeTypes = SkillKnowledgeEditingSupport.knowledgeFileContentTypes(
            supportedFileTypes: ["pdf", "txt", "xlsx"]
        )
        let xlsxType = try? #require(
            UTType(tag: "xlsx", tagClass: .filenameExtension, conformingTo: .data)
        )

        #expect(knowledgeTypes.contains(where: { $0.identifier == UTType.content.identifier }))
        #expect(knowledgeTypes.contains(where: { $0.identifier == UTType.pdf.identifier }))
        #expect(knowledgeTypes.contains(where: { $0.identifier == UTType.plainText.identifier }))
        #expect(knowledgeTypes.contains(where: { $0.identifier == xlsxType?.identifier }))
    }
}
