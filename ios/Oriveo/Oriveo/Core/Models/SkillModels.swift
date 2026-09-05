import Foundation

// MARK: - Skill

struct Skill: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var description: String
    var icon: String              // emoji
    var color: String
    var systemPrompt: String
    var suggestedProviderId: String?
    var suggestedModelId: String?
    var modelCapabilityHint: String   // "any"|"reasoning"|"vision"|"fast"|"large-context"
    var temperature: Double?
    var reasoningLevel: String?
    var webSearchEnabled: Bool?
    var starterMessages: [String]
    var knowledgeFiles: [SkillKnowledgeFile]
    var knowledgeBase: SkillKnowledgeBase?
    var useMemory: Bool
    var isPinned: Bool
    var pinOrder: Int
    var source: SkillSource
    var forkedFromId: UUID?
    var key: String?
    var category: String?
    var sortOrder: Int
    var usageCount: Int
    var lastUsedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    var isBuiltIn: Bool { source == .builtin }
    var isEditable: Bool { source == .user }

    var localizedName: String {
        guard isBuiltIn, let key else { return name }
        let l10nKey = "skill.\(key).name"
        let localized = L10n.tr(l10nKey)
        return localized == l10nKey ? name : localized
    }

    var localizedDescription: String {
        guard isBuiltIn, let key else { return description }
        let l10nKey = "skill.\(key).description"
        let localized = L10n.tr(l10nKey)
        return localized == l10nKey ? description : localized
    }

    var localizedStarterMessages: [String] {
        guard isBuiltIn, let key else { return starterMessages }
        return starterMessages.enumerated().map { index, fallback in
            let l10nKey = "skill.\(key).starter_\(index)"
            let localized = L10n.tr(l10nKey)
            return localized == l10nKey ? fallback : localized
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, key, name, description, icon, color, systemPrompt
        case suggestedProviderId, suggestedModelId, modelCapabilityHint
        case temperature, reasoningLevel, webSearchEnabled
        case starterMessages, knowledgeFiles, knowledgeBase, useMemory, isPinned, pinOrder
        case source, forkedFromId, category, sortOrder
        case usageCount, lastUsedAt, createdAt, updatedAt
    }

    init(
        id: UUID = UUID(),
        key: String? = nil,
        name: String,
        description: String = "",
        icon: String = "🤖",
        color: String = "#6d38ff",
        systemPrompt: String = "",
        suggestedProviderId: String? = nil,
        suggestedModelId: String? = nil,
        modelCapabilityHint: String = "any",
        temperature: Double? = nil,
        reasoningLevel: String? = nil,
        webSearchEnabled: Bool? = nil,
        starterMessages: [String] = [],
        knowledgeFiles: [SkillKnowledgeFile] = [],
        knowledgeBase: SkillKnowledgeBase? = nil,
        useMemory: Bool = true,
        isPinned: Bool = false,
        pinOrder: Int = 0,
        source: SkillSource = .user,
        forkedFromId: UUID? = nil,
        category: String? = nil,
        sortOrder: Int = 0,
        usageCount: Int = 0,
        lastUsedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.key = key
        self.name = name
        self.description = description
        self.icon = icon
        self.color = color
        self.systemPrompt = systemPrompt
        self.suggestedProviderId = suggestedProviderId
        self.suggestedModelId = suggestedModelId
        self.modelCapabilityHint = modelCapabilityHint
        self.temperature = temperature
        self.reasoningLevel = reasoningLevel
        self.webSearchEnabled = webSearchEnabled
        self.starterMessages = starterMessages
        self.knowledgeFiles = knowledgeFiles
        self.knowledgeBase = knowledgeBase
        self.useMemory = useMemory
        self.isPinned = isPinned
        self.pinOrder = pinOrder
        self.source = source
        self.forkedFromId = forkedFromId
        self.category = category
        self.sortOrder = sortOrder
        self.usageCount = usageCount
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let uuid = try? c.decode(UUID.self, forKey: .id) {
            id = uuid
        } else {
            let idString = try c.decode(String.self, forKey: .id)
            guard let parsed = UUID(uuidString: idString) else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Invalid UUID string: \(idString)")
            }
            id = parsed
        }
        key = try c.decodeIfPresent(String.self, forKey: .key)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "🤖"
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#6d38ff"
        systemPrompt = try c.decode(String.self, forKey: .systemPrompt)
        suggestedProviderId = try c.decodeIfPresent(String.self, forKey: .suggestedProviderId)
        suggestedModelId = try c.decodeIfPresent(String.self, forKey: .suggestedModelId)
        modelCapabilityHint = try c.decodeIfPresent(String.self, forKey: .modelCapabilityHint) ?? "any"
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        reasoningLevel = try c.decodeIfPresent(String.self, forKey: .reasoningLevel)
        webSearchEnabled = try c.decodeIfPresent(Bool.self, forKey: .webSearchEnabled)
        starterMessages = try c.decodeIfPresent([String].self, forKey: .starterMessages) ?? []
        knowledgeFiles = try c.decodeIfPresent([SkillKnowledgeFile].self, forKey: .knowledgeFiles) ?? []
        knowledgeBase = try c.decodeIfPresent(SkillKnowledgeBase.self, forKey: .knowledgeBase)
        useMemory = try c.decodeIfPresent(Bool.self, forKey: .useMemory) ?? true
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        pinOrder = try c.decodeIfPresent(Int.self, forKey: .pinOrder) ?? 0
        source = try c.decodeIfPresent(SkillSource.self, forKey: .source) ?? .user
        if let forkStr = try c.decodeIfPresent(String.self, forKey: .forkedFromId) {
            forkedFromId = UUID(uuidString: forkStr)
        } else {
            forkedFromId = try c.decodeIfPresent(UUID.self, forKey: .forkedFromId)
        }
        category = try c.decodeIfPresent(String.self, forKey: .category)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        usageCount = try c.decodeIfPresent(Int.self, forKey: .usageCount) ?? 0
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

// MARK: - SkillKnowledgeFile

nonisolated enum SkillKnowledgeFileSourceType: String, Codable, Hashable, Sendable {
    case text
    case pdfText = "pdf_text"
}

nonisolated enum SkillKnowledgeFileStatus: String, Codable, Hashable, Sendable {
    case extracting
    case uploading
    case indexing
    case ready
    case failed
    case replacing
    case deleting
    case disabled
}

nonisolated enum SkillKnowledgeIngestionMode: String, Codable, Hashable, Sendable {
    case nativeFile = "native_file"
    case extractedText = "extracted_text"
}

nonisolated enum SkillKnowledgeExtractedFrom: String, Codable, Hashable, Sendable {
    case xlsx
}

nonisolated enum SkillKnowledgeErrorCode: String, Codable, Hashable, Sendable {
    case openAINotConfigured = "openai_not_configured"
    case openAIEndpointNotOfficial = "openai_endpoint_not_official"
    case retrievalModelNotEnabled = "retrieval_model_not_enabled"
    case knowledgeServiceUnavailable = "knowledge_service_unavailable"
    case unsupportedFileType = "unsupported_file_type"
    case referenceFileTooLarge = "reference_file_too_large"
    case referenceFileCharLimitExceeded = "reference_file_char_limit_exceeded"
    case knowledgeFileTooLarge = "knowledge_file_too_large"
    case knowledgeTotalSizeExceeded = "knowledge_total_size_exceeded"
    case knowledgeExtractFailed = "knowledge_extract_failed"
    case knowledgeUploadFailed = "knowledge_upload_failed"
    case knowledgeIndexFailed = "knowledge_index_failed"
    case knowledgeRetrieveFailed = "knowledge_retrieve_failed"
    case knowledgeCleanupFailed = "knowledge_cleanup_failed"
}

nonisolated struct SkillKnowledgeFile: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var mimeType: String
    var sourceType: SkillKnowledgeFileSourceType
    var content: String
    var charCount: Int
    var createdAt: Date?
    var updatedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        mimeType: String = "text/plain",
        sourceType: SkillKnowledgeFileSourceType = .text,
        content: String,
        charCount: Int? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.sourceType = sourceType
        self.content = content
        self.charCount = charCount ?? content.count
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, mimeType, sourceType, content, charCount, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let uuid = try? c.decode(UUID.self, forKey: .id) {
            id = uuid
        } else {
            let idString = try c.decode(String.self, forKey: .id)
            id = UUID(uuidString: idString) ?? UUID()
        }
        name = try c.decode(String.self, forKey: .name)
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? "text/plain"
        sourceType = try c.decodeIfPresent(SkillKnowledgeFileSourceType.self, forKey: .sourceType) ?? .text
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        charCount = try c.decodeIfPresent(Int.self, forKey: .charCount) ?? content.count
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

nonisolated struct SkillKnowledgeBase: Codable, Hashable, Sendable {
    var provider: String
    var retrievalModel: String
    var vectorStoreId: String
    var expiresAfterDays: Int
    var files: [SkillKnowledgeBaseFile]
    var updatedAt: Date?
}

nonisolated struct SkillKnowledgeBaseFile: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var mimeType: String
    var sizeBytes: Int
    var ingestionMode: SkillKnowledgeIngestionMode
    var extractedFrom: SkillKnowledgeExtractedFrom?
    var openAIFileId: String?
    var status: SkillKnowledgeFileStatus
    var errorCode: SkillKnowledgeErrorCode?
    var createdAt: Date?
    var updatedAt: Date?
}

