import Foundation

enum SampleData {
    static var privacyPromises: [String] {
        [
            L10n.tr("API keys stay on your device"),
            L10n.tr("Chat data is not uploaded to Oriveo servers"),
            L10n.tr("Exported backups can be encrypted")
        ]
    }

    static var defaultConversationTitle: String {
        L10n.tr("New Chat")
    }

    static var allDefaultConversationTitles: Set<String> {
        ["新聊天", "New Chat", "新規チャット", "새 채팅", "Nuevo chat", "Nouvelle discussion", "Neuer Chat", "Novo chat", "محادثة جديدة"]
    }

    static func makeProvider(
        kind: ProviderKind,
        apiKey: String,
        existingID: UUID? = nil,
        manualModelID: String? = nil
    ) -> Provider {
        let models: [AIModel]
        let recommendations: [AIModel]

        if let manualModelID {
            models = [
                AIModel(
                    id: manualModelID,
                    name: manualModelID,
                    capabilities: [.text],
                    reasoningModeAvailable: false,
                    isAvailable: true,
                    isDefault: true,
                    priceTier: "",
                    summary: L10n.tr("Manually added fallback model"),
                    groupKey: nil,
                    groupName: nil,
                    isManual: true
                )
            ]
        } else {
            models = defaultModels(for: kind)
        }

        return Provider(
            id: existingID ?? UUID(),
            kind: kind,
            status: .connected,
            models: models,
            catalogModels: models,
            lastCheckedAt: Date(),
            apiKey: apiKey,
            apiKeyPreview: APIKeyMask.masked(apiKey),
            lastError: nil,
            baseURLText: kind.defaultBaseURLText
        )
    }

    static func makeStarterConversations(provider: Provider) -> [Conversation] {
        guard let model = provider.defaultModel else { return [] }

        let analysisConversation = Conversation(
            id: UUID(),
            title: L10n.tr("Quarterly Growth Report"),
            providerID: provider.id,
            providerKind: provider.kind,
            modelID: model.id,
            previewText: L10n.tr("Need to identify the top three drivers of revenue growth."),

            estimatedCost: 0.05,
            isDraft: false,
            messages: [
                ChatMessage(
                    id: UUID(),
                    role: .assistant,
                    text: L10n.tr("How can I help you with your productivity today? I can analyze data, write code, or help organize your schedule."),
                    providerKind: provider.kind,
                    providerName: provider.displayName,
                    modelName: model.name,
                    estimatedCost: 0,
                    state: .delivered
                ),
                ChatMessage(
                    id: UUID(),
                    role: .user,
                    text: L10n.tr("Can you help me analyze this dataset for my quarterly report? I need to identify the top three growth drivers from the last six months."),
                    providerKind: provider.kind,
                    providerName: provider.displayName,
                    modelName: model.name,
                    estimatedCost: 0,
                    state: .delivered
                ),
                ChatMessage(
                    id: UUID(),
                    role: .assistant,
                    text: L10n.tr("Here are the key insights from the last six months:\n\n- **Product referrals** continue to grow, indicating word-of-mouth is gaining traction.\n- **Direct sales** maintain steady growth as the most stable conversion source.\n- **Organic search** improved significantly — the new content strategy is paying off."),
                    providerKind: provider.kind,
                    providerName: provider.displayName,
                    modelName: model.name,
                    estimatedCost: 0.03,
                    state: .delivered
                )
            ],
            draftText: "",
            updatedAt: Date().addingTimeInterval(-720)
        )

        let draftConversation = Conversation(
            id: UUID(),
            title: defaultConversationTitle,
            providerID: provider.id,
            providerKind: provider.kind,
            modelID: model.id,
            previewText: L10n.tr("Summarize the most common complaints from user research..."),

            estimatedCost: 0,
            isDraft: true,
            messages: [],
            draftText: L10n.tr("Summarize the most common complaints from user research...")
        )

        return [analysisConversation, draftConversation]
    }

    static func makeBlankConversation(provider: Provider, preferredModelID: String? = nil) -> Conversation {
        let model = provider.allModels.first(where: { $0.id == preferredModelID }) ?? provider.defaultModel ?? provider.models.first

        return Conversation(
            id: UUID(),
            title: defaultConversationTitle,
            providerID: provider.id,
            providerKind: provider.kind,
            modelID: model?.id ?? "",
            previewText: "",

            estimatedCost: 0,
            isDraft: true,
            messages: [],
            draftText: ""
        )
    }

