import Foundation
import UniformTypeIdentifiers

struct SkillEditDraft: Sendable, Equatable {
    var name: String
    var description: String
    var icon: String
    var color: String
    var systemPrompt: String
    var suggestedProviderId: String?
    var suggestedModelId: String?
    var modelCapabilityHint: String
    var starterMessages: [String]
    var knowledgeFiles: [SkillKnowledgeFile]
    var knowledgeBase: SkillKnowledgeBase?
    var useMemory: Bool
    var temperature: Double?
    var reasoningLevel: String?
    var webSearchEnabled: Bool?
}

struct SkillKnowledgeDraftCleanupPlan: Sendable, Equatable {
    let vectorStoreId: String
    let deleteVectorStore: Bool
    let openAIFileIDs: [String]
}

nonisolated enum SkillKnowledgeEditingSupport {
    static let maxReferenceFileSize = 3 * 1024 * 1024
    static let maxKnowledgeFileSize = 20 * 1024 * 1024
    static let maxKnowledgeFiles = 5
    static let maxKnowledgeTotalBytes = 100 * 1024 * 1024
    static let maxFileNameLength = 120

    private static let textFileExtensions: Set<String> = [
        "txt", "md", "json", "csv", "html", "xml", "yaml", "yml",
        "css", "js", "ts", "jsx", "tsx", "py", "java", "kt", "swift", "go", "sql"
    ]

    static let referenceFileContentTypes: [UTType] = buildAllowedContentTypes(
        supportedFileTypes: ["pdf", "txt", "docx", "xlsx", "pptx"]
    )

    static func codePointCount(_ string: String) -> Int {
        string.unicodeScalars.count
    }

    static func sanitizeFileName(_ name: String, maxLength: Int = maxFileNameLength) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        }
        let normalized = String(cleaned).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else { return "file" }
        guard normalized.count > maxLength else { return normalized }

        let fileURL = URL(fileURLWithPath: normalized)
        let ext = fileURL.pathExtension
        guard !ext.isEmpty else {
            return String(normalized.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let dotExt = ".\(ext)"
        let base = fileURL.deletingPathExtension().lastPathComponent
        let baseLimit = max(1, maxLength - dotExt.count)
        let clippedBase = String(base.prefix(baseLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(clippedBase)\(dotExt)".prefix(maxLength).description
    }

    static func validateReferenceFileSize(_ sizeBytes: Int) -> SkillKnowledgeErrorCode? {
        sizeBytes > maxReferenceFileSize ? .referenceFileTooLarge : nil
    }

    static func knowledgeFileContentTypes(supportedFileTypes: [String]) -> [UTType] {
        buildAllowedContentTypes(supportedFileTypes: supportedFileTypes)
    }

    static func validateKnowledgeBaseQuota(
        existingCount: Int,
        existingBytes: Int,
        nextFileBytes: Int
    ) -> SkillKnowledgeErrorCode? {
        if existingCount >= maxKnowledgeFiles {
            return .knowledgeTotalSizeExceeded
        }
        if nextFileBytes > maxKnowledgeFileSize {
            return .knowledgeFileTooLarge
        }
        if existingBytes + nextFileBytes > maxKnowledgeTotalBytes {
            return .knowledgeTotalSizeExceeded
        }
        return nil
    }

    static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    static func isKnowledgeFileTypeSupported(
        fileName: String,
        mimeType: String,
        supportedFileTypes: [String]
    ) -> Bool {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        if supportedFileTypes.contains(ext) {
            return true
        }
        if supportedFileTypes.contains("txt") {
            return mimeType.starts(with: "text/") || textFileExtensions.contains(ext)
        }
        return false
    }

    static func sumKnowledgeBaseBytes(_ knowledgeBase: SkillKnowledgeBase?) -> Int {
        knowledgeBase?.files.reduce(0, { $0 + $1.sizeBytes }) ?? 0
    }

    static func buildReferenceKnowledgeFile(
        id: UUID = UUID(),
        name: String,
        mimeType: String,
        sourceType: SkillKnowledgeFileSourceType,
        content: String,
        now: Date = Date()
    ) -> SkillKnowledgeFile {
        SkillKnowledgeFile(
            id: id,
            name: sanitizeFileName(name),
            mimeType: mimeType,
            sourceType: sourceType,
            content: content,
            charCount: codePointCount(content),
            createdAt: now,
            updatedAt: now
        )
    }

    static func buildLocalKnowledgeBaseFile(
        id: String,
        name: String,
        mimeType: String,
        sizeBytes: Int,
        ingestionMode: SkillKnowledgeIngestionMode,
        extractedFrom: SkillKnowledgeExtractedFrom? = nil,
        openAIFileId: String? = nil,
        status: SkillKnowledgeFileStatus,
        errorCode: SkillKnowledgeErrorCode? = nil,
        createdAt: Date? = nil,
        updatedAt: Date = Date()
    ) -> SkillKnowledgeBaseFile {
        SkillKnowledgeBaseFile(
            id: id,
            name: sanitizeFileName(name),
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            ingestionMode: ingestionMode,
            extractedFrom: extractedFrom,
            openAIFileId: openAIFileId,
            status: status,
            errorCode: errorCode,
            createdAt: createdAt ?? updatedAt,
            updatedAt: updatedAt
        )
    }

    static func upsertKnowledgeBase(
        knowledgeBase: SkillKnowledgeBase?,
        provider: String,
        retrievalModel: String,
        expiresAfterDays: Int,
        vectorStoreId: String? = nil,
        file: SkillKnowledgeBaseFile
    ) -> SkillKnowledgeBase {
        var files = knowledgeBase?.files ?? []
        if let index = files.firstIndex(where: { $0.id == file.id }) {
            files[index] = file
        } else {
            files.append(file)
        }

        return SkillKnowledgeBase(
            provider: provider,
            retrievalModel: retrievalModel,
            vectorStoreId: vectorStoreId ?? knowledgeBase?.vectorStoreId ?? "",
            expiresAfterDays: expiresAfterDays,
            files: files,
            updatedAt: Date()
        )
    }

    static func removeKnowledgeBaseFile(
        knowledgeBase: SkillKnowledgeBase?,
        targetFileID: String
    ) -> SkillKnowledgeBase? {
        guard let knowledgeBase else { return nil }
        let remaining = knowledgeBase.files.filter { $0.id != targetFileID }
        guard !remaining.isEmpty else { return nil }
        return SkillKnowledgeBase(
            provider: knowledgeBase.provider,
            retrievalModel: knowledgeBase.retrievalModel,
            vectorStoreId: knowledgeBase.vectorStoreId,
            expiresAfterDays: knowledgeBase.expiresAfterDays,
            files: remaining,
            updatedAt: Date()
        )
    }

    static func buildDraftCleanupPlan(
        originalKnowledgeBase: SkillKnowledgeBase?,
        currentKnowledgeBase: SkillKnowledgeBase?
    ) -> SkillKnowledgeDraftCleanupPlan? {
        guard let currentKnowledgeBase else { return nil }

        let originalOpenAIFileIDs = Set(
            (originalKnowledgeBase?.files ?? [])
                .compactMap { $0.openAIFileId?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let openAIFileIDs = currentKnowledgeBase.files
            .compactMap { $0.openAIFileId?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !originalOpenAIFileIDs.contains($0) }

        guard !openAIFileIDs.isEmpty else { return nil }

        return SkillKnowledgeDraftCleanupPlan(
            vectorStoreId: currentKnowledgeBase.vectorStoreId,
            deleteVectorStore: originalKnowledgeBase == nil
                && !currentKnowledgeBase.vectorStoreId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            openAIFileIDs: openAIFileIDs
        )
    }

    static func requiresRemoteKnowledgeCleanup(
        originalKnowledgeBase: SkillKnowledgeBase?,
        currentKnowledgeBase: SkillKnowledgeBase?
    ) -> Bool {
        guard let originalKnowledgeBase else { return false }

        let originalOpenAIFileIDs = Set(
            originalKnowledgeBase.files
                .compactMap { $0.openAIFileId?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let currentOpenAIFileIDs = Set(
            (currentKnowledgeBase?.files ?? [])
                .compactMap { $0.openAIFileId?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        if originalOpenAIFileIDs.contains(where: { !currentOpenAIFileIDs.contains($0) }) {
            return true
        }

        let originalVectorStoreID = originalKnowledgeBase.vectorStoreId.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentVectorStoreID = currentKnowledgeBase?.vectorStoreId.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !originalVectorStoreID.isEmpty && originalVectorStoreID != currentVectorStoreID
    }

    static func normalizedKnowledgeBaseForComparison(_ knowledgeBase: SkillKnowledgeBase?) -> SkillKnowledgeBase? {
        guard let knowledgeBase else { return nil }
        return SkillKnowledgeBase(
            provider: knowledgeBase.provider,
            retrievalModel: knowledgeBase.retrievalModel,
            vectorStoreId: knowledgeBase.vectorStoreId,
            expiresAfterDays: knowledgeBase.expiresAfterDays,
            files: knowledgeBase.files.map(normalizedKnowledgeFileForComparison),
            updatedAt: nil
        )
    }

    private static func normalizedKnowledgeFileForComparison(_ file: SkillKnowledgeBaseFile) -> SkillKnowledgeBaseFile {
        var copy = file
        copy.updatedAt = nil
        guard file.status == .indexing else { return copy }
        copy.status = .ready
        return copy
    }

    static func buildSaveBody(from draft: SkillEditDraft) throws -> [String: Any] {
        struct Payload: Encodable {
            let name: String
            let description: String
            let icon: String
            let color: String
            let systemPrompt: String
            let suggestedProviderId: String?
            let suggestedModelId: String?
            let modelCapabilityHint: String
            let starterMessages: [String]
            let knowledgeFiles: [SkillKnowledgeFile]
            let knowledgeBase: SkillKnowledgeBase?
            let useMemory: Bool
            let temperature: Double?
            let reasoningLevel: String?
            let webSearchEnabled: Bool?
        }

        let payload = Payload(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: draft.description.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: draft.icon,
            color: draft.color,
            systemPrompt: draft.systemPrompt,
            suggestedProviderId: draft.suggestedProviderId,
            suggestedModelId: draft.suggestedModelId,
            modelCapabilityHint: draft.modelCapabilityHint,
            starterMessages: draft.starterMessages
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            knowledgeFiles: draft.knowledgeFiles,
            knowledgeBase: draft.knowledgeBase,
            useMemory: draft.useMemory,
            temperature: draft.temperature,
            reasoningLevel: draft.reasoningLevel,
            webSearchEnabled: draft.webSearchEnabled
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderServiceError.network(detail: "Failed to build skill payload.")
        }
        return body
    }

    private static func buildAllowedContentTypes(supportedFileTypes: [String]) -> [UTType] {
        let normalized = Set(supportedFileTypes.map { $0.lowercased() })
        let includeTextTypes = normalized.contains("txt")
        var seen = Set<String>()
        var result: [UTType] = []

        func append(_ type: UTType?) {
            guard let type, seen.insert(type.identifier).inserted else { return }
            result.append(type)
        }

        // Match the broader policy proven in ChatView so iCloud / Files sources are not filtered out.
        append(.content)
        append(.data)

        if normalized.contains("pdf") {
            append(.pdf)
        }

        if includeTextTypes {
            append(.text)
            append(.plainText)
            append(.utf8PlainText)
            append(.sourceCode)
            append(.json)
            append(.xml)
            append(.commaSeparatedText)
            for ext in textFileExtensions.sorted() {
                append(UTType(tag: ext, tagClass: .filenameExtension, conformingTo: .text))
            }
        }

        for ext in normalized.sorted() where ext != "txt" && ext != "pdf" {
            let conformsTo: UTType = textFileExtensions.contains(ext) ? .text : .data
            append(UTType(tag: ext, tagClass: .filenameExtension, conformingTo: conformsTo))
        }

        return result
    }
}
