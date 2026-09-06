import Foundation

struct RelayCatalogConnectionIdentity: Equatable {
    let endpoint: String?
    let apiKey: String
    let relayKind: RelayKind?
    let requestedWithoutModel: RelayRequestedConfig

    init(provider: Provider) {
        endpoint = provider.baseURLText?.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = provider.apiKey
        relayKind = provider.relayKind
        var requested = provider.relayRequested ?? RelayRequestedConfig()
        requested.modelID = nil
        requestedWithoutModel = requested
    }
}

enum RelayCatalogRefreshWritePolicy {
    static func mayFinish(
        requestToken: UUID,
        activeToken: UUID?,
        current: Provider,
        connectionIdentity: RelayCatalogConnectionIdentity
    ) -> Bool {
        activeToken == requestToken
            && current.kind == .relay
            && RelayCatalogConnectionIdentity(provider: current) == connectionIdentity
    }
}

enum RelayGenerationVerificationWritePolicy {
    static func mayCommit(current: Provider?, connectionIdentity: RelayCatalogConnectionIdentity) -> Bool {
        guard let current, current.kind == .relay else { return false }
        return RelayCatalogConnectionIdentity(provider: current) == connectionIdentity
    }
}

@MainActor
final class ProviderManager {

    nonisolated static let defaultManualModelCapabilities: Set<ModelCapability> = [.text, .image, .file, .web, .reasoning]

    nonisolated static func defaultManualModelCapabilities(
        for kind: ProviderKind
    ) -> Set<ModelCapability> {
        kind == .relay ? [.text] : defaultManualModelCapabilities
    }

    let openRouterService: OpenRouterService
    let openAIService: OpenAIService
    let deepSeekService: DeepSeekService
    let grokService: GrokService
    let geminiService: GeminiService
    let anthropicService: AnthropicService
    let groqService: GroqService
    let togetherService: TogetherService
    let fireworksService: FireworksService
    let miniMaxService: MiniMaxService
    let zhipuService: ZhipuService
    let qwenService: QwenService
    let moonshotService: MoonshotService
    let mistralService: MistralService
    let siliconFlowService: SiliconFlowService
    private let providerSession: URLSession

    unowned private(set) var appState: AppState!
    private var relayCatalogRefreshTokens: [UUID: UUID] = [:]


    init(session: URLSession = .shared) {
        providerSession = session
        openRouterService = OpenRouterService(session: session)
        openAIService = OpenAIService(session: session)
        deepSeekService = DeepSeekService(session: session)
        grokService = GrokService(session: session)
        geminiService = GeminiService(session: session)
        anthropicService = AnthropicService(session: session)
        groqService = GroqService(session: session)
        togetherService = TogetherService(session: session)
        fireworksService = FireworksService(session: session)
        miniMaxService = MiniMaxService(session: session)
        zhipuService = ZhipuService(session: session)
        qwenService = QwenService(session: session)
        moonshotService = MoonshotService(session: session)
        mistralService = MistralService(session: session)
        siliconFlowService = SiliconFlowService(session: session)
    }

    func bind(to appState: AppState) {
        self.appState = appState
    }


    func service(for kind: ProviderKind) -> (any ProviderServiceProtocol)? {
        switch kind {
        case .openRouter: return openRouterService
        case .openAI: return openAIService
        case .deepseek: return deepSeekService
        case .grok: return grokService
        case .anthropic: return anthropicService
        case .gemini: return geminiService
        case .groq: return groqService
        case .together: return togetherService
        case .fireworks: return fireworksService
        case .miniMax: return miniMaxService
        case .zhipu: return zhipuService
        case .qwen: return qwenService
        case .moonshot: return moonshotService
        case .mistral: return mistralService
        case .siliconFlow: return siliconFlowService
        case .relay: return openAIService
        }
    }


    private var providers: [Provider] {
        get { appState.providers }
        set { appState.providers = newValue }
    }

    func provider(for id: UUID) -> Provider? {
        providers.first(where: { $0.id == id })
    }


    func registerRelay(
        name: String,
        endpoint: String,
        apiKey: String,
        relayRequested: RelayRequestedConfig? = nil,
        catalogModelIDs: [String] = [],
        preferredModelID: String? = nil,
        runtimeMetadata: [String: LocalModelRuntimeMetadata] = [:],
        connectionState: ProviderConnectionState = .connected
    ) -> Provider {
        let resolvedName = uniqueProviderInstanceName(
            desiredName: name,
            kind: .relay,
            fallbackName: relayDomainName(from: endpoint) ?? ProviderKind.relay.displayName
        )
        let uniqueModelIDs = catalogModelIDs.reduce(into: [String]()) { result, modelID in
            let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !result.contains(trimmed) else { return }
            result.append(trimmed)
        }
        let preferred = preferredModelID.flatMap { preferred in
            uniqueModelIDs.first(where: { $0 == preferred })
        } ?? uniqueModelIDs.first
        let catalogModels = uniqueModelIDs.map { modelID in
            let runtime = runtimeMetadata[modelID]
            return AIModel(
                id: modelID,
                name: ModelResolver.displayName(forManualModelID: modelID, providerKind: .relay),
                capabilities: [.text],
                reasoningModeAvailable: false,
                isAvailable: true,
                isDefault: modelID == preferred,
                priceTier: "",
                summary: L10n.tr("Discovered from relay catalog", table: .providers),
                groupKey: ModelResolver.groupKey(forManualModelID: modelID, providerKind: .relay),
                groupName: ModelResolver.groupName(forManualModelID: modelID, providerKind: .relay),
                generationProfile: LocalEngineGenerationProfiles.profile(for: relayRequested?.engineProfile),
                localLoadState: runtime?.loadState,
                executionLocality: runtime?.executionLocality
            )
        }
        let provider = Provider(
            id: UUID(),
            kind: .relay,
            status: connectionState,
            models: ModelResolver.initialEnabledModels(from: catalogModels, providerKind: .relay),
            catalogModels: catalogModels,
            lastCheckedAt: nil,
            apiKey: apiKey,
            apiKeyPreview: APIKeyMask.masked(apiKey),
            lastError: {
                if case .issue(let message) = connectionState { return message }
                return nil
            }(),
            baseURLText: endpoint,
            customName: resolvedName,
            relayRequested: relayRequested
        )
        upsertProvider(provider)
        return provider
    }