// MARK: - SkillSource

enum SkillSource: String, Codable {
    case builtin, user, community
}

// MARK: - API Responses

struct SkillCatalogResponse: Codable {
    let version: Int
    let skills: [Skill]?
    let categories: [SkillCategory]?
}

struct SkillConflictResponse: Codable {
    let error: String
    let serverSkill: Skill
}

struct SkillCategory: Codable, Identifiable {
    let id: String
    let name: String
    let icon: String
    let sortOrder: Int

    var localizedName: String {
        let l10nKey = "skill.category.\(id)"
        let localized = L10n.tr(l10nKey)
        return localized == l10nKey ? name : localized
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, sortOrder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "📁"
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
}

struct UserSkillsResponse: Codable {
    let skills: [Skill]
    let usage: SkillUsage
}

struct SkillUsage: Codable {
    let count: Int
    let limit: Int?
    let isPro: Bool

    private enum CodingKeys: String, CodingKey {
        case count, limit, isPro
    }

    init(count: Int = 0, limit: Int? = 5, isPro: Bool = false) {
        self.count = count
        self.limit = limit
        self.isPro = isPro
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        limit = try c.decodeIfPresent(Int.self, forKey: .limit)
        isPro = try c.decodeIfPresent(Bool.self, forKey: .isPro) ?? false
    }
}

struct CreateSkillResponse: Codable {
    let skill: Skill
    let usage: SkillUsage
}

struct UpdateSkillResponse: Codable {
    let skill: Skill
}

struct DeleteSkillResponse: Codable {
    let usage: SkillUsage
}

// MARK: - SkillError

enum SkillError: LocalizedError {
    case notAuthenticated
    case quotaExceeded(count: Int, limit: Int)
    case conflict(serverSkill: Skill)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return L10n.tr("This Skill could not be updated.")
        case .quotaExceeded:
            return nil
        case .conflict:
            return nil
        }
    }
}
