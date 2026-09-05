import Testing
import Foundation
@testable import Oriveo

@Suite("Skill Models")
struct SkillModelsTests {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Skill Codable

    @Test("Skill Full Roundtrip")
    func skillFullRoundtrip() throws {
        let original = Skill(
            id: UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!,
            name: "Code Review",
            description: "Expert code reviewer",
            icon: "💻",
            color: "#4A90D9",
            systemPrompt: "You are an expert code reviewer.",
            suggestedProviderId: "anthropic",
            suggestedModelId: "claude-sonnet-4-6",
            modelCapabilityHint: "reasoning",
            temperature: 0.7,
            starterMessages: ["Review this code", "Find bugs"],
            knowledgeFiles: [
                SkillKnowledgeFile(
                    name: "rules.md",
                    mimeType: "text/markdown",
                    sourceType: .text,
                    content: "# Rules\n- Be thorough",
                    createdAt: Date(timeIntervalSince1970: 1_712_705_600),
                    updatedAt: Date(timeIntervalSince1970: 1_712_705_600)
                )
            ],
            knowledgeBase: SkillKnowledgeBase(
                provider: "openai",
                retrievalModel: "gpt-5.4-mini",
                vectorStoreId: "vs_123",
                expiresAfterDays: 90,
                files: [
                    SkillKnowledgeBaseFile(
                        id: "kb-file-1",
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
            useMemory: false,
            isPinned: true,
            pinOrder: 1,
            source: .builtin,
            category: "coding",
            sortOrder: 10,
            usageCount: 42
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(Skill.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.name == "Code Review")
        #expect(decoded.description == "Expert code reviewer")
        #expect(decoded.icon == "💻")
        #expect(decoded.color == "#4A90D9")
        #expect(decoded.systemPrompt == "You are an expert code reviewer.")
        #expect(decoded.suggestedProviderId == "anthropic")
        #expect(decoded.suggestedModelId == "claude-sonnet-4-6")
        #expect(decoded.modelCapabilityHint == "reasoning")
        #expect(decoded.temperature == 0.7)
        #expect(decoded.starterMessages == ["Review this code", "Find bugs"])
        #expect(decoded.knowledgeFiles.count == 1)
        #expect(decoded.knowledgeFiles[0].name == "rules.md")
        #expect(decoded.knowledgeFiles[0].mimeType == "text/markdown")
        #expect(decoded.knowledgeFiles[0].sourceType == .text)
        #expect(decoded.knowledgeBase?.provider == "openai")
        #expect(decoded.knowledgeBase?.files.first?.status == .ready)
        #expect(decoded.useMemory == false)
        #expect(decoded.isPinned == true)
        #expect(decoded.pinOrder == 1)
        #expect(decoded.source == .builtin)
        #expect(decoded.category == "coding")
        #expect(decoded.sortOrder == 10)
        #expect(decoded.usageCount == 42)
        #expect(decoded.isBuiltIn == true)
        #expect(decoded.isEditable == false)
    }

    @Test("Skill Backward Compatibility")
    func skillBackwardCompatibility() throws {
        let minimalJSON = """
        {
            "id": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
            "name": "Translator",
            "systemPrompt": "Translate text.",
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!

        let decoded = try decoder.decode(Skill.self, from: minimalJSON)

        #expect(decoded.name == "Translator")
        #expect(decoded.description == "")
        #expect(decoded.icon == "🤖")
        #expect(decoded.color == "#6d38ff")
        #expect(decoded.modelCapabilityHint == "any")
        #expect(decoded.starterMessages.isEmpty)
        #expect(decoded.knowledgeFiles.isEmpty)
        #expect(decoded.useMemory == true)
        #expect(decoded.isPinned == false)
        #expect(decoded.source == .user)
        #expect(decoded.suggestedProviderId == nil)
        #expect(decoded.temperature == nil)
    }

    @Test("Skill Knowledge Compatibility")
    func skillKnowledgeCompatibility() throws {
        let json = """
        {
            "id": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
            "name": "Knowledge",
            "systemPrompt": "Prompt",
            "knowledgeFiles": [
                {
                    "id": "B1B2C3D4-E5F6-7890-ABCD-EF1234567890",
                    "name": "rules.md",
                    "content": "abc"
                }
            ],
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!

        let decoded = try decoder.decode(Skill.self, from: json)

        #expect(decoded.knowledgeBase == nil)
        #expect(decoded.knowledgeFiles.first?.mimeType == "text/plain")
        #expect(decoded.knowledgeFiles.first?.sourceType == .text)
        #expect(decoded.knowledgeFiles.first?.charCount == 3)
    }

    @Test("Skill String UUIDDecoding")
    func skillStringUUIDDecoding() throws {
        let json = """
        {
            "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
            "name": "Test",
            "systemPrompt": "prompt",
            "forkedFromId": "b1b2c3d4-e5f6-7890-abcd-ef1234567890",
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!

        let decoded = try decoder.decode(Skill.self, from: json)
        #expect(decoded.id == UUID(uuidString: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"))
        #expect(decoded.forkedFromId == UUID(uuidString: "b1b2c3d4-e5f6-7890-abcd-ef1234567890"))
    }

    @Test("Skill Computed Properties")
    func skillComputedProperties() {
        let builtIn = Skill(name: "Built-in", source: .builtin)
        #expect(builtIn.isBuiltIn == true)
        #expect(builtIn.isEditable == false)

        let userSkill = Skill(name: "User", source: .user)
        #expect(userSkill.isBuiltIn == false)
        #expect(userSkill.isEditable == true)

        let community = Skill(name: "Community", source: .community)
        #expect(community.isBuiltIn == false)
        #expect(community.isEditable == false)
    }

    @Test("Home Skills Default Curated Order")
    func homeSkillsDefaultCuratedOrder() {
        let catalog = [
            Skill(key: "code_assistant", name: "Code Assistant", source: .builtin),
            Skill(key: "translation_expert", name: "Translation Expert", source: .builtin),
            Skill(key: "writing_coach", name: "Writing Coach", source: .builtin),
            Skill(key: "email_assistant", name: "Email Assistant", source: .builtin),
            Skill(key: "brainstorm", name: "Brainstorm", source: .builtin),
            Skill(key: "document_summarizer", name: "Document Summarizer", source: .builtin),
        ]

        let selected = selectHomeSkills(catalogSkills: catalog, userSkills: [])

        #expect(selected.prefix(5).map { $0.key } == [
            "translation_expert",
            "writing_coach",
            "email_assistant",
            "brainstorm",
            "document_summarizer",
        ])
    }

    @Test("Home Skills Pinned And Recent Priority")
    func homeSkillsPinnedAndRecentPriority() {
        let catalog = [
            Skill(key: "translation_expert", name: "Translation Expert", source: .builtin),
            Skill(key: "writing_coach", name: "Writing Coach", source: .builtin),
            Skill(key: "email_assistant", name: "Email Assistant", source: .builtin),
            Skill(key: "brainstorm", name: "Brainstorm", source: .builtin),
            Skill(key: "document_summarizer", name: "Document Summarizer", source: .builtin),
        ]
        let user = [
            Skill(name: "Pinned", isPinned: true, pinOrder: 1, source: .user),
            Skill(name: "Recent", source: .user, lastUsedAt: Date()),
            Skill(name: "Unused", source: .user),
        ]

        let selected = selectHomeSkills(catalogSkills: catalog, userSkills: user)

        #expect(selected.prefix(2).map { $0.name } == ["Pinned", "Recent"])
        #expect(selected.contains(where: { $0.name == "Unused" }) == false)
    }

    // MARK: - SkillKnowledgeFile

    @Test("Knowledge File Char Count")
    func knowledgeFileCharCount() {
        let file = SkillKnowledgeFile(name: "test.txt", content: "Hello World")
        #expect(file.charCount == 11)
        #expect(file.name == "test.txt")
    }

    // MARK: - Conversation skillId

    @Test("Conversation Skill Id Backward Compat")
    func conversationSkillIdBackwardCompat() throws {
        let json = """
        {
            "id": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
            "title": "Old Chat",
            "providerID": "B1B2C3D4-E5F6-7890-ABCD-EF1234567890",
            "providerKind": "openAI",
            "modelID": "gpt-4o",
            "previewText": "Hello",
            "estimatedCost": 0.01,
            "isDraft": false,
            "messages": [],
            "useMemory": true
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Conversation.self, from: json)
        #expect(decoded.skillId == nil)
        #expect(decoded.useMemory == true)
    }

    @Test("Conversation skillId roundtrip")
    func conversationSkillIdRoundtrip() throws {
        let skillUUID = UUID()
        var conv = TestFactories.makeConversation()
        conv.skillId = skillUUID

        let data = try TestFactories.jsonEncoder.encode(conv)
        let decoded = try TestFactories.jsonDecoder.decode(Conversation.self, from: data)

        #expect(decoded.skillId == skillUUID)
    }

    // MARK: - SkillCatalogResponse

    @Test("Catalog Response No Change")
    func catalogResponseNoChange() throws {
        let json = """
        {"version": 2, "skills": null, "categories": null}
        """.data(using: .utf8)!

        let decoded = try decoder.decode(SkillCatalogResponse.self, from: json)
        #expect(decoded.version == 2)
        #expect(decoded.skills == nil)
        #expect(decoded.categories == nil)
    }
}