    func registerProvider(
        kind: ProviderKind,
        apiKey: String,
        manualModelID: String? = nil,
        baseURLText: String? = nil,
        customName: String? = nil,
        isAdditionalInstance: Bool = false,
        authMode: ProviderAuthMode = .apiKey,
        subscriptionAccountID: String? = nil
    ) async throws -> Provider {
        let existingProvider: Provider? = nil
        let existingID: UUID? = nil
        let setupCatalog = ProviderSetupCatalog.current()
        let trimmedBaseURLText = baseURLText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBaseURLText = (trimmedBaseURLText?.isEmpty == false)
            ? trimmedBaseURLText
            : (kind == .relay ? nil : setupCatalog.defaultBaseURLText(for: kind))

        let provider: Provider
        if manualModelID == nil, let svc = service(for: kind) {
            if kind == .relay {
                let syncResult = try await svc.syncProvider(
                    apiKey: apiKey,
                    preferredModelID: existingProvider?.defaultModel?.id,
                    baseURL: effectiveBaseURLText
                )
                provider = buildProviderFromSync(
                    syncResult: syncResult,
                    kind: kind,
                    apiKey: apiKey,
                    existingID: existingID,
                    existingProvider: existingProvider,
                    baseURLText: effectiveBaseURLText ?? setupCatalog.defaultBaseURLText(for: kind),
                    customName: uniqueProviderInstanceName(
                        desiredName: customName ?? "",
                        kind: kind,
                        fallbackName: relayDomainName(from: effectiveBaseURLText ?? "") ?? ProviderKind.relay.displayName
                    )
                )
            } else {
                await MetadataClient.shared.forceRefresh()
                let officialID: UUID? = isAdditionalInstance
                    ? nil
                    : DeterministicProviderID.make(
                        kind: kind,
                        regionID: DeterministicProviderID.regionID(
                            for: kind,
                            baseURLText: effectiveBaseURLText,
                            setupCatalog: setupCatalog
                        )
                    )
                var officialProvider = buildOfficialProviderFromMetadata(
                    kind: kind,
                    apiKey: apiKey,
                    existingID: officialID,
                    existingProvider: existingProvider,
                    baseURLText: effectiveBaseURLText ?? setupCatalog.defaultBaseURLText(for: kind),
                    customName: customName.map {
                        uniqueProviderInstanceName(desiredName: $0, kind: kind, fallbackName: kind.displayName)
                    } ?? makeDefaultProviderInstanceName(for: kind)
                )
                officialProvider.authMode = authMode
                if authMode == .subscription {
                    officialProvider.status = .connected
                    officialProvider.lastCheckedAt = Date()
                    if kind == .openAI {
                        await applyOpenAISubscriptionCatalog(
                            to: &officialProvider,
                            accessToken: apiKey,
                            accountID: subscriptionAccountID
                        )
                    } else {
                        await applyGrokSubscriptionCatalog(to: &officialProvider, accessToken: apiKey)
                    }
                } else {
                    let validation = await ProviderKeyValidator.validate(
                        provider: officialProvider,
                        apiKey: apiKey,
                        session: providerSession
                    )
                    applyValidationOutcome(validation, to: &officialProvider)
                }
                provider = officialProvider
            }
        } else {
            provider = SampleData.makeProvider(
                kind: kind,
                apiKey: apiKey,
                existingID: existingID,
                manualModelID: manualModelID
            )
        }

        let normalizedProvider = ModelResolver.synchronizeDefaultSelection(
            in: provider,
            preferredModelID: provider.defaultModel?.id
        )

        guard upsertProvider(normalizedProvider) else {
            throw ProviderServiceError.invalidConfiguration(
                detail: "Could not safely persist the provider. Please retry."
            )
        }
        return normalizedProvider
    }

    private static func fetchingWithTransientRetry<T>(
        attempts: Int = 3,
        delay: Duration = .milliseconds(600),
        _ operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0..<max(1, attempts) {
            do {
                return try await operation()
            } catch {
                lastError = error
                let isTransient = (error as? OpenAISubscriptionError).map { if case .transport = $0 { true } else { false } }
                    ?? (error as? GrokSubscriptionError).map { if case .transport = $0 { true } else { false } }
                    ?? false
                guard isTransient, attempt < attempts - 1 else { throw error }
                try? await Task.sleep(for: delay)
            }
        }
        throw lastError ?? OpenAISubscriptionError.transport("retry exhausted")
    }

    private func applyGrokSubscriptionCatalog(to provider: inout Provider, accessToken: String) async {
        ToolCallMemoryStore.shared.clear(connectionID: provider.id)
        await MetadataClient.shared.refreshModelFacts()
        guard case let .available(config) = MetadataClient.shared.syncGrokSubscriptionAvailability() else {
            provider.catalogModels = []
            provider.models = []
            provider.lastError = ProviderIssueMessage.catalogUnavailableKey
            return
        }

        let descriptors: [GrokModelDescriptor]
        do {
            descriptors = try await Self.fetchingWithTransientRetry {
                try await GrokSubscriptionOAuthClient(session: providerSession)
                    .fetchModels(config: config, accessToken: accessToken)
            }
        } catch {
            AppLog.error(error, module: "ProviderCatalog", context: ["provider": "grok", "op": "fetchModels"])
            provider.catalogModels = []
            provider.models = []
            provider.lastError = (error as? GrokSubscriptionError)?.userFacingMessage
                ?? ProviderIssueMessage.catalogUnavailableKey
            return
        }

        guard !descriptors.isEmpty else {
            provider.catalogModels = []
            provider.models = []
            return
        }

        let preferred = descriptors.first?.id
        let models = descriptors.map { descriptor in
            var capabilities: [ModelCapability] = [.text]
            if descriptor.supportsWebSearch { capabilities.append(.web) }
            if descriptor.supportsReasoning { capabilities.append(.reasoning) }
            return AIModel(
                id: descriptor.id,
                name: descriptor.displayName?.isEmpty == false
                    ? descriptor.displayName!
                    : ModelResolver.displayName(forManualModelID: descriptor.id, providerKind: .grok),
                capabilities: capabilities,
                reasoningModeAvailable: descriptor.supportsReasoning,
                isAvailable: true,
                isDefault: descriptor.id == preferred,
                priceTier: "",
                summary: L10n.tr("Included in your Grok subscription", table: .providers),
                groupKey: ModelResolver.groupKey(forManualModelID: descriptor.id, providerKind: .grok),
                groupName: ModelResolver.groupName(forManualModelID: descriptor.id, providerKind: .grok)
            )
        }
        .enumerated().map { index, model -> AIModel in
            var enriched = model
            enriched.upstreamReasoningLevels = descriptors[index].reasoningEfforts
            enriched.upstreamDefaultReasoningLevel = descriptors[index].defaultReasoningEffort
            enriched.upstreamAPIBackend = descriptors[index].apiBackend
            return enriched
        }
        provider.catalogModels = models
        provider.models = models
        provider.cachedAvailableModelCount = models.count
        provider.lastError = nil
    }