    static func assistantReply(for text: String, modelName: String) -> String {
        String(format: L10n.tr("I've drafted a response based on %@'s current context that you can keep iterating on:\n\n- Break the problem into the three most important decisions first.\n- Start with an actionable first step so you can keep moving.\n- If you want, I can turn it into a more detailed checklist, copy, or code next.\n\nYour latest message was: %@"), modelName, text)
    }

    private static func defaultModels(for kind: ProviderKind) -> [AIModel] {
        switch kind {
        case .anthropic:
            return [
                AIModel(id: "anthropic-claude-4-sonnet", name: "claude-4-sonnet", capabilities: [.reasoning, .text, .image], reasoningModeAvailable: true, isAvailable: true, isDefault: true, priceTier: "$3/M", summary: "Logic, Creative, Coding", groupKey: nil, groupName: nil),
                AIModel(id: "anthropic-claude-4-opus", name: "claude-4-opus", capabilities: [.reasoning, .text, .image, .file], reasoningModeAvailable: true, isAvailable: true, isDefault: false, priceTier: "$15/M", summary: "Intelligent, Deep Reasoning, Writing", groupKey: nil, groupName: nil),
                AIModel(id: "anthropic-claude-4-haiku", name: "claude-4-haiku", capabilities: [.text, .image], reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: "$0.25/M", summary: "Instant, Basic Chat, Speed", groupKey: nil, groupName: nil)
            ]
        case .openAI:
            return [
                AIModel(id: "openai-gpt-4o", name: "GPT-4o", capabilities: [.reasoning, .text, .image, .file, .web], reasoningModeAvailable: true, isAvailable: true, isDefault: true, priceTier: "$2.5/M", summary: "Multimodal, Vision, Audio, Logic", groupKey: nil, groupName: nil),
                AIModel(id: "openai-o3", name: "o3", capabilities: [.reasoning, .text, .web], reasoningModeAvailable: true, isAvailable: true, isDefault: false, priceTier: "$10/M", summary: "Reasoning-first, Complex Analysis", groupKey: nil, groupName: nil),
                AIModel(id: "openai-gpt-4.1-mini", name: "GPT-4.1 mini", capabilities: [.text, .image], reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: "$0.4/M", summary: "Fast, Cheap, Everyday Tasks", groupKey: nil, groupName: nil)
            ]
        case .gemini:
            return [
                AIModel(id: "gemini-2.0-flash", name: "gemini-2.0-flash", capabilities: [.text, .image, .file, .web], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "$0.1/M", summary: "Fast multimodal assistant", groupKey: nil, groupName: nil),
                AIModel(id: "gemini-2.0-pro", name: "gemini-2.0-pro", capabilities: [.reasoning, .text, .image, .file, .web], reasoningModeAvailable: true, isAvailable: true, isDefault: false, priceTier: "$1.25/M", summary: "Research, long context, tools", groupKey: nil, groupName: nil)
            ]
        case .openRouter:
            return [
                AIModel(id: "anthropic/claude-4-sonnet", name: "claude-4-sonnet", capabilities: [.reasoning, .text, .image], reasoningModeAvailable: true, isAvailable: true, isDefault: true, priceTier: "$3/M", summary: "Unified routing, logic, quality", groupKey: "anthropic", groupName: "Anthropic"),
                AIModel(id: "openai/gpt-4.1", name: "gpt-4.1", capabilities: [.text, .image, .file], reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: "$2/M", summary: "Balanced, capable generalist", groupKey: "openai", groupName: "OpenAI"),
                AIModel(id: "google/gemini-2.0-flash", name: "gemini-2.0-flash", capabilities: [.text, .image, .web], reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: "$0.1/M", summary: "Cheap, fast, multimodal", groupKey: "google", groupName: "Google")
            ]
        case .deepseek:
            return [
                AIModel(id: "deepseek-chat", name: "DeepSeek Chat", capabilities: [.text], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "$0.27/M", summary: "Official general-purpose chat", groupKey: nil, groupName: nil),
                AIModel(id: "deepseek-reasoner", name: "DeepSeek Reasoner", capabilities: [.reasoning, .text], reasoningModeAvailable: true, isAvailable: true, isDefault: false, priceTier: "$1.10/M", summary: "Official reasoning mode", groupKey: nil, groupName: nil)
            ]
        case .grok:
            return [
                AIModel(id: "grok-4", name: "Grok 4", capabilities: [.reasoning, .text, .image], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "$3/M", summary: "Frontier reasoning and vision", groupKey: nil, groupName: nil),
                AIModel(id: "grok-3-mini", name: "Grok 3 mini", capabilities: [.reasoning, .text], reasoningModeAvailable: true, isAvailable: true, isDefault: false, priceTier: "$0.3/M", summary: "Fast reasoning with adjustable effort", groupKey: nil, groupName: nil)
            ]
        case .groq:
            return [
                AIModel(id: "llama-3.3-70b-versatile", name: "llama-3.3-70b-versatile", capabilities: [.text], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "$0.59/M", summary: "Fast, versatile, general purpose", groupKey: "llama-3.3", groupName: "Llama 3.3"),
                AIModel(id: "deepseek-r1-distill-llama-70b", name: "deepseek-r1-distill-llama-70b", capabilities: [.reasoning, .text], reasoningModeAvailable: true, isAvailable: true, isDefault: false, priceTier: "$0.75/M", summary: "Reasoning, analysis", groupKey: "deepseek", groupName: "DeepSeek")
            ]
        case .together:
            return [
                AIModel(id: "meta-llama/Llama-3.3-70B-Instruct-Turbo", name: "Llama 3.3 70B Instruct Turbo", capabilities: [.text], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "$0.88/M", summary: "Fast, versatile, general purpose", groupKey: "llama-3.3", groupName: "Llama 3.3"),
                AIModel(id: "deepseek-ai/DeepSeek-R1", name: "DeepSeek R1", capabilities: [.reasoning, .text], reasoningModeAvailable: true, isAvailable: true, isDefault: false, priceTier: "$3/M", summary: "Reasoning, analysis", groupKey: "deepseek", groupName: "DeepSeek")
            ]
        case .fireworks:
            return [
                AIModel(id: "accounts/fireworks/models/llama-v3p3-70b-instruct", name: "llama-v3p3-70b-instruct", capabilities: [.text], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "$0.9/M", summary: "Fast, versatile, general purpose", groupKey: "llama-3.3", groupName: "Llama 3.3"),
                AIModel(id: "accounts/fireworks/models/deepseek-r1", name: "deepseek-r1", capabilities: [.reasoning, .text], reasoningModeAvailable: true, isAvailable: true, isDefault: false, priceTier: "$3/M", summary: "Reasoning, analysis", groupKey: "deepseek", groupName: "DeepSeek")
            ]
        case .miniMax:
            return [
                AIModel(id: "MiniMax-Text-01", name: "MiniMax-Text-01", capabilities: [.text], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "", summary: "General purpose chat", groupKey: nil, groupName: nil)
            ]
        case .zhipu:
            return [
                AIModel(id: "glm-4-plus", name: "GLM-4-Plus", capabilities: [.text], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "", summary: "General purpose chat", groupKey: nil, groupName: nil)
            ]
        case .qwen:
            return [
                AIModel(id: "qwen-plus", name: "Qwen Plus", capabilities: [.text], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "", summary: "General purpose chat", groupKey: nil, groupName: nil)
            ]
        case .moonshot:
            return [
                AIModel(id: "kimi-k2-0905-preview", name: "Kimi K2 Preview", capabilities: [.reasoning, .text, .image, .web], reasoningModeAvailable: true, isAvailable: true, isDefault: true, priceTier: "$0.6/M", summary: "Long context multimodal reasoning", groupKey: "kimi", groupName: "Kimi")
            ]
        case .mistral:
            return [
                AIModel(id: "magistral-medium-latest", name: "Magistral Medium", capabilities: [.reasoning, .text, .image], reasoningModeAvailable: true, isAvailable: true, isDefault: true, priceTier: "$2/M", summary: "Reasoning with visible thinking", groupKey: nil, groupName: nil),
                AIModel(id: "mistral-medium-3-5", name: "Mistral Medium 3.5", capabilities: [.text, .image], reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: "$0.4/M", summary: "Frontier multimodal chat", groupKey: nil, groupName: nil)
            ]
        case .siliconFlow:
            return [
                AIModel(id: "deepseek-ai/DeepSeek-V3.1", name: "DeepSeek V3.1", capabilities: [.reasoning, .text], reasoningModeAvailable: true, isAvailable: true, isDefault: true, priceTier: "", summary: "Aggregated frontier chat", groupKey: "deepseek-ai", groupName: "DeepSeek"),
                AIModel(id: "Qwen/Qwen3-32B", name: "Qwen3 32B", capabilities: [.text], reasoningModeAvailable: true, isAvailable: true, isDefault: false, priceTier: "", summary: "Fast multilingual reasoning", groupKey: "qwen", groupName: "Qwen")
            ]
        case .relay:
            return []
        }
    }
}
