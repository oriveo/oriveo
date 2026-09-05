import Foundation
@testable import Oriveo


enum TestFactories {

    // MARK: - Provider

    static func makeProvider(
        id: UUID = UUID(),
        kind: ProviderKind = .openAI,
        status: ProviderConnectionState = .connected,
        models: [AIModel]? = nil,
        catalogModels: [AIModel] = [],
        
        lastCheckedAt: Date? = Date(),
        apiKey: String = "sk-test-key-12345",
        apiKeyPreview: String = "sk-...12345",
        lastError: String? = nil,
        baseURLText: String? = nil,
        customName: String? = nil,
        updatedAt: Date = .distantPast
    ) -> Provider {
        let defaultModels = models ?? [makeModel(id: "gpt-4o")]
        var p = Provider(
            id: id,
            kind: kind,
            status: status,
            models: defaultModels,
            catalogModels: catalogModels,
            
            lastCheckedAt: lastCheckedAt,
            apiKey: apiKey,
            apiKeyPreview: apiKeyPreview,
            lastError: lastError,
            baseURLText: baseURLText ?? kind.defaultBaseURLText,
            customName: customName
        )
        p.updatedAt = updatedAt
        return p
    }

    // MARK: - AIModel

    static func makeModel(
        id: String = "test-model",
        name: String? = nil,
        capabilities: [ModelCapability] = [],
        reasoningModeAvailable: Bool = false,
        isAvailable: Bool = true,
        isDefault: Bool = false,
        priceTier: String = "standard",
        summary: String? = nil,
        groupKey: String? = nil,
        groupName: String? = nil,
        promptPrice: Double? = nil,
        completionPrice: Double? = nil,
        canonicalModelId: String? = nil,
        isRecommended: Bool = false,
        sortRank: Int? = nil,
        createdAt: TimeInterval? = nil,
        isManual: Bool = false
    ) -> AIModel {
        AIModel(
            id: id,
            name: name ?? id,
            capabilities: capabilities,
            reasoningModeAvailable: reasoningModeAvailable,
            isAvailable: isAvailable,
            isDefault: isDefault,
            priceTier: priceTier,
            summary: summary,
            groupKey: groupKey,
            groupName: groupName,
            createdAt: createdAt,
            promptPrice: promptPrice,
            completionPrice: completionPrice,
            canonicalModelId: canonicalModelId,
            isRecommended: isRecommended,
            sortRank: sortRank,
            isManual: isManual
        )
    }

    // MARK: - ChatMessage

    static func makeMessage(
        id: UUID = UUID(),
        role: ChatRole = .user,
        text: String = "Hello",
        providerID: UUID? = nil,
        providerKind: ProviderKind = .openAI,
        providerName: String? = nil,
        modelID: String? = nil,
        modelName: String = "GPT-4o",
        estimatedCost: Double = 0,
        state: ChatMessageState = .delivered,
        errorTitle: String? = nil,
        errorDetail: String? = nil,
        attachments: [Oriveo.Attachment]? = nil,
        createdAt: Date? = Date()
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            role: role,
            text: text,
            providerID: providerID,
            providerKind: providerKind,
            providerName: providerName ?? providerKind.displayName,
            modelID: modelID,
            modelName: modelName,
            estimatedCost: estimatedCost,
            state: state,
            errorTitle: errorTitle,
            errorDetail: errorDetail,
            attachments: attachments,
            createdAt: createdAt
        )
    }

    // MARK: - Conversation

    static func makeConversation(
        id: UUID = UUID(),
        title: String = "Test Chat",
        hasCustomTitle: Bool = false,
        providerID: UUID = UUID(),
        providerKind: ProviderKind = .openAI,
        modelID: String = "gpt-4o",
        previewText: String? = nil,
        estimatedCost: Double = 0,
        isDraft: Bool = false,
        messages: [ChatMessage] = [],
        draftText: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        folderID: UUID? = nil
    ) -> Conversation {
        var conv = Conversation(
            id: id,
            title: title,
            providerID: providerID,
            providerKind: providerKind,
            modelID: modelID,
            previewText: previewText ?? messages.last?.text ?? "",
            estimatedCost: estimatedCost,
            isDraft: isDraft,
            messages: messages,
            draftText: draftText,
            createdAt: createdAt,
            updatedAt: updatedAt,
            folderID: folderID
        )
        conv.hasCustomTitle = hasCustomTitle
        return conv
    }

    // MARK: - Folder

    static func makeFolder(
        id: UUID = UUID(),
        name: String = "Test Folder",
        sortOrder: Int = 1000,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) -> Folder {
        Folder(
            id: id,
            name: name,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - Attachment

    static func makeImageAttachment(
        id: UUID = UUID(),
        fileName: String = "photo.jpg",
        mimeType: String = "image/jpeg",
        localImageID: String? = nil,
        thumbnailBase64: String? = "iVBORw0KGgo="
    ) -> Oriveo.Attachment {
        Oriveo.Attachment(
            id: id,
            kind: .image,
            fileName: fileName,
            mimeType: mimeType,
            localImageID: localImageID,
            thumbnailBase64: thumbnailBase64
        )
    }

    static func makeFileAttachment(
        id: UUID = UUID(),
        fileName: String = "report.pdf",
        mimeType: String = "application/pdf",
        base64Data: String? = "JVBERi0xLjQ=",
        originalBase64Data: String? = nil
    ) -> Oriveo.Attachment {
        Oriveo.Attachment(
            id: id,
            kind: .file,
            fileName: fileName,
            mimeType: mimeType,
            base64Data: base64Data,
            originalBase64Data: originalBase64Data
        )
    }

    // MARK: - AppSessionSnapshot

    static func makeSnapshot(
        selectedTab: AppTab = .home,
        hasCompletedOnboarding: Bool = true,
        providers: [Provider] = [],
        conversations: [Conversation] = [],
        lastUsedModelRef: LastUsedModelRef? = nil,
        folders: [Folder]? = nil
    ) -> AppSessionSnapshot {
        AppSessionSnapshot(
            selectedTab: selectedTab,
            hasCompletedOnboarding: hasCompletedOnboarding,
            providers: providers,
            conversations: conversations,
            lastUsedModelRef: lastUsedModelRef,
            folders: folders
        )
    }


    static var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