    private func applyOpenAISubscriptionCatalog(
        to provider: inout Provider,
        accessToken: String,
        accountID: String?
    ) async {
        ToolCallMemoryStore.shared.clear(connectionID: provider.id)
        await MetadataClient.shared.refreshModelFacts()
        guard case let .available(config) = MetadataClient.shared.syncOpenAISubscriptionAvailability() else {
            AppLog.warning(
                "The subscription configuration is unavailable, skipping the catalog fetch",
                module: "ProviderCatalog",
                context: ["provider": "openai"]
            )
            provider.catalogModels = []
            provider.models = []
            provider.lastError = ProviderIssueMessage.catalogUnavailableKey
            return
        }
        let passedIn = accountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fromToken = OpenAIJWTClaims.string(accessToken, claim: "chatgpt_account_id") ?? ""
        let resolvedAccountID = passedIn.isEmpty ? fromToken : passedIn
        guard !resolvedAccountID.isEmpty else {
            AppLog.warning(
                "No account id available: the caller passed none and the token carries no such claim",
                module: "ProviderCatalog",
                context: ["provider": "openai"]
            )
            provider.catalogModels = []
            provider.models = []
            provider.lastError = ProviderIssueMessage.catalogUnavailableKey
            return
        }

        let descriptors: [CodexModelDescriptor]
        do {
            descriptors = try await Self.fetchingWithTransientRetry {
                try await OpenAISubscriptionOAuthClient(session: providerSession)
                    .fetchModels(config: config, accessToken: accessToken, accountID: resolvedAccountID)
            }
        } catch {
            AppLog.error(error, module: "ProviderCatalog", context: ["provider": "openai", "op": "fetchModels"])
            provider.catalogModels = []
            provider.models = []
            provider.lastError = (error as? OpenAISubscriptionError)?.userFacingMessage
                ?? ProviderIssueMessage.catalogUnavailableKey
            return
        }

        guard !descriptors.isEmpty else {
            provider.catalogModels = []
            provider.models = []
            return
        }

        let preferred = descriptors.first?.slug
        let models = descriptors.map { descriptor in
            var capabilities: [ModelCapability] = [.text]
            if descriptor.supportsWebSearch { capabilities.append(.web) }
            if descriptor.supportsReasoning { capabilities.append(.reasoning) }
            if descriptor.supportsImageInput { capabilities.append(.image) }
            return AIModel(
                id: descriptor.slug,
                name: descriptor.displayName?.isEmpty == false
                    ? descriptor.displayName!
                    : ModelResolver.displayName(forManualModelID: descriptor.slug, providerKind: .openAI),
                capabilities: capabilities,
                reasoningModeAvailable: descriptor.supportsReasoning,
                isAvailable: true,
                isDefault: descriptor.slug == preferred,
                priceTier: "",
                summary: L10n.tr("Included in your ChatGPT subscription", table: .providers),
                groupKey: ModelResolver.groupKey(forManualModelID: descriptor.slug, providerKind: .openAI),
                groupName: ModelResolver.groupName(forManualModelID: descriptor.slug, providerKind: .openAI)
            )
        }
        .enumerated().map { index, model -> AIModel in
            var enriched = model
            enriched.upstreamReasoningLevels = descriptors[index].supportedReasoningLevels
            return enriched
        }
        provider.catalogModels = models
        provider.models = models
        provider.cachedAvailableModelCount = models.count
        provider.lastError = nil
    }

    private func makeDefaultProviderInstanceName(for kind: ProviderKind) -> String? {
        return uniqueProviderInstanceName(desiredName: kind.displayName, kind: kind, fallbackName: kind.displayName)
    }

    func updateProviderName(providerID: UUID, newName: String) {
        guard var provider = provider(for: providerID) else { return }
        provider.customName = normalizedProviderName(desiredName: newName, for: provider)
        updateProvider(provider)
    }

    func normalizedProviderName(desiredName: String, for provider: Provider) -> String {
        uniqueProviderInstanceName(
            desiredName: desiredName,
            kind: provider.kind,
            excludingID: provider.id,
            fallbackName: provider.kind == .relay
                ? (relayDomainName(from: provider.baseURLText ?? "") ?? ProviderKind.relay.displayName)
                : provider.kind.displayName
        )
    }

    func uniqueProviderInstanceName(
        desiredName: String,
        kind: ProviderKind,
        excludingID: UUID? = nil,
        fallbackName: String
    ) -> String {
        let baseName = desiredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallbackName
            : desiredName.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingNames = Set(
            providers
                .filter { $0.kind == kind && $0.id != excludingID }
                .map { provider in
                    let trimmed = provider.customName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (trimmed?.isEmpty == false ? trimmed : nil) ?? provider.kind.displayName
                }
                .map(normalizeProviderName)
        )

        guard existingNames.contains(normalizeProviderName(baseName)) else { return baseName }

        let suffixBaseName = removingNumericSuffix(from: baseName)
        var suffix = 2
        while existingNames.contains(normalizeProviderName("\(suffixBaseName) \(suffix)")) {
            suffix += 1
        }
        return "\(suffixBaseName) \(suffix)"
    }

