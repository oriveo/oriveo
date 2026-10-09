import Foundation
import Testing
import UniformTypeIdentifiers
import ZIPFoundation
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

    @Test("reference files in password-protected docx/xlsx/pptx are reported as password-protected", arguments: ["docx", "xlsx", "PPTX"])
    func passwordProtectedOfficeReferenceFileIsReportedAsPasswordProtected(ext: String) throws {
        let data = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(repeating: 0, count: 2_048)
        let failure = try #require(
            SkillKnowledgeEditingSupport.referenceFileImportFailure(data: data, fileExtension: ext)
        )
        let message = failure.importFailureMessage(
            fileName: "secret.\(ext)",
            maxInputFileBytes: SkillKnowledgeEditingSupport.maxReferenceFileSize
        )
        #expect(message == String(format: L10n.tr("file_extraction_error_encrypted_pdf", table: .chat), "secret.\(ext)"))
    }

    @Test("a regular docx and non-OOXML reference files are not reported as password-protected")
    func regularReferenceFilesAreNotReportedAsPasswordProtected() throws {
        let archive = try Archive(accessMode: .create)
        let xml = Data("<w:document><w:body><w:p><w:r><w:t>hello docx</w:t></w:r></w:p></w:body></w:document>".utf8)
        try archive.addEntry(
            with: "word/document.xml",
            type: .file,
            uncompressedSize: Int64(xml.count),
            provider: { position, size in xml[Int(position)..<(Int(position) + size)] }
        )
        let docx = try #require(archive.data)
        #expect(SkillKnowledgeEditingSupport.referenceFileImportFailure(data: docx, fileExtension: "docx") == nil)
        #expect(try OfficeTextExtractor.extractText(from: docx, fileExtension: "docx")?.contains("hello docx") == true)

        // The OLE header only matters for OOXML extensions; other types take their own branches as usual.
        let ole = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(repeating: 0, count: 2_048)
        #expect(SkillKnowledgeEditingSupport.referenceFileImportFailure(data: ole, fileExtension: "txt") == nil)
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