    private func normalizeProviderName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private func removingNumericSuffix(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: #" \d+$"#, options: .regularExpression) else {
            return trimmed
        }
        return String(trimmed[..<range.lowerBound])
    }

    private func relayDomainName(from endpoint: String) -> String? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+\-.]*://"#, options: .regularExpression) == nil
            ? "https://\(trimmed)"
            : trimmed
        guard let host = URL(string: candidate)?.host?.lowercased(), !host.isEmpty else { return nil }
        if host == "localhost" || host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil || host.contains(":") {
            return host
        }
        let parts = host.split(separator: ".")
        guard parts.count > 2 else { return host }
        return parts.suffix(2).joined(separator: ".")
    }

    private func buildOfficialProviderFromMetadata(
        kind: ProviderKind,
        apiKey: String,
        existingID: UUID?,
        existingProvider: Provider?,
        baseURLText: String?,
        customName: String?
    ) -> Provider {
        var provider = Provider(
            id: existingID ?? UUID(),
            kind: kind,
            status: .connected,
            models: existingProvider?.models ?? [],
            catalogModels: [],
            lastCheckedAt: Date(),
            apiKey: apiKey,
            apiKeyPreview: APIKeyMask.masked(apiKey),
            lastError: nil,
            baseURLText: baseURLText,
            customName: customName
        )

        let resolvedCatalog = ProviderCatalogResolver.resolve(provider: provider)
        let catalogModels = resolvedCatalog.catalog.map(\.model)

        if (existingProvider?.models ?? []).isEmpty {
            provider.models = ModelResolver.initialEnabledModels(
                from: catalogModels,
                providerKind: kind
            )
        } else {
            provider.models = ModelResolver.makeEnabledModels(
                from: existingProvider?.models ?? [],
                catalogModels: catalogModels,
                providerKind: kind,
                legacyCatalogModels: existingProvider?.catalogModels ?? [],
                repairLegacyAutoEnabledAll: true
            )
        }

        provider.models = ManualRetainedPruningPolicy.apply(
            provider: provider,
            resolvedCatalog: ProviderCatalogResolver.resolve(provider: provider)
        )
        ManualRetainedPruningPolicy.recordActivation(
            provider: provider,
            count: resolvedCatalog.enabledModels.filter(\.isManual).count
        )

        return provider
    }


    func resyncProvider(
        providerID: UUID,
        commitGuard: @escaping @MainActor () -> Bool = { true },
        failClosed: Bool = false
    ) async throws {
        try Task.checkCancellation()
        guard commitGuard() else { throw CancellationError() }
        guard var provider = provider(for: providerID) else { return }

        provider.status = .syncing
        provider.lastError = nil
        updateProvider(provider)

        do {
            if provider.kind == .relay {
                await MetadataClient.shared.forceRefresh()
                try Task.checkCancellation()
                guard commitGuard() else { throw CancellationError() }
                if let svc = service(for: provider.kind) {
                    let syncResult = try await svc.syncProvider(
                        apiKey: provider.apiKey,
                        preferredModelID: provider.defaultModel?.id,
                        baseURL: ProviderSetupCatalog.current().usesConfigurableBaseURL(provider.kind)
                    ? provider.baseURLText
                    : nil,
                        relayRequested: provider.relayRequested
                    )
                    try Task.checkCancellation()
                    guard commitGuard() else { throw CancellationError() }
                    applyRelaySyncResult(syncResult, to: &provider)
                }
            } else if provider.authMode == .subscription {
                await MetadataClient.shared.forceRefresh()
                try Task.checkCancellation()
                guard commitGuard() else { throw CancellationError() }
                if provider.kind == .openAI {
                    switch await OpenAISubscriptionRuntime.prepare(providerID: providerID) {
                    case let .success(prepared):
                        await applyOpenAISubscriptionCatalog(
                            to: &provider,
                            accessToken: prepared.accessToken,
                            accountID: prepared.context.accountID
                        )
                    case let .failure(error):
                        provider.status = .issue(error.userFacingMessage)
                        provider.lastError = error.userFacingMessage
                        updateProvider(provider)
                        return
                    }
                } else {
                    switch await GrokSubscriptionRuntime.prepare(providerID: providerID) {
                    case let .success(prepared):
                        await applyGrokSubscriptionCatalog(to: &provider, accessToken: prepared.accessToken)
                    case let .failure(error):
                        provider.status = .issue(error.userFacingMessage)
                        provider.lastError = error.userFacingMessage
                        updateProvider(provider)
                        return
                    }
                }
            } else {
                await MetadataClient.shared.forceRefresh()
                try Task.checkCancellation()
                guard commitGuard() else { throw CancellationError() }
                let resolvedCatalog = ProviderCatalogResolver.resolve(provider: provider)
                provider.models = ModelResolver.makeEnabledModels(
                    from: provider.models,
                    catalogModels: resolvedCatalog.catalog.map(\.model),
                    providerKind: provider.kind,
                    legacyCatalogModels: provider.catalogModels,
                    repairLegacyAutoEnabledAll: true
                )
                provider.catalogModels = []

                let postResolveCatalog = ProviderCatalogResolver.resolve(provider: provider)
                provider.models = ManualRetainedPruningPolicy.apply(
                    provider: provider,
                    resolvedCatalog: postResolveCatalog
                )
                ManualRetainedPruningPolicy.recordActivation(
                    provider: provider,
                    count: postResolveCatalog.enabledModels.filter(\.isManual).count
                )

                provider = ModelResolver.synchronizeDefaultSelection(
                    in: provider,
                    preferredModelID: provider.models.first(where: \.isDefault)?.id
                        ?? provider.catalogModels.first(where: \.isDefault)?.id
                )

                let validation = await ProviderKeyValidator.validate(
                    provider: provider,
                    apiKey: provider.apiKey,
                    session: providerSession
                )
                try Task.checkCancellation()
                guard commitGuard() else { throw CancellationError() }
                applyValidationOutcome(validation, to: &provider)
                updateProvider(provider)
                if case .invalid = validation {
                    throw ProviderServiceError.invalidAPIKey(
                        detail: "Provider key validation returned an invalid-key signal."
                    )
                }
                return
            }

            provider = ModelResolver.synchronizeDefaultSelection(
                in: provider,
                preferredModelID: provider.models.first(where: \.isDefault)?.id
                    ?? provider.catalogModels.first(where: \.isDefault)?.id
            )
            provider.status = .connected
            provider.lastCheckedAt = Date()
            provider.lastError = nil
            try Task.checkCancellation()
            guard commitGuard() else { throw CancellationError() }
            updateProvider(provider)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let providerError = providerServiceError(from: error)
            let preserve = !failClosed && shouldKeepProviderAvailableAfterSyncFailure(providerError, provider: provider)
            if preserve {
                provider.status = .connected
            } else {
                provider.status = .issue(providerError.messageKey)
                provider.lastError = providerError.messageKey
            }
            guard commitGuard() else { throw CancellationError() }
            updateProvider(provider)
            throw providerError
        }
    }


    private func buildProviderFromSync(
        syncResult: ProviderSyncResult,
        kind: ProviderKind,
        apiKey: String,
        existingID: UUID?,
        existingProvider: Provider?,
        baseURLText: String?,
        customName: String?
    ) -> Provider {
        if kind == .relay {
            let catalogModels = ModelResolver.mergeManualModels(from: existingProvider?.allModels ?? [], into: syncResult.models, providerKind: kind)
            let enabledModels = ModelResolver.makeEnabledModels(from: existingProvider?.models ?? [], catalogModels: catalogModels, providerKind: kind)
            return Provider(id: existingID ?? UUID(), kind: kind, status: .connected, models: enabledModels, catalogModels: catalogModels, lastCheckedAt: Date(), apiKey: apiKey, apiKeyPreview: APIKeyMask.masked(apiKey), lastError: nil, baseURLText: baseURLText, customName: customName ?? existingProvider?.customName)
        }
        let enabledModels = ModelResolver.makeEnabledModels(from: existingProvider?.models ?? [], catalogModels: syncResult.models, providerKind: kind)
        return Provider(id: existingID ?? UUID(), kind: kind, status: .connected, models: enabledModels, catalogModels: [], lastCheckedAt: Date(), apiKey: apiKey, apiKeyPreview: APIKeyMask.masked(apiKey), lastError: nil, baseURLText: baseURLText)
    }

    /// Applies the actual service `ProviderSyncResult` without allowing relay
    /// catalog membership to revoke previously enabled sendable models.
    func applyRelaySyncResult(_ syncResult: ProviderSyncResult, to provider: inout Provider) {
        ToolCallMemoryStore.shared.clear(connectionID: provider.id)
        provider.catalogModels = ModelResolver.mergeManualModels(
            from: provider.allModels,
            into: syncResult.models,
            providerKind: provider.kind
        )
        let refreshedEnabled = ModelResolver.makeEnabledModels(
            from: provider.models,
            catalogModels: provider.catalogModels,
            providerKind: provider.kind
        )
        // A third-party catalog is discovery evidence, not an authorization list.
        // Keep previously enabled remote models that disappeared from `/models`;
        // their row is annotated from membership in `catalogModels`, while their
        // `isAvailable` value keeps its actual sendability semantics.
        let retained = provider.models.filter { enabled in
            !refreshedEnabled.contains {
                ModelResolver.modelsShareSameRemoteModel($0, enabled, providerKind: provider.kind)
            }
        }
        provider.models = refreshedEnabled + retained
    }


    func updateAPIKey(providerID: UUID, newKey: String) async throws {
        guard let originalProvider = provider(for: providerID) else { return }

        var updatedProvider = originalProvider
        updatedProvider.apiKey = newKey
        updatedProvider.apiKeyPreview = APIKeyMask.masked(newKey)

        if originalProvider.kind == .relay {
            updatedProvider.status = .issue(ProviderIssueMessage.unverifiedConnectionKey)
            updatedProvider.lastCheckedAt = nil
            updatedProvider.lastError = ProviderIssueMessage.unverifiedConnectionKey
            updatedProvider.catalogModels = []
            updateProvider(updatedProvider)
            guard !newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do {
                try await reverifyRelayProvider(providerID: providerID, refreshCatalog: true)
            } catch {
                recordRelayGenerationVerification(providerID: providerID, verified: false, error: error)
                throw providerServiceError(from: error)
            }
            return
        }

        updateProvider(updatedProvider)

        do {
            try await resyncProvider(providerID: providerID)
        } catch {
            updateProvider(originalProvider)
            throw error
        }
    }

    func verifyRelayGeneration(_ provider: Provider) async throws {
        guard provider.kind == .relay else { return }
        let requested = provider.relayRequested ?? RelayRequestedConfig()
        let modelID = requested.modelID
            ?? provider.defaultModel?.id
            ?? provider.models.first?.id
            ?? provider.catalogModels.first?.id
        guard let modelID, !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderServiceError.invalidConfiguration(detail: "A model is required for generation verification.")
        }
        guard let endpoint = provider.baseURLText, !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderServiceError.invalidConfiguration(detail: "A request URL is required for generation verification.")
        }
        _ = try await openAIService.pingRelay(
            apiKey: provider.apiKey,
            baseURL: endpoint,
            modelID: modelID,
            relayRequested: requested
        )
    }

    func reverifyRelayProvider(
        providerID: UUID,
        refreshCatalog: Bool = false,
        commitGuard: @escaping @MainActor () -> Bool = { true }
    ) async throws {
        guard let provider = provider(for: providerID), provider.kind == .relay else { return }
        let connectionIdentity = RelayCatalogConnectionIdentity(provider: provider)
        try await verifyRelayGeneration(provider)
        guard commitGuard(),
              RelayGenerationVerificationWritePolicy.mayCommit(
                  current: self.provider(for: providerID),
                  connectionIdentity: connectionIdentity
              ) else { throw CancellationError() }
        recordRelayGenerationVerification(providerID: providerID, verified: true)
        if refreshCatalog {
            _ = await refreshRelayCatalog(providerID: providerID, commitGuard: commitGuard)
        }
    }

    @discardableResult
    func refreshRelayCatalog(
        providerID: UUID,
        commitGuard: @escaping @MainActor () -> Bool = { true }
    ) async -> Bool {
        guard let provider = provider(for: providerID), provider.kind == .relay else { return false }
        let connectionIdentity = RelayCatalogConnectionIdentity(provider: provider)
        let token = UUID()
        relayCatalogRefreshTokens[providerID] = token
        appState.relayCatalogRefreshingProviderIDs.insert(providerID)

        func releaseToken() {
            if relayCatalogRefreshTokens[providerID] == token {
                relayCatalogRefreshTokens.removeValue(forKey: providerID)
                appState.relayCatalogRefreshingProviderIDs.remove(providerID)
            }
        }

        func ownedCurrentProvider() -> Provider? {
            guard let current = self.provider(for: providerID),
                  RelayCatalogRefreshWritePolicy.mayFinish(
                      requestToken: token,
                      activeToken: relayCatalogRefreshTokens[providerID],
                      current: current,
                      connectionIdentity: connectionIdentity
                  ) else {
                releaseToken()
                return nil
            }
            return current
        }

        func finishCatalogFailure() {
            guard var current = ownedCurrentProvider() else { return }
            current.lastError = ProviderIssueMessage.catalogUnavailableKey
            updateProvider(current)
            releaseToken()
        }

        do {
            await MetadataClient.shared.forceRefresh()
            try Task.checkCancellation()
            guard commitGuard() else {
                releaseToken()
                return false
            }
            guard let service = service(for: provider.kind) else {
                finishCatalogFailure()
                return false
            }
            let syncResult = try await service.syncProvider(
                apiKey: provider.apiKey,
                preferredModelID: provider.defaultModel?.id,
                baseURL: ProviderSetupCatalog.current().usesConfigurableBaseURL(provider.kind)
                    ? provider.baseURLText
                    : nil,
                relayRequested: provider.relayRequested
            )
            try Task.checkCancellation()
            guard commitGuard(), var current = ownedCurrentProvider() else {
                releaseToken()
                return false
            }
            let latestDefaultModelID = current.relayRequested?.modelID ?? current.defaultModel?.id
            applyRelaySyncResult(syncResult, to: &current)
            current = ModelResolver.synchronizeDefaultSelection(
                in: current,
                preferredModelID: latestDefaultModelID
            )
            // A directory response is never a substitute for a generation probe.
            // It only clears its own catalog error; connection status/time stay intact.
            if current.lastError == ProviderIssueMessage.catalogUnavailableKey {
                current.lastError = nil
            }
            updateProvider(current)
            releaseToken()
            return true
        } catch is CancellationError {
            releaseToken()
            return false
        } catch {
            finishCatalogFailure()
            return false
        }
    }

    func recordRelayGenerationVerification(providerID: UUID, verified: Bool, error: Error? = nil) {
        guard var provider = provider(for: providerID), provider.kind == .relay else { return }
        if verified {
            provider.status = .connected
            provider.lastCheckedAt = Date()
            provider.lastError = nil
        } else {
            let message = error.map { providerServiceError(from: $0).messageKey }
                ?? ProviderIssueMessage.unverifiedConnectionKey
            provider.status = .issue(message)
            provider.lastError = message
        }
        updateProvider(provider)
    }

    func removeStoredRelayCredential(providerID: UUID) {
        guard var provider = provider(for: providerID),
              provider.kind == .relay,
              !RelayCredentialPolicy.requiresCredential(provider.relayRequested) else { return }
        provider.apiKey = ""
        provider.apiKeyPreview = APIKeyMask.masked("")
        updateProvider(provider)
    }

    func updateBaseURL(providerID: UUID, baseURLText: String?) async throws {
        guard var provider = provider(for: providerID) else { return }
        let setupCatalog = ProviderSetupCatalog.current()
        guard setupCatalog.usesConfigurableBaseURL(provider.kind) else { return }
        let trimmedBaseURLText = baseURLText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBaseURLText = (trimmedBaseURLText?.isEmpty == false)
            ? trimmedBaseURLText
            : nil

        provider.baseURLText = effectiveBaseURLText ?? setupCatalog.defaultBaseURLText(for: provider.kind)

        updateProvider(provider)
        try await resyncProvider(providerID: providerID)
    }

    func setDefaultModel(modelID: String, for providerID: UUID) {
        guard var provider = provider(for: providerID),
              let resolvedModel = ModelResolver.matchingModel(for: modelID, in: provider) else {
            return
        }

        if !provider.models.contains(where: { ModelResolver.modelsShareSameRemoteModel($0, resolvedModel, providerKind: provider.kind) }) {
            provider.models.append(resolvedModel)
        }

        provider = ModelResolver.synchronizeDefaultSelection(in: provider, preferredModelID: resolvedModel.id)
        updateProvider(provider)
    }

    @discardableResult
    func ensureModelEnabledAsDefault(providerID: UUID, modelID: String) -> Bool {
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelID.isEmpty, let provider = provider(for: providerID) else {
            return false
        }

        if ModelResolver.matchingModel(for: trimmedModelID, in: provider) != nil {
            setDefaultModel(modelID: trimmedModelID, for: providerID)
            return true
        }

        return saveManualModelData(providerID: providerID, modelID: trimmedModelID)
    }

    static func applyingRelayDefaultModelSelection(
        to provider: Provider,
        modelID: String
    ) -> Provider {
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider.kind == .relay, !trimmedModelID.isEmpty else { return provider }

        var candidate = provider
        let selectedModel: AIModel
        if let resolved = ModelResolver.matchingModel(for: trimmedModelID, in: candidate) {
            selectedModel = resolved
        } else {
            selectedModel = AIModel(
                id: trimmedModelID,
                name: ModelResolver.displayName(forManualModelID: trimmedModelID, providerKind: .relay),
                capabilities: [.text],
                reasoningModeAvailable: false,
                isAvailable: true,
                isDefault: false,
                priceTier: "",
                summary: nil,
                groupKey: ModelResolver.groupKey(forManualModelID: trimmedModelID, providerKind: .relay),
                groupName: ModelResolver.groupName(forManualModelID: trimmedModelID, providerKind: .relay),
                isManual: true
            )
            candidate.catalogModels.insert(selectedModel, at: 0)
        }

        if !candidate.models.contains(where: {
            ModelResolver.modelsShareSameRemoteModel($0, selectedModel, providerKind: .relay)
        }) {
            candidate.models.insert(selectedModel, at: 0)
        }
        return ModelResolver.synchronizeDefaultSelection(in: candidate, preferredModelID: selectedModel.id)
    }

    func enableModel(modelID: String, for providerID: UUID) {
        guard var provider = provider(for: providerID),
              let resolvedModel = ModelResolver.matchingModel(for: modelID, in: provider) else {
            return
        }

        if provider.models.contains(where: { ModelResolver.modelsShareSameRemoteModel($0, resolvedModel, providerKind: provider.kind) }) {
            return
        }

        var enabledModel = resolvedModel
        enabledModel.isDefault = provider.models.isEmpty
        provider.models.append(enabledModel)
        provider = ModelResolver.synchronizeDefaultSelection(
            in: provider,
            preferredModelID: provider.defaultModel?.id ?? enabledModel.id
        )
        updateProvider(provider)
    }

    func disableModel(modelID: String, for providerID: UUID) {
        guard var provider = provider(for: providerID), provider.models.count > 1 else { return }

        guard let removedModel = ModelResolver.matchingModel(for: modelID, in: provider) else { return }
        let preferredDefaultID = provider.models.first(where: { $0.id != removedModel.id && $0.isDefault })?.id
            ?? provider.models.first(where: { $0.id != removedModel.id })?.id

        provider.models.removeAll(where: { ModelResolver.modelsShareSameRemoteModel($0, removedModel, providerKind: provider.kind) })
        provider = ModelResolver.synchronizeDefaultSelection(in: provider, preferredModelID: preferredDefaultID)
        updateProvider(provider)
    }

    @discardableResult
    func saveManualModelData(
        providerID: UUID,
        modelID: String,
        capabilities: Set<ModelCapability>? = nil
    ) -> Bool {
        guard var provider = provider(for: providerID) else { return false }

        var mergedCaps = capabilities ?? Self.defaultManualModelCapabilities(for: provider.kind)
        mergedCaps.insert(.text)
        let orderedCaps = mergedCaps.sorted { $0.rawValue < $1.rawValue }
        let manualModel = AIModel(
            id: modelID,
            name: ModelResolver.displayName(forManualModelID: modelID, providerKind: provider.kind),
            capabilities: orderedCaps,
            reasoningModeAvailable: mergedCaps.contains(.reasoning),
            isAvailable: true,
            isDefault: provider.models.isEmpty,
            priceTier: "",
            summary: provider.kind == .relay
                ? L10n.tr("Manual model")
                : L10n.tr("Manual fallback model"),
            groupKey: ModelResolver.groupKey(forManualModelID: modelID, providerKind: provider.kind),
            groupName: ModelResolver.groupName(forManualModelID: modelID, providerKind: provider.kind),
            imageGenProfile: mergedCaps.contains(.imageGen) ? "default" : nil,
            isManual: true
        )

        if let existingIndex = provider.models.firstIndex(where: { ModelResolver.modelsShareSameRemoteModel($0, manualModel, providerKind: provider.kind) }) {
            for index in provider.models.indices {
                provider.models[index].isDefault = index == existingIndex
            }
        } else {
            provider.models.insert(manualModel, at: 0)
            for index in provider.models.indices {
                provider.models[index].isDefault = index == 0
            }
        }

        if !provider.models.contains(where: \.isDefault), !provider.models.isEmpty {
            provider.models[0].isDefault = true
        }

        if let existingCatalogIndex = provider.catalogModels.firstIndex(where: { ModelResolver.modelsShareSameRemoteModel($0, manualModel, providerKind: provider.kind) }) {
            provider.catalogModels[existingCatalogIndex] = manualModel
        } else {
            provider.catalogModels.insert(manualModel, at: 0)
        }

        let normalizedProvider = ModelResolver.synchronizeDefaultSelection(
            in: provider,
            preferredModelID: provider.models.first(where: \.isDefault)?.id
        )
        updateProvider(normalizedProvider)
        return true
    }

    @discardableResult
    func removeProvider(_ providerID: UUID) -> Bool {
        guard providers.contains(where: { $0.id == providerID }) else { return false }
        let existingCount = providers.count
        providers.removeAll(where: { $0.id == providerID })
        guard providers.count != existingCount else { return false }
        ProviderCapabilityIdentityStore.tombstone(providerID: providerID, partitionID: appState.sessionPartitionUID)
        ToolCallMemoryStore.shared.clear(connectionID: providerID)
        ProviderAPIKeyStore.delete(providerID: providerID, uid: appState.sessionPartitionUID)
        return true
    }


    @discardableResult
    func upsertProvider(_ provider: Provider) -> Bool {
        var p = provider
        if let existing = providers.first(where: { $0.id == p.id }) {
            advanceCapabilityIdentity(from: existing, to: p)
        } else {
            _ = ProviderCapabilityIdentityStore.identity(providerID: p.id, partitionID: appState.sessionPartitionUID)
        }
        p.updatedAt = Date()
        let resolved = ProviderCatalogResolver.resolve(provider: p)
        p.cachedAvailableModelCount = resolved.availableModelCount
        if p.kind == .relay {
            p = applyRelayEnrichment(to: p, resolved: resolved)
        }
        if let index = providers.firstIndex(where: { $0.id == p.id }) {
            providers[index] = p
        } else {
            providers.insert(p, at: 0)
        }
        normalizeConversationModelSelections(for: p)
        return true
    }

    func updateProvider(_ provider: Provider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        var p = provider
        advanceCapabilityIdentity(from: providers[index], to: p)
        if providers[index].authMode != p.authMode {
            ToolCallMemoryStore.shared.clear(connectionID: p.id)
        }
        p.updatedAt = Date()
        let resolved = ProviderCatalogResolver.resolve(provider: p)
        p.cachedAvailableModelCount = resolved.availableModelCount
        if p.kind == .relay {
            p = applyRelayEnrichment(to: p, resolved: resolved)
        }
        providers[index] = p
        normalizeConversationModelSelections(for: p)
    }

    private func advanceCapabilityIdentity(from old: Provider, to new: Provider) {
        let partitionID = appState.sessionPartitionUID
        if old.apiKey != new.apiKey {
            ProviderCapabilityIdentityStore.advanceCredentialEpoch(providerID: new.id, partitionID: partitionID)
        }
        let connectionChanged = old.kind != new.kind
            || old.baseURLText != new.baseURLText
            || old.relayRequested != new.relayRequested
        if connectionChanged {
            ProviderCapabilityIdentityStore.advanceConnectionGeneration(providerID: new.id, partitionID: partitionID)
        }
    }

    private func applyRelayEnrichment(to provider: Provider, resolved: ResolvedProviderCatalog) -> Provider {
        var p = provider
        let enrichedById = resolved.catalog.reduce(into: [String: AIModel]()) { result, entry in
            if result[entry.model.id] == nil {
                result[entry.model.id] = entry.model
            }
        }

        func merged(_ raw: AIModel) -> AIModel {
            let enriched = enrichedById[raw.id] ?? raw
            var out = raw
            out.capabilities = enriched.capabilities
            out.reasoningModeAvailable = enriched.reasoningModeAvailable
            out.reasoningProfile = enriched.reasoningProfile
            out.webSearchProfile = enriched.webSearchProfile
            out.imageGenProfile = enriched.imageGenProfile
            out.badgeOrder = enriched.badgeOrder
            if let canonical = enriched.canonicalModelId, !canonical.isEmpty {
                out.canonicalModelId = canonical
            }
            if !enriched.priceTier.isEmpty {
                out.priceTier = enriched.priceTier
            }
            out.promptPrice = enriched.promptPrice ?? out.promptPrice
            out.completionPrice = enriched.completionPrice ?? out.completionPrice
            out.billingSku = enriched.billingSku ?? out.billingSku
            out.pricingUnit = enriched.pricingUnit
            out.sourceSummary = enriched.sourceSummary ?? out.sourceSummary
            out.costPerUnit = enriched.costPerUnit ?? out.costPerUnit
            out.costInputBatches = enriched.costInputBatches ?? out.costInputBatches
            out.costOutputBatches = enriched.costOutputBatches ?? out.costOutputBatches
            out.costInputPriority = enriched.costInputPriority ?? out.costInputPriority
            out.costOutputPriority = enriched.costOutputPriority ?? out.costOutputPriority
            out.cacheReadInputPerMToken = enriched.cacheReadInputPerMToken ?? out.cacheReadInputPerMToken
            out.cacheCreationInputPerMToken = enriched.cacheCreationInputPerMToken ?? out.cacheCreationInputPerMToken
            return out
        }

        p.catalogModels = p.catalogModels.map(merged)
        p.models = p.models.map(merged)
        return p
    }

    private func normalizeConversationModelSelections(for provider: Provider) {
        guard !provider.allModels.isEmpty else { return }

        var modelUpdates: [ConversationModelUpdate] = []
        let metadataUpdatedAt = Date()
        for conversation in appState.conversations where conversation.providerID == provider.id {
            var updatedModelID = conversation.modelID
            if let resolvedModel = ModelResolver.matchingModel(for: conversation.modelID, in: provider) {
                updatedModelID = ModelResolver.preferredStoredModelIdentifier(
                    for: resolvedModel,
                    providerKind: provider.kind
                )
            } else if let defaultModel = provider.defaultModel {
                updatedModelID = ModelResolver.preferredStoredModelIdentifier(
                    for: defaultModel,
                    providerKind: provider.kind
                )
            }
            if updatedModelID != conversation.modelID {
                modelUpdates.append(
                    ConversationModelUpdate(
                        conversationID: conversation.id,
                        providerID: conversation.providerID,
                        providerKind: conversation.providerKind,
                        modelID: updatedModelID,
                        metadataUpdatedAt: metadataUpdatedAt
                    )
                )
            }
        }

        if !modelUpdates.isEmpty {
            appState.updateConversationModelProjections(modelUpdates)
        }
    }


    func applyValidationOutcome(_ result: ProviderKeyValidator.Result, to provider: inout Provider) {
        provider.lastCheckedAt = Date()
        switch result {
        case .valid:
            provider.status = .connected
            provider.lastError = nil
        case .invalid:
            let key = "The API key could not be validated. Check the value or generate a new key."
            provider.status = .issue(key)
            provider.lastError = key
        case .unverified:
            provider.status = .connected
            provider.lastError = "We couldn't verify the connection. You can retry from the provider details."
        }
    }

    static func providerStatusIsIssue(_ status: ProviderConnectionState) -> Bool {
        if case .issue = status { return true }
        return false
    }


    func providerServiceError(from error: Error) -> ProviderServiceError {
        if let providerServiceError = error as? ProviderServiceError {
            return providerServiceError
        }
        return .network(detail: error.localizedDescription)
    }

    private func shouldKeepProviderAvailableAfterSyncFailure(
        _ error: ProviderServiceError,
        provider: Provider
    ) -> Bool {
        let hasCachedModels = !provider.allModels.isEmpty || provider.lastCheckedAt != nil
        guard hasCachedModels else { return false }

        switch error {
        case .invalidAPIKey, .invalidConfiguration:
            return false
        case .quotaExceeded, .modelUnavailable,
             .rateLimited, .emptyModelCatalog, .network, .upstream, .emptyResponse:
            return true
        case let .subscriptionFailure(_, kind, _, _):
            switch kind {
            case .expired, .ineligible:
                return false
            case .unavailable, .quotaExhausted:
                return true
            }
        }
    }
}
