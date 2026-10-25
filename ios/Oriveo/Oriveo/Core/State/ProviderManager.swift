import Foundation

/// A catalog request binds only the fields of the connection that actually goes out. The display name and the default
/// model can change while the request is in flight: the former must be kept, the latter is re-synced on the latest
/// snapshot, and neither may be overwritten by a stale catalog result.
/// `relayKind` is deliberately not part of it: it is a display value derived from the default protocol at save time
/// (used for the badge) and is never read on the wire. Counting it would make the first save of an existing connection
/// that only changes a request header rewrite it and invalidate an in-flight catalog refresh.
struct RelayCatalogConnectionIdentity: Equatable {
    let endpoint: String?
    let apiKey: String
    let requestedWithoutModel: RelayRequestedConfig

    /// - modelID: a probe write-back compares the effective key of the probed model; a catalog refresh passes nil,
    ///   meaning the primary key. The identity holds key values only, not the names or states in `relayKeys`.
    init(provider: Provider, modelID: String? = nil) {
        endpoint = provider.baseURLText?.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = ProviderCredentialResolver.apiKey(provider: provider, modelID: modelID)
        var requested = provider.relayRequested ?? RelayRequestedConfig()
        requested.modelID = nil
        requestedWithoutModel = requested
    }

    /// Whether the outbound connection is the same apart from key values (a multi-key catalog refresh compares each key's value one by one).
    func sameConnection(as other: RelayCatalogConnectionIdentity) -> Bool {
        endpoint == other.endpoint && requestedWithoutModel == other.requestedWithoutModel
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

    /// The single table that picks a service by kind (`ProviderServiceRouter.Services`).
    let services: ProviderServiceRouter.Services
    var openRouterService: OpenRouterService { services.openRouter }
    var openAIService: OpenAIService { services.openAI }
    var deepSeekService: DeepSeekService { services.deepSeek }
    var grokService: GrokService { services.grok }
    var geminiService: GeminiService { services.gemini }
    var anthropicService: AnthropicService { services.anthropic }
    var groqService: GroqService { services.groq }
    var togetherService: TogetherService { services.together }
    var fireworksService: FireworksService { services.fireworks }
    var miniMaxService: MiniMaxService { services.miniMax }
    var zhipuService: ZhipuService { services.zhipu }
    var qwenService: QwenService { services.qwen }
    var moonshotService: MoonshotService { services.moonshot }
    var mistralService: MistralService { services.mistral }
    var siliconFlowService: SiliconFlowService { services.siliconFlow }
    private let providerSession: URLSession

    unowned private(set) var appState: AppState!
    private var relayCatalogRefreshTokens: [UUID: UUID] = [:]
    /// In-flight background finalize tasks for relay writes (whole-catalog resolve + official catalog enrichment);
    /// only the latest one per Provider is kept.
    private var relayFinalizeTasks: [UUID: Task<Void, Never>] = [:]
    /// In-flight lazy checks triggered by enabling a single model from the model library; each removes itself when done. Only tests wait on it.
    private var relayModelProbeTasks: [UUID: [UUID: Task<Void, Never>]] = [:]
    /// Dependencies of the automatic web-search probe; production uses the shared store and the real upstream, tests inject a fake upstream and an isolated store.
    var relayWebProbeAutoContext = RelayWebProbeAutoContext()
    /// Automatic web-search probes run as one chain: a new batch queues behind the previous one and is not cancelled with the page.
    private var relayWebProbeChain: Task<Void, Never>?


    init(session: URLSession = .shared) {
        providerSession = session
        services = ProviderServiceRouter.Services(session: session)
    }

    func bind(to appState: AppState) {
        self.appState = appState
    }


    func service(for kind: ProviderKind) -> (any ProviderServiceProtocol)? {
        services.native(for: kind)
    }


    private var providers: [Provider] {
        get { appState.providers }
        set { appState.providers = newValue }
    }

    func provider(for id: UUID) -> Provider? {
        providers.first(where: { $0.id == id })
    }


    /// The unified shape of relay catalog entries: registration and the draft catalog of the add flow's second step share
    /// it, so grouping and group order match the model library.
    static func relayCatalogModels(
        modelIDs: [String],
        relayRequested: RelayRequestedConfig?,
        runtimeMetadata: [String: LocalModelRuntimeMetadata] = [:]
    ) -> [AIModel] {
        // A discovered catalog can hold tens of thousands of models: deduplicate with a set, since checking
        // `result.contains` for each one is quadratic in the catalog size.
        var seenModelIDs = Set<String>()
        let uniqueModelIDs = modelIDs.reduce(into: [String]()) { result, modelID in
            let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seenModelIDs.insert(trimmed).inserted else { return }
            result.append(trimmed)
        }
        return uniqueModelIDs.map { modelID in
            let runtime = runtimeMetadata[modelID]
            var model = AIModel(
                id: modelID,
                name: ModelResolver.displayName(forManualModelID: modelID, providerKind: .relay),
                capabilities: [.text],
                reasoningModeAvailable: false,
                isAvailable: true,
                // A relay has no default model.
                isDefault: false,
                priceTier: "",
                summary: L10n.tr("Discovered from the model catalog", table: .providers),
                groupKey: ModelResolver.groupKey(forManualModelID: modelID, providerKind: .relay),
                groupName: ModelResolver.groupName(forManualModelID: modelID, providerKind: .relay),
                generationProfile: LocalEngineGenerationProfiles.profile(for: relayRequested?.engineProfile),
                localLoadState: runtime?.loadState,
                executionLocality: runtime?.executionLocality
            )
            model.engineDeclaration = runtime?.engineDeclaration
            return model
        }
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
            fallbackName: Self.relayDomainName(from: endpoint) ?? ProviderKind.relay.displayName
        )
        var catalogModels = Self.relayCatalogModels(
            modelIDs: catalogModelIDs,
            relayRequested: relayRequested,
            runtimeMetadata: runtimeMetadata
        )
        let uniqueModelIDs = catalogModels.map(\.id)
        // Only the verification sample is enabled (and not marked as default). If the sample is in the catalog, enable
        // that entry; if it is not (typed in by hand, or the catalog is empty), add it like a manual model; with no
        // sample, fall back to the initial enabling rule.
        let sampleModelID = preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let enabledModels: [AIModel]
        if sampleModelID.isEmpty {
            enabledModels = ModelResolver.initialEnabledModels(from: catalogModels, providerKind: .relay)
        } else if let catalogModel = catalogModels.first(where: { $0.id == sampleModelID }) {
            enabledModels = [catalogModel]
        } else {
            let manualModel = AIModel(
                id: sampleModelID,
                name: ModelResolver.displayName(forManualModelID: sampleModelID, providerKind: .relay),
                capabilities: Self.defaultManualModelCapabilities(for: .relay).sorted { $0.rawValue < $1.rawValue },
                reasoningModeAvailable: false,
                isAvailable: true,
                isDefault: false,
                priceTier: "",
                summary: L10n.tr("Manual model"),
                groupKey: ModelResolver.groupKey(forManualModelID: sampleModelID, providerKind: .relay),
                groupName: ModelResolver.groupName(forManualModelID: sampleModelID, providerKind: .relay),
                isManual: true
            )
            catalogModels.insert(manualModel, at: 0)
            enabledModels = [manualModel]
        }
        let provider = Provider(
            id: UUID(),
            kind: .relay,
            status: connectionState,
            // The whole discovered catalog goes into catalogModels (the "model library" of the provider detail page) and
            // only the verification sample is enabled. The two fields have this fixed split: the library shows
            // `catalogModels` minus the enabled ones, so enabling everything would leave the library empty and the user
            // could no longer see what their relay offers. Keeping the rest in the library also makes the picker's
            // "Add models" entry work (its condition is catalogModels.count > models.count).
            models: enabledModels,
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
        subscriptionAccountID: String? = nil,
        endpointSource: ProviderEndpointSource? = nil,
        setupValues: [String: String]? = nil
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
                        fallbackName: Self.relayDomainName(from: effectiveBaseURLText ?? "") ?? ProviderKind.relay.displayName
                    )
                )
            } else {
                // The provider being added is not configured yet, so name its catalog explicitly.
                await MetadataClient.shared.forceRefresh(providerKinds: [kind])
                let officialID: UUID? = isAdditionalInstance
                    ? nil
                    : DeterministicProviderID.make(
                        kind: kind,
                        regionID: DeterministicProviderID.regionID(
                            for: kind,
                            baseURLText: effectiveBaseURLText,
                            endpointSource: endpointSource,
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
                // The setup page's chosen source wins; every other entry point is classified by metadata. Template values stay on this device only.
                officialProvider.setupValues = setupValues
                if let endpointSource {
                    officialProvider.endpointSource = endpointSource
                } else {
                    officialProvider.classifyEndpointSourceIfNeeded(catalog: setupCatalog)
                }
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

        let models = Self.grokSubscriptionModels(from: descriptors)
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

        let models = Self.codexSubscriptionModels(from: descriptors)
        provider.catalogModels = models
        provider.models = models
        provider.cachedAvailableModelCount = models.count
        provider.lastError = nil
    }

    /// Maps the Grok subscription `/models` descriptors to catalog models. Catalog sync and the capability matrix tests
    /// share this one mapping.
    static func grokSubscriptionModels(from descriptors: [GrokModelDescriptor]) -> [AIModel] {
        let preferred = descriptors.first?.id
        return descriptors.map { descriptor in
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
    }

    /// Maps the Codex subscription `/models` descriptors to catalog models. Catalog sync and the capability matrix tests
    /// share this one mapping.
    static func codexSubscriptionModels(from descriptors: [CodexModelDescriptor]) -> [AIModel] {
        let preferred = descriptors.first?.slug
        return descriptors.map { descriptor in
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
            enriched.upstreamInputModalities = descriptors[index].inputModalities
            return enriched
        }
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
                ? (Self.relayDomainName(from: provider.baseURLText ?? "") ?? ProviderKind.relay.displayName)
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

    static func relayDomainName(from endpoint: String) -> String? {
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
                        apiKey: ProviderCredentialResolver.apiKey(provider: provider, modelID: nil),
                        preferredModelID: relayVerificationSampleModelID(for: provider),
                        baseURL: provider.baseURLText,
                        relayRequested: provider.relayRequested
                    )
                    try Task.checkCancellation()
                    guard commitGuard() else { throw CancellationError() }
                    applyRelaySyncResult(syncResult, to: &provider)
                }
            } else if provider.authMode == .subscription {
                await MetadataClient.shared.forceRefresh(providerKinds: [provider.kind])
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
                await MetadataClient.shared.forceRefresh(providerKinds: [provider.kind])
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
                    apiKey: ProviderCredentialResolver.apiKey(provider: provider, modelID: nil),
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
        // A catalog response carries only model ids: the model-level protocol, source, capability overrides and engine declaration are written locally, so they carry over by id after a refresh.
        let relayFields = Self.relayModelFieldsByID(enabled: provider.models, catalog: provider.catalogModels)
        provider.catalogModels = ModelResolver.mergeManualModels(
            from: provider.allModels,
            into: syncResult.models.map { Self.restoringRelayModelFields($0, from: relayFields) },
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
        let refreshedIndex = ModelResolver.RemoteModelIndex(refreshedEnabled, providerKind: provider.kind)
        let retained = provider.models.filter { enabled in
            !refreshedIndex.containsRemoteModel(of: enabled)
        }
        provider.models = refreshedEnabled + retained
    }


    private struct RelayModelFields {
        let transport: RelayTransport?
        let source: RelayTransportSource?
        let overrides: RelayCapabilityOverrides?
        let engineDeclaration: EngineDeclaration?
        let keyID: String?
        let listedByKeyIDs: [String]?
        let deniedKeyID: String?
    }

    /// Enabled models win (a send writes the observed value to both copies, but the one the user is actually using is authoritative).
    private static func relayModelFieldsByID(enabled: [AIModel], catalog: [AIModel]) -> [String: RelayModelFields] {
        var result: [String: RelayModelFields] = [:]
        for model in enabled + catalog where result[model.id] == nil {
            guard model.relayTransport != nil || model.relayCapabilityOverrides != nil
                || model.engineDeclaration != nil || model.relayKeyID != nil
                || model.relayListedByKeyIDs != nil || model.relayDeniedKeyID != nil else { continue }
            result[model.id] = RelayModelFields(
                transport: model.relayTransport,
                source: model.relayTransportSource,
                overrides: model.relayCapabilityOverrides,
                engineDeclaration: model.engineDeclaration,
                keyID: model.relayKeyID,
                listedByKeyIDs: model.relayListedByKeyIDs,
                deniedKeyID: model.relayDeniedKeyID
            )
        }
        return result
    }

    private static func restoringRelayModelFields(_ model: AIModel, from fields: [String: RelayModelFields]) -> AIModel {
        guard let saved = fields[model.id] else { return model }
        var out = model
        out.relayTransport = saved.transport
        out.relayTransportSource = saved.source
        out.relayCapabilityOverrides = saved.overrides
        // Engine declaration: use the new one if this catalog carries it, otherwise keep the old one.
        out.engineDeclaration = model.engineDeclaration ?? saved.engineDeclaration
        // The three key-binding fields: the binding and the no-access marker carry over by id; the lister list uses the new value when this refresh provides one.
        out.relayKeyID = saved.keyID
        out.relayListedByKeyIDs = model.relayListedByKeyIDs ?? saved.listedByKeyIDs
        out.relayDeniedKeyID = saved.deniedKeyID
        return out
    }

    func updateAPIKey(providerID: UUID, newKey: String) async throws {
        guard let originalProvider = provider(for: providerID) else { return }

        var updatedProvider = originalProvider
        updatedProvider.apiKey = newKey
        updatedProvider.apiKeyPreview = APIKeyMask.masked(newKey)

        if originalProvider.kind == .relay {
            // This replaces the value of the primary key: use the same pure function as the key operation replaceSecret
            // (it clears that key's status and no-access markers).
            let primaryKeyID = RelayKeyBinding.keyIDs(originalProvider)[0]
            if let replaced = RelayKeyBinding.apply(.replaceSecret(id: primaryKeyID, apiKey: newKey), to: originalProvider) {
                updatedProvider = replaced
            }
            // The first observable write for the new key must fail closed: it must not briefly inherit the old Connected
            // state and lastCheckedAt, which are evidence for the old credential, not for the new one.
            updatedProvider.status = .issue(ProviderIssueMessage.unverifiedConnectionKey)
            updatedProvider.lastCheckedAt = nil
            updatedProvider.lastError = ProviderIssueMessage.unverifiedConnectionKey
            // Changing only the key does not clear the catalog: after re-verification succeeds only this one key is
            // refetched, and on failure the catalog stays as it was. A save that also changes the address, protocol,
            // auth or security mode does not come through here and still clears the catalog.
            updateProvider(updatedProvider)
            guard !newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do {
                try await reverifyRelayProvider(providerID: providerID, refreshCatalog: true, catalogKeyID: primaryKeyID)
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

    /// The single 1-token generation check used by the lifecycle entry points. An explicit model is a hard prerequisite;
    /// it must never degrade to `/models`.
    func verifyRelayGeneration(_ provider: Provider) async throws {
        guard provider.kind == .relay else { return }
        let requested = provider.relayRequested ?? RelayRequestedConfig()
        // Verification sample = the last-used fallback model, then the first catalog model; a stored relayRequested.modelID is not read.
        let modelID = relayVerificationSampleModelID(for: provider)
        guard let modelID, !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderServiceError.invalidConfiguration(detail: "A model is required for generation verification.")
        }
        guard let endpoint = provider.baseURLText, !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderServiceError.invalidConfiguration(detail: "A request URL is required for generation verification.")
        }
        _ = try await openAIService.pingRelay(
            apiKey: ProviderCredentialResolver.apiKey(provider: provider, modelID: modelID),
            baseURL: endpoint,
            modelID: modelID,
            relayRequested: requested
        )
    }

    /// The same 1-token check, which also reports what this request says about the key that was actually sent; it writes nothing.
    /// The key sent is the effective key of the verification sample model (`verifyRelayGeneration` picks the key by sample). Cancellation reports nothing.
    func verifyRelayGeneration(_ provider: Provider, observe: (RelayKeyStatusObservation) -> Void) async throws {
        let sampleModelID = relayVerificationSampleModelID(for: provider)
        let keyID = RelayKeyBinding.effectiveKeyID(provider: provider, modelID: sampleModelID)
        let secret = ProviderCredentialResolver.apiKey(provider: provider, modelID: sampleModelID)
        let recorder = RelayPreOutputRejection.Recorder()
        do {
            try await RelayPreOutputRejection.$current.withValue(recorder) {
                try await verifyRelayGeneration(provider)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let rejection = recorder.rejection
            observe(RelayKeyStatusObservation(
                keyID: keyID, secret: secret,
                state: RelayKeyAccess.generationFailureStatus(rejection), httpStatus: rejection?.status
            ))
            throw error
        }
        observe(RelayKeyStatusObservation(keyID: keyID, secret: secret, state: .ok, httpStatus: nil))
    }

    /// "Test connection" on the edit page: when the result is persisted (`persists`) it also writes the key status, otherwise it writes nothing.
    func verifyRelayGenerationRecordingKeyStatus(_ candidate: Provider, providerID: UUID, persists: Bool) async throws {
        var observation: RelayKeyStatusObservation?
        defer {
            if persists { recordRelayKeyStatusObservation(observation, providerID: providerID) }
        }
        try await verifyRelayGeneration(candidate) { observation = $0 }
    }

    /// Writes one conclusion onto the connection: only when that key's value is unchanged, the conclusion is not nil and the status changed (success records no status code).
    @discardableResult
    static func applyRelayKeyStatusObservation(_ observation: RelayKeyStatusObservation?, to provider: inout Provider) -> Bool {
        guard let observation, provider.kind == .relay,
              ProviderCredentialResolver.secret(provider: provider, keyID: observation.keyID) == observation.secret else { return false }
        return applyRelayGenerationKeyStatus(&provider, keyID: observation.keyID, state: observation.state, httpStatus: observation.httpStatus)
    }

    func recordRelayKeyStatusObservation(_ observation: RelayKeyStatusObservation?, providerID: UUID) {
        guard var provider = provider(for: providerID),
              Self.applyRelayKeyStatusObservation(observation, to: &provider) else { return }
        updateProvider(provider)
    }

    /// The relay verification sample, with the last-used model as a fallback.
    func relayVerificationSampleModelID(for provider: Provider) -> String? {
        ProviderSelectionSnapshot.relayVerificationSampleModelID(
            in: provider,
            lastUsedModelRef: appState?.lastUsedModelRef
        )
    }

    /// A plain "re-verify" runs only the 1-token generation. A catalog refresh spends the user's connection and is not
    /// connection evidence; only explicit combined entry points (replacing a key, changing the security mode or the
    /// connection identity) require it.
    func reverifyRelayProvider(
        providerID: UUID,
        refreshCatalog: Bool = false,
        catalogKeyID: String? = nil,
        commitGuard: @escaping @MainActor () -> Bool = { true }
    ) async throws {
        guard let provider = provider(for: providerID), provider.kind == .relay else { return }
        let connectionIdentity = RelayCatalogConnectionIdentity(provider: provider)
        // This 1-token request is really sent with the effective key of the sample model: the status is written on that
        // key, and dropped if that key's value or the connection changed in the meantime.
        var observation: RelayKeyStatusObservation?
        func recordKeyStatus() {
            guard commitGuard(), let current = self.provider(for: providerID), current.kind == .relay,
                  RelayCatalogConnectionIdentity(provider: current).sameConnection(as: connectionIdentity) else { return }
            recordRelayKeyStatusObservation(observation, providerID: providerID)
        }
        do {
            try await verifyRelayGeneration(provider) { observation = $0 }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            recordKeyStatus()
            throw error
        }
        guard commitGuard(),
              RelayGenerationVerificationWritePolicy.mayCommit(
                  current: self.provider(for: providerID),
                  connectionIdentity: connectionIdentity
              ) else { throw CancellationError() }
        // `/models` is catalog evidence only and must not overwrite the connection evidence just obtained from the
        // 1-token generation check. If the catalog fails, the connection stays connected and a retryable catalog
        // state is shown explicitly.
        recordRelayGenerationVerification(providerID: providerID, verified: true)
        recordKeyStatus()
        if refreshCatalog {
            _ = await refreshRelayCatalog(providerID: providerID, onlyKeyID: catalogKeyID, commitGuard: commitGuard)
        }
    }

    /// Refreshes only the relay's model catalog. The catalog is not a connection check: success or failure must neither
    /// fabricate nor revoke existing generation evidence. Failure always becomes the stable catalog-error key, so the
    /// three clients show only "couldn't fetch the model list" with a retry or enter-by-hand way out.
    ///
    /// With two or more keys, each key sends the same refresh request with its own value (sequentially), the results are
    /// merged by `RelayKeyBinding.mergeCatalog`, each key's status is written, and the existing retention of manual and
    /// enabled models then applies. `onlyKeyID` fetches just that key and marks the others skipped; with a single key it
    /// is ignored and the original path runs.
    @discardableResult
    func refreshRelayCatalog(
        providerID: UUID,
        onlyKeyID: String? = nil,
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

        /// May only finish a catalog request that this request still owns and whose actual connection is unchanged.
        /// A name or default-model update does not change the identity, so the catalog result merges into the latest
        /// object; a changed key, endpoint or protocol abandons the result and never overwrites the newer connection.
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

        // With fewer than two keys the single-key path still writes the primary key's status; an implicit single key is
        // materialized into a list on the first write.
        let singleKeyID = RelayKeyBinding.keyIDs(provider)[0]

        func finishCatalogFailure(rejection: RelayPreOutputRejection? = nil, recordKeyStatus: Bool = false) {
            guard var current = ownedCurrentProvider() else { return }
            // A catalog failure is an independent soft error; it must not rewrite the connection status or time from the generation check.
            current.lastError = ProviderIssueMessage.catalogUnavailableKey
            if recordKeyStatus {
                let status = rejection?.status
                let body = rejection.map { String(decoding: $0.body, as: UTF8.self) } ?? ""
                if let updated = RelayKeyAccess.settingStatus(
                    current, keyID: singleKeyID,
                    state: RelayKeyAccess.catalogFailureState(status: status, body: body),
                    httpStatus: status, at: Date()
                ) {
                    current = updated
                }
            }
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
            if RelayKeyBinding.keys(provider).count >= 2 {
                return try await refreshRelayCatalogPerKey(
                    provider: provider,
                    service: service,
                    onlyKeyID: onlyKeyID,
                    connectionIdentity: connectionIdentity,
                    isOwned: { [weak self] in
                        self?.relayCatalogRefreshTokens[providerID] == token && commitGuard()
                    },
                    release: releaseToken
                )
            }
            // Same recorder as the multi-key path: on failure the raw status code and body decide that key's status.
            let recorder = RelayPreOutputRejection.Recorder()
            let syncResult: ProviderSyncResult
            do {
                syncResult = try await RelayPreOutputRejection.$current.withValue(recorder) {
                    try await service.syncProvider(
                        apiKey: ProviderCredentialResolver.apiKey(provider: provider, modelID: nil),
                        preferredModelID: relayVerificationSampleModelID(for: provider),
                        baseURL: provider.requestBaseURLText(),
                        relayRequested: provider.relayRequested
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                finishCatalogFailure(rejection: recorder.rejection, recordKeyStatus: true)
                return false
            }
            try Task.checkCancellation()
            guard commitGuard(), var current = ownedCurrentProvider() else {
                releaseToken()
                return false
            }
            // Re-read current after the response instead of writing the pre-request provider back wholesale, so a
            // concurrent change to the name, enabled models and so on is kept; a relay has no default model to re-mark.
            applyRelaySyncResult(syncResult, to: &current)
            if let updated = RelayKeyAccess.settingStatus(current, keyID: singleKeyID, state: .ok, httpStatus: nil, at: Date()) {
                current = updated
            }
            // A directory response is never a substitute for a generation probe.
            // It only clears its own catalog error; connection status/time stay intact.
            // A connection error from an unverified save likewise must not be washed away by a successful /models.
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

    // MARK: - Relay multiple keys

    /// Entry point for data-layer key operations (called from the key pages): writes the result of `RelayKeyBinding.apply`.
    /// After add, every key refetches the catalog (so the primary key also gets a status and listers); after
    /// replaceSecret only that key refetches (the others are skipped); after rebind, a model that has no protocol yet
    /// gets the same lazy 1-token check as when it is enabled. Returns false when the operation is refused (the
    /// connection is missing, is not a relay, or the pure function refused).
    @discardableResult
    func applyRelayKeyOperation(providerID: UUID, _ operation: RelayKeyBinding.Operation) async -> Bool {
        guard let provider = provider(for: providerID), provider.kind == .relay,
              let updated = RelayKeyBinding.apply(operation, to: provider) else { return false }
        updateProvider(updated)
        switch operation {
        case .add:
            _ = await refreshRelayCatalog(providerID: providerID)
        case let .replaceSecret(id, _):
            _ = await refreshRelayCatalog(providerID: providerID, onlyKeyID: id)
        case let .rebind(modelID, _):
            // After a rebind "not reachable" no longer holds, so clear it first; with no protocol, run the lazy check once as before.
            setRelayModelProbeState(nil, providerID: providerID, modelID: modelID)
            if updated.models.contains(where: { $0.id == modelID && $0.relayTransport == nil }) {
                let token = UUID()
                relayModelProbeTasks[providerID, default: [:]][token] = Task { [weak self, appStateRetainer = appState as AppState?] in
                    _ = appStateRetainer // same note as in enableModel
                    await self?.probeRelayModelTransport(providerID: providerID, modelID: modelID)
                    self?.relayModelProbeTasks[providerID]?[token] = nil
                }
            }
        case .rename, .move, .delete:
            break
        }
        return true
    }

    /// A send rejected before any output: no access means the model records the effective key (a single key is recorded
    /// as `initial` too); an invalid or restricted key writes that key's status (a single key is materialized into a
    /// list; no write when the status did not change). Other verdicts write nothing.
    func recordRelayKeyAccessFailure(
        providerID: UUID,
        modelID: String,
        keyID: String,
        outcome: RelayKeyAccess.Outcome,
        httpStatus: Int,
        sentIdentity: RelayCatalogConnectionIdentity? = nil
    ) {
        guard relayKeyWriteIsCurrent(providerID: providerID, modelID: modelID, sentIdentity: sentIdentity) else { return }
        switch outcome {
        case .modelAccessDenied:
            mutateRelayModel(providerID: providerID, modelID: modelID) { model in
                model.relayDeniedKeyID = keyID
            }
        case .keyInvalid, .keyLimited:
            guard let provider = provider(for: providerID), provider.kind == .relay,
                  let updated = RelayKeyAccess.settingStatus(
                      provider, keyID: keyID, state: outcome == .keyInvalid ? .invalid : .limited,
                      httpStatus: httpStatus, at: Date()
                  ) else { return }
            updateProvider(updated)
        case .none:
            break
        }
    }

    /// A successful send clears the no-access marker if it equals the effective key, and writes ok if that key's status is not ok
    /// (a single key is materialized into a list).
    /// "Not reachable": only this model is cleared (no lazy check, and it does not matter whether the key status changed).
    /// Writing the key status back to ok does not touch other models on the same key: a relay can gate by protocol, and a
    /// working key does not mean every model works.
    func recordRelayKeyAccessSuccess(
        providerID: UUID, modelID: String, keyID: String,
        sentIdentity: RelayCatalogConnectionIdentity? = nil
    ) {
        if case .failed = appState?.relayModelProbeStates[providerID]?[modelID] {
            setRelayModelProbeState(nil, providerID: providerID, modelID: modelID)
        }
        guard relayKeyWriteIsCurrent(providerID: providerID, modelID: modelID, sentIdentity: sentIdentity) else { return }
        mutateRelayModel(providerID: providerID, modelID: modelID) { model in
            if model.relayDeniedKeyID == keyID { model.relayDeniedKeyID = nil }
        }
        guard let provider = provider(for: providerID), provider.kind == .relay,
              provider.relayKeys?.first(where: { $0.id == keyID })?.status?.state != .ok,
              let updated = RelayKeyAccess.settingStatus(provider, keyID: keyID, state: .ok, httpStatus: nil, at: Date())
        else { return }
        updateProvider(updated)
    }

    /// A generation request on a persisted connection (1-token re-verify, lazy check, capability test) writes that key's
    /// status back: only success, invalid key and restricted key are written (nil means it says nothing about this key);
    /// nothing is written when the status did not change. The caller checks the connection identity first.
    func recordRelayGenerationKeyStatus(providerID: UUID, keyID: String, state: RelayKey.Status.State?, httpStatus: Int?) {
        guard var provider = provider(for: providerID), provider.kind == .relay,
              Self.applyRelayGenerationKeyStatus(&provider, keyID: keyID, state: state, httpStatus: httpStatus) else { return }
        updateProvider(provider)
    }

    /// Returns whether anything was written. Success records no status code (same as a successful send).
    @discardableResult
    static func applyRelayGenerationKeyStatus(
        _ provider: inout Provider, keyID: String, state: RelayKey.Status.State?, httpStatus: Int?
    ) -> Bool {
        guard let state,
              let updated = RelayKeyAccess.settingStatus(
                  provider, keyID: keyID, state: state, httpStatus: state == .ok ? nil : httpStatus, at: Date()
              ) else { return false }
        provider = updated
        return true
    }

    /// A key's value was replaced: clears "not reachable" on enabled models of this connection whose effective key is in
    /// `keyIDs`, and re-checks those that still have no model-level protocol through the same entry as the lazy check
    /// after enabling (one background task, one after another, without blocking the caller; the skip guards stay in that
    /// entry). "Checking" is left alone: the in-flight lazy check finishes it. The effective key is computed on the latest connection object.
    private func relayKeySecretsReplaced(providerID: UUID, keyIDs: Set<String>) {
        guard !keyIDs.isEmpty,
              let states = appState?.relayModelProbeStates[providerID],
              let provider = provider(for: providerID), provider.kind == .relay else { return }
        let cleared = provider.models.filter { model in
            guard case .failed = states[model.id] else { return false }
            return keyIDs.contains(RelayKeyBinding.effectiveKeyID(provider: provider, modelID: model.id))
        }
        guard !cleared.isEmpty else { return }
        for model in cleared {
            setRelayModelProbeState(nil, providerID: providerID, modelID: model.id)
        }
        let reprobe = cleared.filter { $0.relayTransport == nil }.map(\.id)
        guard !reprobe.isEmpty else { return }
        let token = UUID()
        relayModelProbeTasks[providerID, default: [:]][token] = Task { [weak self, appStateRetainer = appState as AppState?] in
            _ = appStateRetainer // same note as in enableModel
            for modelID in reprobe {
                await self?.probeRelayModelTransport(providerID: providerID, modelID: modelID)
            }
            self?.relayModelProbeTasks[providerID]?[token] = nil
        }
    }

    /// The body of a multi-key catalog refresh. It captures each key's value before the request; if on return the
    /// connection (address / kind / request config) changed or fewer than two keys remain, the whole run is abandoned,
    /// and a key that was deleted or changed value is only treated as skipped. A failed key keeps the entries it listed
    /// last time, and its status follows the key-access verdict.
    private func refreshRelayCatalogPerKey(
        provider: Provider,
        service: any ProviderServiceProtocol,
        onlyKeyID: String?,
        connectionIdentity: RelayCatalogConnectionIdentity,
        isOwned: @MainActor () -> Bool,
        release: () -> Void
    ) async throws -> Bool {
        let providerID = provider.id
        var results: [String: RelayKeyBinding.CatalogFetch] = [:]
        var requestedSecrets: [String: String] = [:]
        let preferredModelID = relayVerificationSampleModelID(for: provider)
        let baseURL = provider.requestBaseURLText()
        let relayRequested = provider.relayRequested
        for key in RelayKeyBinding.keys(provider) {
            guard onlyKeyID == nil || onlyKeyID == key.id else {
                results[key.id] = .skipped
                continue
            }
            let secret = ProviderCredentialResolver.secret(provider: provider, keyID: key.id)
            requestedSecrets[key.id] = secret
            // A non-2xx response to the refresh request is also recorded in this recorder via mapHTTPError, so on failure the raw status code and body decide the key status.
            let recorder = RelayPreOutputRejection.Recorder()
            do {
                let syncResult = try await RelayPreOutputRejection.$current.withValue(recorder) {
                    try await service.syncProvider(
                        apiKey: secret,
                        preferredModelID: preferredModelID,
                        baseURL: baseURL,
                        relayRequested: relayRequested
                    )
                }
                results[key.id] = .ok(syncResult.models)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let rejection = recorder.rejection
                results[key.id] = .failed(
                    status: rejection?.status,
                    body: rejection.map { String(decoding: $0.body, as: UTF8.self) } ?? ""
                )
            }
            try Task.checkCancellation()
        }
        guard isOwned(),
              var current = self.provider(for: providerID), current.kind == .relay,
              RelayCatalogConnectionIdentity(provider: current).sameConnection(as: connectionIdentity),
              RelayKeyBinding.keys(current).count >= 2 else {
            release()
            return false
        }
        let keyIDs = RelayKeyBinding.keyIDs(current)
        for (keyID, secret) in requestedSecrets
        where !keyIDs.contains(keyID) || ProviderCredentialResolver.secret(provider: current, keyID: keyID) != secret {
            results[keyID] = .skipped
        }
        let merged = RelayKeyBinding.mergeCatalog(keyIDs: keyIDs, previous: current.catalogModels, results: results)
        let anyFetched = results.values.contains { if case .ok = $0 { return true } else { return false } }
        // If no key fetched successfully, the catalog stays as it was (only statuses are written) and the result is a failure, same as a single-key failure.
        if anyFetched {
            // Apply the same sort as the single-key refresh after merging, so both paths output the same order (each key's entries were already filtered by the refresh request).
            let sorted = merged.catalog.sorted(by: openAIService.catalogModelSort)
            applyRelaySyncResult(ProviderSyncResult(models: sorted), to: &current)
        }
        let now = Date()
        for keyID in keyIDs {
            guard let state = merged.states[keyID],
                  let updated = RelayKeyAccess.settingStatus(
                      current, keyID: keyID, state: state.state, httpStatus: state.httpStatus, at: now
                  ) else { continue }
            current = updated
        }
        // The catalog error describes the catalog only: if any key fetched, clear our own catalog error; if none did,
        // mark the catalog unavailable and leave the connection status alone.
        if anyFetched {
            if current.lastError == ProviderIssueMessage.catalogUnavailableKey { current.lastError = nil }
        } else {
            current.lastError = ProviderIssueMessage.catalogUnavailableKey
        }
        updateProvider(current)
        release()
        return anyFetched
    }

    /// Called only when the tested configuration still equals the saved connection; an unsaved draft must not pollute the old persisted state.
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

        let previousBaseURLText = provider.baseURLText
        provider.baseURLText = effectiveBaseURLText ?? setupCatalog.defaultBaseURLText(for: provider.kind)
        provider.reclassifyEndpointSource(previousBaseURLText: previousBaseURLText, catalog: setupCatalog)

        updateProvider(provider)
        try await resyncProvider(providerID: providerID)
    }

    /// A template item with placeholders was chosen on the official detail page: same criterion as setup, so the address, source and template values are written together.
    func updateEndpointSetup(providerID: UUID, submission: ProviderSetupSubmission) async throws {
        guard var provider = provider(for: providerID), provider.usesEndpointSource else { return }
        provider.baseURLText = submission.baseURLText
        provider.endpointSource = submission.endpointSource
        provider.setupValues = submission.setupValues
        updateProvider(provider)
        try await resyncProvider(providerID: providerID)
    }

    func setDefaultModel(modelID: String, for providerID: UUID) {
        guard var provider = provider(for: providerID),
              provider.kind != .relay,
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
            // A relay has no default model: this only guarantees the model is enabled. Resolution uses the literal ID, and when the catalog has no entry
            // with that literal ID it falls through to the manual add below instead of being folded by date into another model.
            if provider.kind == .relay {
                return enableModel(modelID: trimmedModelID, for: providerID) != .notFound
            }
            setDefaultModel(modelID: trimmedModelID, for: providerID)
            return true
        }

        return saveManualModelData(providerID: providerID, modelID: trimmedModelID)
    }

    /// Outcome of tapping "+" on a catalog row. Callers turn it into user feedback:
    /// `.alreadyEnabled` is idempotent and not a failure, while `.notFound` (provider gone or
    /// the id is not in the catalog) must be visible to the user rather than silent.
    enum EnableModelResult: Equatable {
        case added(modelName: String)
        case alreadyEnabled
        case notFound
    }

    /// - Parameter lazilyVerifiesRelayTransport: pass true only when the user enables a single model in the model library:
    ///   enable first, then run a per-model probe for it in the background; a failed probe does not undo the enabling. Recovery actions such as undoing a delete do not pass it.
    @discardableResult
    func enableModel(
        modelID: String,
        for providerID: UUID,
        lazilyVerifiesRelayTransport: Bool = false
    ) -> EnableModelResult {
        guard var provider = provider(for: providerID),
              let resolvedModel = ModelResolver.matchingModel(for: modelID, in: provider) else {
            return .notFound
        }

        if provider.models.contains(where: { ModelResolver.modelsShareSameRemoteModel($0, resolvedModel, providerKind: provider.kind) }) {
            return .alreadyEnabled
        }

        var enabledModel = resolvedModel
        enabledModel.isDefault = provider.kind != .relay && provider.models.isEmpty
        if let keyID = Self.relayBoundKeyID(for: enabledModel.id, in: provider) {
            enabledModel.relayKeyID = keyID
        }
        provider.models.append(enabledModel)
        provider = ModelResolver.synchronizeDefaultSelection(
            in: provider,
            preferredModelID: provider.defaultModel?.id ?? enabledModel.id
        )
        updateProvider(provider)
        if lazilyVerifiesRelayTransport {
            // The task body runs on the main actor and starts only after this function returns, so registration always happens before the task removes itself.
            let token = UUID()
            // `self?.` strongly holds this object while suspended but not the unowned AppState,
            // so if AppState is released before the probe writes its state it would read a dangling reference; hold it strongly until the task ends.
            relayModelProbeTasks[providerID, default: [:]][token] = Task { [weak self, appStateRetainer = appState as AppState?] in
                _ = appStateRetainer
                await self?.probeRelayModelTransport(providerID: providerID, modelID: enabledModel.id)
                self?.relayModelProbeTasks[providerID]?[token] = nil
            }
        }
        return .added(modelName: enabledModel.name)
    }

    /// "Add all" for a catalog group: write back only once after everything is appended (one cloud sync of the whole set, one background catalog finalize) and do not probe.
    /// Duplicate detection and key ownership match enabling a single model, and the check sees the models already appended earlier in this batch. Returns how many were newly enabled.
    @discardableResult
    func enableModels(modelIDs: [String], for providerID: UUID) -> Int {
        guard var provider = provider(for: providerID) else { return 0 }
        var firstAddedID: String?
        var added = 0
        for modelID in modelIDs {
            guard let resolvedModel = ModelResolver.matchingModel(for: modelID, in: provider),
                  !provider.models.contains(where: { ModelResolver.modelsShareSameRemoteModel($0, resolvedModel, providerKind: provider.kind) }) else {
                continue
            }
            var enabledModel = resolvedModel
            enabledModel.isDefault = provider.kind != .relay && provider.models.isEmpty
            if let keyID = Self.relayBoundKeyID(for: enabledModel.id, in: provider) {
                enabledModel.relayKeyID = keyID
            }
            provider.models.append(enabledModel)
            firstAddedID = firstAddedID ?? enabledModel.id
            added += 1
        }
        guard added > 0 else { return 0 }
        provider = ModelResolver.synchronizeDefaultSelection(
            in: provider,
            preferredModelID: provider.defaultModel?.id ?? firstAddedID
        )
        updateProvider(provider)
        return added
    }

    /// Decides the key by bindCases when enabling or adding manually; with a single key on the connection this is nil and nothing is written.
    /// Family = the cached server by-model family, then `RelayFamilyHeuristics`; read synchronously, no request is sent.
    static func relayBoundKeyID(
        for modelID: String,
        in provider: Provider,
        family: ((String) -> String?)? = nil
    ) -> String? {
        guard provider.kind == .relay else { return nil }
        let keyIDs = RelayKeyBinding.keyIDs(provider)
        guard keyIDs.count >= 2 else { return nil }
        let resolveFamily = family ?? { id in
            MetadataClient.shared.cachedRelayModelFamilyNow(for: id) ?? RelayFamilyHeuristics.infer(modelID: id)?.rawValue
        }
        return RelayKeyBinding.bind(
            keyIDs: keyIDs,
            catalog: provider.catalogModels,
            enabled: provider.models,
            targetModelID: modelID,
            family: resolveFamily
        )
    }

    // MARK: - Relay per-model probe

    /// Runs a 1-token probe over the candidates for one enabled relay model; the first protocol that passes is written back as `reachable`.
    /// A request is sent only for a relay form that is not a local engine, whose connection protocol is `auto`, and whose model has no protocol of its own (from any source);
    /// when the user chose the connection protocol the model follows the connection, so nothing is probed and no field is written. If nothing passes, no field is written.
    /// The write-back lands on the latest object: if the connection's key / address / config changed during the probe, or the model was disabled or already has a protocol, the result is dropped.
    func probeRelayModelTransport(providerID: UUID, modelID: String) async {
        guard let provider = provider(for: providerID),
              ProviderForm.of(provider) == .relay,
              provider.relayRequested?.engineProfile == nil,
              let model = provider.models.first(where: { $0.id == modelID }),
              model.relayTransport == nil,
              !RelayProbeCandidates.followsUserChosenConnection(provider: provider, model: model) else { return }
        let connectionIdentity = Self.relayProbeWriteIdentity(provider, modelID: modelID)
        // The "checking / not reachable" state of a model-library row lives in this session's memory only; every exit settles it to its final value.
        setRelayModelProbeState(.inFlight, providerID: providerID, modelID: modelID)
        var finalState: RelayModelProbeState?
        defer { setRelayModelProbeState(finalState, providerID: providerID, modelID: modelID) }
        let candidates = await RelayProbeCandidates.candidates(
            supportedEndpointTypes: RelayCatalogEndpointTypesCache.shared.endpointTypes(
                endpoint: provider.baseURLText,
                modelID: modelID
            ),
            family: { await MetadataClient.shared.relayModelFamily(for: modelID) }
        )
        let service = openAIService
        let apiKey = ProviderCredentialResolver.apiKey(provider: provider, modelID: modelID)
        let keyID = RelayKeyBinding.effectiveKeyID(provider: provider, modelID: modelID)
        let endpoint = provider.baseURLText ?? ""
        let outcome: RelayModelProbe.Outcome?
        // Used by "view reason" when nothing passed: the error of the last candidate sent, with its upstream status code.
        var lastError: Error?
        var lastStatus: Int?
        var lastRejection: RelayPreOutputRejection?
        do {
            outcome = try await RelayModelProbe.probe(
                provider: provider,
                model: model,
                candidates: candidates,
                onFailure: { error, rejection in
                    lastError = error
                    lastStatus = rejection?.status
                    lastRejection = rejection
                }
            ) { routed, probeModelID in
                _ = try await service.pingRelay(
                    apiKey: apiKey,
                    baseURL: endpoint,
                    modelID: probeModelID,
                    relayRequested: routed
                )
            }
        } catch {
            return
        }
        // If the connection's key / address / config changed during the probe, or the model was disabled or already has a protocol, this result is void and the in-memory state is cleared with it.
        guard var current = self.provider(for: providerID),
              Self.relayProbeWriteIdentity(current, modelID: modelID) == connectionIdentity else { return }
        // The key status is written by the outcome of the last attempt, on the effective key of the probed model: a pass means success, a failure is judged by its upstream response.
        let keyStatusWritten = Self.applyRelayGenerationKeyStatus(
            &current, keyID: keyID,
            state: outcome != nil ? .ok : RelayKeyAccess.generationFailureStatus(lastRejection),
            httpStatus: outcome != nil ? nil : lastRejection?.status
        )
        guard current.models.contains(where: { $0.id == modelID && $0.relayTransport == nil }) else {
            if keyStatusWritten { updateProvider(current) }
            return
        }
        guard let outcome else {
            if keyStatusWritten { updateProvider(current) }
            // A cancelled probe (leaving the page / rebinding / re-detecting) is not recorded as "not reachable"; the defer clears "checking".
            if Task.isCancelled { return }
            finalState = .failed(Self.relayModelProbeFailure(lastError, httpStatus: lastStatus))
            return
        }
        RelayModelProbe.apply(outcome, modelID: modelID, to: &current)
        updateProvider(current)
        // A lazy check that actually ran and passed counts as one enable event for the automatic web probe; the branches that return early above do not probe.
        startRelayWebProbeAfterEnable(providerID: providerID, modelID: modelID)
    }

    /// One sentence for "view reason": reuse the existing failure classification (`ProviderServiceError.message`); with no error at all (no candidate) use the verification-failed sentence.
    private static func relayModelProbeFailure(_ error: Error?, httpStatus: Int?) -> RelayModelProbeFailure {
        guard let error else {
            return RelayModelProbeFailure(
                summary: L10n.tr("No detected protocol completed the test request.", table: .providers),
                httpStatus: httpStatus
            )
        }
        let summary = (error as? ProviderServiceError)?.message
            ?? (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        return RelayModelProbeFailure(summary: summary, httpStatus: httpStatus)
    }

    /// nil clears it. Writes only the in-memory table and does not touch the Provider.
    private func setRelayModelProbeState(_ state: RelayModelProbeState?, providerID: UUID, modelID: String) {
        guard let appState, appState.relayModelProbeStates[providerID]?[modelID] != state else { return }
        appState.relayModelProbeStates[providerID, default: [:]][modelID] = state
        if appState.relayModelProbeStates[providerID]?.isEmpty == true {
            appState.relayModelProbeStates[providerID] = nil
        }
    }

    /// The connection identity used by the lazy-check write-back: the per-protocol root address table does not count, because it is exactly the field
    /// the probe write-back itself adds to, so for two models enabled one after the other on the same connection the first write-back must not make the second look like "connection changed". Other fields are compared as usual.
    /// The key is the effective key of the probed model: only replacing that key (or rebinding) counts as a connection change; changing a different key does not.
    /// The identity used when a send writes back the key status: same criterion as the lazy-check write-back, namely the key value that model actually sent plus the outbound config (address, auth, security mode and so on).
    static func relayKeyWriteIdentity(_ provider: Provider, modelID: String) -> RelayCatalogConnectionIdentity {
        relayProbeWriteIdentity(provider, modelID: modelID)
    }

    /// Write only when the identity recorded at the start of the send still matches the current one; nil means the caller does not check (tests that call directly, and synchronous paths).
    private func relayKeyWriteIsCurrent(providerID: UUID, modelID: String, sentIdentity: RelayCatalogConnectionIdentity?) -> Bool {
        guard let sentIdentity else { return true }
        guard let current = provider(for: providerID) else { return false }
        return Self.relayKeyWriteIdentity(current, modelID: modelID) == sentIdentity
    }

    private static func relayProbeWriteIdentity(_ provider: Provider, modelID: String) -> RelayCatalogConnectionIdentity {
        var stripped = provider
        stripped.relayRequested?.resolvedAPIBaseURLs = nil
        return RelayCatalogConnectionIdentity(provider: stripped, modelID: modelID)
    }

    // MARK: - Relay user-triggered "test capabilities"

    /// After the user taps "test capabilities", sends at most 3 streaming requests for one enabled relay model on its first-send protocol (the same path as chat), and writes the results back as `tested`.
    /// Returns nil and sends nothing when the model is out of scope (not a relay form, a local engine, not enabled, or a protocol that is not one of the four).
    /// Before each item is sent and before each write-back it checks cancellation, the connection identity, the first-send protocol and whether the model is still testable; failing any stops at `stopped`,
    /// completed items keep their readings and are not written. `deadline` / `send` are for test injection only; `onEvent` reports progress item by item to the panel.
    func runRelayCapabilityTest(
        providerID: UUID,
        modelID: String,
        deadline: Duration = RelayCapabilityTest.perItemDeadline,
        send injectedSend: RelayCapabilityTest.Send? = nil,
        onEvent: ((RelayCapabilityTest.Event) -> Void)? = nil
    ) async -> RelayCapabilityTest.Result? {
        guard let provider = provider(for: providerID),
              let model = provider.models.first(where: { $0.id == modelID }),
              RelayCapabilityTest.isEligible(provider: provider, model: model) else { return nil }
        let connectionIdentity = Self.relayProbeWriteIdentity(provider, modelID: modelID)
        let transport = RelayCapabilityTest.transport(provider: provider, model: model)
        let webContext = relayWebProbeAutoContext
        let kinds = RelayCapabilityTest.plannedKinds(provider: provider, model: model, fragments: webContext.fragments)
        let services = services
        let session = providerSession
        let partitionID = appState.sessionPartitionUID
        let baseSend: RelayCapabilityTest.Send = injectedSend ?? { _, request in
            try await RelayCapabilityTest.perform(request, session: session)
        }
        // The HTTP response of each item is written back to that key's status; a timeout or a network error with no response writes nothing.
        let keyID = RelayKeyBinding.effectiveKeyID(provider: provider, modelID: modelID)
        let lastResponse = RelayCapabilityResponseSlot()
        let send: RelayCapabilityTest.Send = { kind, request in
            let response = try await baseSend(kind, request)
            lastResponse.set(response)
            return response
        }

        var text: RelayCapabilityTest.ItemResult?
        var itemResults: [RelayCapabilityOverrides.Key: RelayCapabilityTest.ItemResult] = [:]
        func stopped(_ reason: RelayCapabilityTest.StopReason) -> RelayCapabilityTest.Result {
            RelayCapabilityTest.Result(outcome: .stopped, text: text, itemResults: itemResults, stopReason: reason, written: false)
        }
        /// Returns the latest provider / model while still testable, otherwise the reason it was interrupted.
        func check() -> Swift.Result<(Provider, AIModel), CheckFailure> {
            if Task.isCancelled { return .failure(CheckFailure(reason: .cancelled)) }
            guard let current = self.provider(for: providerID),
                  let currentModel = current.models.first(where: { $0.id == modelID }),
                  RelayCapabilityTest.isEligible(provider: current, model: currentModel) else {
                return .failure(CheckFailure(reason: .unavailable))
            }
            if Self.relayProbeWriteIdentity(current, modelID: modelID) != connectionIdentity {
                return .failure(CheckFailure(reason: .connection))
            }
            if RelayCapabilityTest.transport(provider: current, model: currentModel) != transport {
                return .failure(CheckFailure(reason: .protocolChanged))
            }
            return .success((current, currentModel))
        }

        for kind in kinds where kind != .web {
            let current: Provider
            let currentModel: AIModel
            switch check() {
            case let .success(pair): (current, currentModel) = pair
            case let .failure(failure): return stopped(failure.reason)
            }
            onEvent?(.started(kind))
            let item: RelayCapabilityTest.ItemResult
            lastResponse.set(nil)
            do {
                let request = try RelayCapabilityTest.request(
                    kind: kind, provider: current, model: currentModel, services: services, partitionID: partitionID
                )
                item = try await RelayCapabilityTest.execute(
                    kind: kind, transport: transport, request: request, deadline: deadline, send: send
                )
            } catch is CancellationError {
                return stopped(.cancelled)
            } catch {
                // A request that cannot be built (address / security policy) was never sent, so it is reported as a network error.
                item = RelayCapabilityTest.ItemResult(verdict: .undetermined, reason: .network, status: nil, elapsedMs: 0)
            }
            if let response = lastResponse.take(),
               let latest = self.provider(for: providerID),
               Self.relayProbeWriteIdentity(latest, modelID: modelID) == connectionIdentity {
                // A 2xx counts only when the reading is a success (a web page or an undecodable body counts as a failure).
                let state: RelayKey.Status.State? = (200..<300).contains(response.status)
                    ? (item.reason == .ok ? .ok : nil)
                    : RelayKeyAccess.generationStatus(status: response.status, body: String(decoding: response.body, as: UTF8.self))
                recordRelayGenerationKeyStatus(providerID: providerID, keyID: keyID, state: state, httpStatus: response.status)
            }
            onEvent?(.finished(kind, item))
            if let key = kind.overrideKey {
                itemResults[key] = item
            } else {
                text = item
                guard item.verdict == .accepted else {
                    return RelayCapabilityTest.Result(
                        outcome: .textFailed, text: item, itemResults: [:], stopReason: nil, written: false
                    )
                }
            }
        }

        // The 4th item, web search, is a manual web probe (no cap, no dedup, not entered in the automatic history) using the same injected send.
        // The web override is written by the probe itself and is not rolled back by a later interruption. If the fragment changed before or after the probe, or is no longer listed, it stops at protocol.
        var webOverrideWritten = false
        if kinds.contains(.web) {
            let probeTransport: RelayTransport
            let fragmentHash: String?
            switch check() {
            case let .success((current, currentModel)):
                probeTransport = RelayWebProbe.transport(provider: current, model: currentModel)
                fragmentHash = Self.relayWebProbeHash(current, probeTransport, store: webContext.fragments)
            case let .failure(failure): return stopped(failure.reason)
            }
            guard fragmentHash != nil else { return stopped(.protocolChanged) }
            onEvent?(.started(.web))
            let probeSend = RelayCapabilityWebSend(baseSend)
            let probe = await probeRelayWeb(
                providerID: providerID, modelID: modelID, deadline: deadline,
                send: { request in try await probeSend.send(.web, request) },
                fragments: webContext.fragments, records: webContext.records, template: true
            )
            guard case let .probed(outcome) = probe?.run else {
                if case let .failure(failure) = check() { return stopped(failure.reason) }
                return stopped(probe == nil ? .cancelled : .protocolChanged)
            }
            webOverrideWritten = probe?.overrideWritten ?? false
            let verdict: RelayCapabilityTest.Verdict = switch outcome.result {
            case .searched: .searched
            case .silent: .silent
            case .rejected: .rejected
            case .undetermined: .undetermined
            }
            let item = RelayCapabilityTest.ItemResult(
                verdict: verdict, reason: outcome.reason, status: outcome.status, elapsedMs: outcome.elapsedMs
            )
            onEvent?(.finished(.web, item))
            itemResults[.web] = item
            switch check() {
            case let .success((current, _)):
                if Self.relayWebProbeHash(current, probeTransport, store: webContext.fragments) != fragmentHash {
                    return stopped(.protocolChanged)
                }
            case let .failure(failure): return stopped(failure.reason)
            }
        }

        var current: Provider
        switch check() {
        case let .success(pair): current = pair.0
        case let .failure(failure): return stopped(failure.reason)
        }
        let result = RelayCapabilityTest.Result(
            outcome: .completed,
            text: text,
            itemResults: itemResults,
            stopReason: nil,
            // The web item counts as written only when the probe actually changed the web override (value or source); a user setting or an equal value does not count.
            written: webOverrideWritten
                || itemResults.contains { $0.key != .web && [.accepted, .rejected].contains($0.value.verdict) }
        )
        let before = current
        RelayCapabilityTest.apply(result, modelID: modelID, to: &current)
        if current != before {
            updateProvider(current)
        }
        // When test results are written back, clear the image and toolCall negative cache of the model's first-send protocol (the protocol this test sent).
        Self.clearRelayNegativeCaches(
            connectionID: providerID.uuidString, modelID: modelID,
            transport: transport, kinds: [.image, .toolCall]
        )
        return result
    }

    /// Fragment hash of the capability test web item: the saved fragment, otherwise the built-in template.
    private static func relayWebProbeHash(_ provider: Provider, _ transport: RelayTransport, store: RelayWebFragmentStore) -> String? {
        relayWebProbeFragment(provider, transport, store: store, template: true).map { RelayWebProbe.fragmentHash($0.object) }
    }

    private struct CheckFailure: Error {
        let reason: RelayCapabilityTest.StopReason
    }

    /// The send of a capability test is handed to the web probe (its send must be `@Sendable`); the send is used only within this test.
    private final class RelayCapabilityWebSend: @unchecked Sendable {
        let send: RelayCapabilityTest.Send

        init(_ send: @escaping RelayCapabilityTest.Send) {
            self.send = send
        }
    }

    /// The fragment used by the web probe: the one saved on the first-send protocol; if none and `template` is set, that protocol's built-in template is put into this request's fragment set (not saved).
    private static func relayWebProbeFragment(
        _ provider: Provider, _ transport: RelayTransport, store: RelayWebFragmentStore, template: Bool
    ) -> (set: RelayWebFragmentSet, object: [String: Any])? {
        let saved = store.chatFragments(for: provider)
        if let saved, let object = saved.object(for: transport) { return (saved, object) }
        guard template, let raw = RelayWebFragments.template(for: transport) else { return nil }
        var set = saved ?? RelayWebFragmentSet()
        set.raw[transport.rawValue] = raw
        return set.object(for: transport).map { (set, $0) }
    }

    /// Relay web-search probe: only does the call, with no UI and no automatic trigger.
    /// Returns nil when the connection / model does not exist or the outer task was cancelled; returns `.notListed` (zero requests) when out of scope or the model's effective protocol has no fragment.
    /// searched / rejected / silent write the local record by the merge rule (tested, with the current fragment hash); searched / rejected also write the web override
    /// (tested; `user` entries are untouched); undetermined writes nothing. If the connection identity or protocol changed during the send, only the result is returned and nothing is written.
    func runRelayWebProbe(
        providerID: UUID,
        modelID: String,
        deadline: Duration = RelayWebProbe.deadline,
        send injectedSend: RelayWebProbe.Send? = nil,
        fragments: RelayWebFragmentStore = .shared,
        records: RelayWebProbeStore = .shared
    ) async -> RelayWebProbe.Run? {
        await probeRelayWeb(
            providerID: providerID, modelID: modelID, deadline: deadline, send: injectedSend,
            fragments: fragments, records: records, template: false
        )?.run
    }

    /// Same as `runRelayWebProbe`, and also reports whether the web override was actually written (value or source changed, following the Web probe's overrideWritten).
    /// `template` (for the capability test panel only): when the first-send protocol has no saved fragment, that protocol's built-in template is used for a temporary test and is not saved;
    /// the template is that protocol's effective fragment: the record is still written (hash = template hash), and the web override is mirrored and counted as written as usual.
    private func probeRelayWeb(
        providerID: UUID,
        modelID: String,
        deadline: Duration,
        send injectedSend: RelayWebProbe.Send?,
        fragments: RelayWebFragmentStore,
        records: RelayWebProbeStore,
        template: Bool
    ) async -> (run: RelayWebProbe.Run, overrideWritten: Bool)? {
        guard let provider = provider(for: providerID),
              let model = provider.models.first(where: { $0.id == modelID }) else { return nil }
        guard RelayWebProbe.isEligible(provider: provider, model: model) else { return (.notListed, false) }
        let transport = RelayWebProbe.transport(provider: provider, model: model)
        guard let picked = Self.relayWebProbeFragment(provider, transport, store: fragments, template: template) else {
            return (.notListed, false)
        }
        let set = picked.set
        let fragment = picked.object
        let fragmentHash = RelayWebProbe.fragmentHash(fragment)
        let connectionIdentity = Self.relayProbeWriteIdentity(provider, modelID: modelID)
        let session = providerSession
        // Production send judges while reading: the request is cancelled as soon as web-search evidence is seen, without waiting for the stream to end.
        let send: RelayWebProbe.Send = injectedSend ?? { request in
            try await RelayWebProbe.perform(request, session: session, transport: transport, fragment: fragment)
        }
        let outcome: RelayWebProbe.Outcome
        do {
            let request = try RelayWebProbe.request(
                provider: provider, model: model, fragments: set, services: services,
                partitionID: appState.sessionPartitionUID
            )
            outcome = try await RelayWebProbe.execute(
                transport: transport, fragment: fragment, request: request, deadline: deadline, send: send
            )
        } catch is CancellationError {
            return nil
        } catch {
            // A request that cannot be built (address / security policy) was never sent, so it is reported as a network error.
            outcome = RelayWebProbe.Outcome(result: .undetermined, reason: .network, status: nil, evidenceUrls: [], elapsedMs: 0)
        }
        guard var current = self.provider(for: providerID),
              let currentModel = current.models.first(where: { $0.id == modelID }),
              Self.relayProbeWriteIdentity(current, modelID: modelID) == connectionIdentity,
              RelayWebProbe.transport(provider: current, model: currentModel) == transport,
              // The fragment changed during the send: the result belongs to the old fragment, so neither the record nor the override is written.
              Self.relayWebProbeFragment(current, transport, store: fragments, template: template)
                .map({ RelayWebProbe.fragmentHash($0.object) }) == fragmentHash
        else { return (.probed(outcome), false) }
        // The override mirrors the merged current record (silent does not erase searched); undetermined writes no record and leaves the override alone.
        var mirrored = outcome.result
        if let result = RelayWebProbeRecord.Result(rawValue: outcome.result.rawValue) {
            let merged = records.record(
                connectionID: providerID.uuidString, modelID: modelID, transport: transport.rawValue,
                result: result, source: .tested, fragmentHash: fragmentHash
            )
            mirrored = RelayWebProbe.Result(rawValue: merged.result.rawValue) ?? outcome.result
        }
        let before = current
        RelayWebProbe.apply(mirrored, modelID: modelID, to: &current)
        // apply touches only that model's web override: a changed provider means the override's value or source was actually written.
        let overrideWritten = current != before
        if overrideWritten {
            updateProvider(current)
        }
        return (.probed(outcome), overrideWritten)
    }

    /// "Test again" in the rejected area of the Web Search page: a manual probe (no cap, no dedup, not entered in the automatic history); the store and the send come from the same context as the automatic probe.
    func retestRelayWebProbe(providerID: UUID, modelID: String) async -> RelayWebProbe.Run? {
        let context = relayWebProbeAutoContext
        return await runRelayWebProbe(
            providerID: providerID, modelID: modelID, send: context.send,
            fragments: context.fragments, records: context.records
        )
    }

    // MARK: - Automatic web probe trigger

    /// The effective fragments before the Web Search page saves: after saving, they decide which protocols' fragment hashes changed.
    func relayWebFragmentsBeforeSave(_ provider: Provider) -> RelayWebFragmentSet {
        relayWebProbeAutoContext.fragments.effective(provider: provider)
    }

    /// A successful save on the Web Search page counts as one automatic event: it removes tested web on protocols whose fragment hash changed and prunes the automatic history;
    /// candidates are enabled models whose first-send protocol has a non-empty fragment after the save (in enable order); the selected ones are written to the history and then probed serially in the background.
    func relayWebFragmentsSaved(providerID: UUID, before: RelayWebFragmentSet) {
        let context = relayWebProbeAutoContext
        guard var provider = provider(for: providerID), ProviderForm.of(provider) == .relay else { return }
        let after = context.fragments.chatFragments(for: provider) ?? RelayWebFragmentSet()
        // Compare by effective fragment (saved ?? template): when what is saved is exactly the template, the effective fragment is unchanged, so the tested web result is not cleared.
        let changed = Set(RelayWebFragments.transports.filter { transport in
            RelayWebProbe.effectiveFragment(before, transport: transport).map(RelayWebProbe.fragmentHash)
                != RelayWebProbe.effectiveFragment(after, transport: transport).map(RelayWebProbe.fragmentHash)
        })
        let unchanged = provider
        RelayWebProbe.clearTestedWeb(transports: changed, in: &provider)
        if provider != unchanged {
            updateProvider(provider)
        }
        var currentHashes: [String: String] = [:]
        for transport in RelayWebFragments.transports {
            currentHashes[transport.rawValue] = Self.relayWebFragmentHash(after, transport)
        }
        context.records.pruneAutoHistory(connectionID: providerID.uuidString, currentHashes: currentHashes)
        let candidates = provider.models.compactMap { Self.relayWebProbeCandidate(provider: provider, model: $0, fragments: after) }
        startAutomaticRelayWebProbes(provider: provider, event: .saveFragment, candidates: candidates)
    }

    /// After a lazy check passes: the model is a candidate only if its first-send protocol has a fragment, subject to the cap and dedup.
    private func startRelayWebProbeAfterEnable(providerID: UUID, modelID: String) {
        guard let provider = provider(for: providerID),
              let model = provider.models.first(where: { $0.id == modelID }),
              let fragments = relayWebProbeAutoContext.fragments.chatFragments(for: provider),
              let candidate = Self.relayWebProbeCandidate(provider: provider, model: model, fragments: fragments)
        else { return }
        startAutomaticRelayWebProbes(provider: provider, event: .enableModel(.passed), candidates: [candidate])
    }

    /// Queues onto the serial queue: when its turn comes it selects by the history at that time, re-checks before each send, writes the history, then runs the production probe (following the Web runSelected).
    private func startAutomaticRelayWebProbes(
        provider: Provider, event: RelayWebProbeTrigger.Event, candidates: [RelayWebProbeTrigger.Candidate]
    ) {
        guard !candidates.isEmpty else { return }
        let context = relayWebProbeAutoContext
        let connectionID = provider.id.uuidString
        let form = ProviderForm.of(provider)
        let providerID = provider.id
        let previous = relayWebProbeChain
        relayWebProbeChain = Task { [weak self] in
            await previous?.value
            // The history is written per item before sending and the selection is made when its turn comes, so only what the previous batch really sent counts toward the cap and dedup.
            let selection = RelayWebProbeTrigger.select(
                event: event, form: form, candidates: candidates,
                history: context.records.autoHistory(), now: context.records.now, connectionID: connectionID
            )
            for candidate in selection.probe {
                guard let self else { return }
                // The model was disabled, or its first-send protocol or fragment changed, while queued: this item is no longer sent and no history is written.
                guard let latest = self.provider(for: providerID),
                      let model = latest.models.first(where: { $0.id == candidate.modelID }),
                      let fragments = context.fragments.chatFragments(for: latest),
                      Self.relayWebProbeCandidate(provider: latest, model: model, fragments: fragments) == candidate
                else { continue }
                if selection.countsTowardCap {
                    context.records.appendAutoHistory(connectionID: connectionID, [candidate])
                }
                _ = await self.runRelayWebProbe(
                    providerID: providerID, modelID: candidate.modelID, send: context.send,
                    fragments: context.fragments, records: context.records
                )
            }
        }
    }

    /// For tests: waits for the automatic probe queue to finish.
    func waitForRelayWebProbesForTesting() async {
        await relayWebProbeChain?.value
    }

    private static func relayWebFragmentHash(_ set: RelayWebFragmentSet, _ transport: RelayTransport) -> String? {
        guard let object = set.object(for: transport), !object.isEmpty else { return nil }
        return RelayWebProbe.fragmentHash(object)
    }

    private static func relayWebProbeCandidate(
        provider: Provider, model: AIModel, fragments: RelayWebFragmentSet
    ) -> RelayWebProbeTrigger.Candidate? {
        guard RelayWebProbe.isEligible(provider: provider, model: model) else { return nil }
        let transport = RelayWebProbe.transport(provider: provider, model: model)
        guard let hash = relayWebFragmentHash(fragments, transport) else { return nil }
        return RelayWebProbeTrigger.Candidate(modelID: model.id, transport: transport.rawValue, fragmentHash: hash)
    }

    /// The HTTP response one capability-test item received; the send runs in a child task, so reads and writes are locked.
    private final class RelayCapabilityResponseSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var response: RelayCapabilityTest.Response?

        func set(_ value: RelayCapabilityTest.Response?) {
            lock.withLock { response = value }
        }

        func take() -> RelayCapabilityTest.Response? {
            lock.withLock {
                defer { response = nil }
                return response
            }
        }
    }

    /// "Restore automatic": clears only this model's `tested` override entries (the enabled list and the catalog entry with the same id); `user` entries are untouched.
    func restoreRelayCapabilityAutomatic(providerID: UUID, modelID: String) {
        guard var provider = provider(for: providerID) else { return }
        let before = provider
        func restore(_ models: inout [AIModel]) {
            for index in models.indices where models[index].id == modelID {
                models[index].relayCapabilityOverrides = RelayCapabilityTest.restoreAutomatic(
                    models[index].relayCapabilityOverrides
                )
            }
        }
        restore(&provider.models)
        restore(&provider.catalogModels)
        if provider != before {
            updateProvider(provider)
        }
    }

    // MARK: - Relay model advanced settings

    /// Changes one model (the enabled list and the catalog entry with the same id are written together); nothing is persisted when nothing changed.
    private func mutateRelayModel(providerID: UUID, modelID: String, _ body: (inout AIModel) -> Void) {
        guard var provider = provider(for: providerID) else { return }
        let before = provider
        for index in provider.models.indices where provider.models[index].id == modelID {
            body(&provider.models[index])
        }
        for index in provider.catalogModels.indices where provider.catalogModels[index].id == modelID {
            body(&provider.catalogModels[index])
        }
        if provider != before {
            updateProvider(provider)
        }
    }

    /// Protocol segment: choosing a protocol sets the model-level protocol to it with source `user`; nil (Auto) clears the model-level protocol and source.
    func setRelayModelTransport(providerID: UUID, modelID: String, transport: RelayTransport?) {
        mutateRelayModel(providerID: providerID, modelID: modelID) { model in
            model.relayTransport = transport
            model.relayTransportSource = transport == nil ? nil : .user
        }
    }

    /// A single-protocol 1-token probe after the protocol was chosen by hand (the existing probe primitive, with just that one candidate). It only returns the result and writes no field:
    /// true for pass, false for failure; nil when out of scope (not a relay / a local engine / not enabled) or cancelled.
    /// `ping` is injected by tests only; production uses `OpenAIService.pingRelay`.
    func probeRelayModelTransportOnce(
        providerID: UUID,
        modelID: String,
        transport: RelayTransport,
        ping injectedPing: RelayModelProbe.Ping? = nil
    ) async -> Bool? {
        guard let provider = provider(for: providerID),
              ProviderForm.of(provider) == .relay,
              provider.relayRequested?.engineProfile == nil,
              let model = provider.models.first(where: { $0.id == modelID }) else { return nil }
        let service = openAIService
        let apiKey = ProviderCredentialResolver.apiKey(provider: provider, modelID: modelID)
        let endpoint = provider.baseURLText ?? ""
        // This also writes that key's status: on the effective key of the probed model, dropped if the identity changed.
        let keyID = RelayKeyBinding.effectiveKeyID(provider: provider, modelID: modelID)
        let connectionIdentity = Self.relayProbeWriteIdentity(provider, modelID: modelID)
        var lastRejection: RelayPreOutputRejection?
        do {
            let outcome = try await RelayModelProbe.probe(
                provider: provider, model: model, candidates: [transport],
                onFailure: { _, rejection in lastRejection = rejection }
            ) { routed, probeModelID in
                if let injectedPing { return try await injectedPing(routed, probeModelID) }
                _ = try await service.pingRelay(
                    apiKey: apiKey, baseURL: endpoint, modelID: probeModelID, relayRequested: routed
                )
            }
            if let current = self.provider(for: providerID),
               Self.relayProbeWriteIdentity(current, modelID: modelID) == connectionIdentity {
                recordRelayGenerationKeyStatus(
                    providerID: providerID, keyID: keyID,
                    state: outcome != nil ? .ok : RelayKeyAccess.generationFailureStatus(lastRejection),
                    httpStatus: outcome != nil ? nil : lastRejection?.status
                )
            }
            return outcome != nil
        } catch {
            return nil
        }
    }

    /// Capability row dropdown: On / Off writes `{value, user}` and clears the same-level negative cache of the model's current effective protocol (image generation has no levels);
    /// nil (Auto) deletes the key, both user and tested, and leaves the negative cache alone.
    func setRelayCapabilityOverride(
        providerID: UUID,
        modelID: String,
        key: RelayCapabilityOverrides.Key,
        value: Bool?
    ) {
        guard key != .reasoningLevels else { return }
        mutateRelayModel(providerID: providerID, modelID: modelID) { model in
            var overrides = model.relayCapabilityOverrides ?? RelayCapabilityOverrides()
            overrides.setValue(value, for: key, source: .user)
            model.relayCapabilityOverrides = overrides.isEmpty ? nil : overrides
        }
        let kind: RelayNegativeCache.Kind? = switch key {
        case .image: .image
        case .file: .file
        case .toolCall: .toolCall
        // Web search has no negative cache (the web probe only writes records).
        case .imageGeneration, .reasoningLevels, .web: nil
        }
        guard value != nil, let kind,
              let provider = provider(for: providerID),
              let model = provider.models.first(where: { $0.id == modelID }) else { return }
        Self.clearRelayNegativeCaches(
            connectionID: providerID.uuidString, modelID: modelID,
            transport: RelayFirstSendTransport.current(provider: provider, model: model),
            kinds: [kind]
        )
    }

    /// Clears the relay negative cache and the matching capability negative cache entries together, so a
    /// rejection recorded in either layer cannot keep hiding a capability the user just re-tested or overrode.
    static func clearRelayNegativeCaches(
        connectionID: String,
        modelID: String,
        transport: RelayTransport,
        kinds: Set<RelayNegativeCache.Kind>,
        negativeCache: RelayNegativeCache = .shared,
        capabilityNegativeCache: CapabilityNegativeCache = .shared
    ) {
        negativeCache.clear(connectionID: connectionID, modelID: modelID, transport: transport.rawValue, kinds: kinds)
        let keys: [String] = kinds.compactMap { kind in
            switch kind {
            case .image: CapabilityEvidenceFacade.visionInputKey
            case .file: CapabilityEvidenceFacade.fileInputKey
            case .toolCall, .reasoningTierFast, .reasoningTierBalanced, .reasoningTierDeep, .reasoningTierMax: nil
            }
        }
        for key in keys {
            guard let family = CapabilityEvidenceProductionAdapter.relayWireFamily(transport: transport, key: key) else {
                continue
            }
            capabilityNegativeCache.clear(
                connectionId: connectionID, modelId: modelID, wireFamily: family, capabilityKeys: [key]
            )
        }
    }

    /// Clears every negative cache entry of a connection in both layers.
    static func clearRelayNegativeCaches(
        connectionID: String,
        negativeCache: RelayNegativeCache = .shared,
        capabilityNegativeCache: CapabilityNegativeCache = .shared
    ) {
        negativeCache.clearConnection(connectionID)
        capabilityNegativeCache.clearConnection(connectionID)
    }

    /// The five thinking cells: they only narrow the automatic set (anything outside it is dropped); a set equal to the automatic one, or nil, deletes the override; an empty set is not written.
    func setRelayReasoningLevels(providerID: UUID, modelID: String, levels: [String]?) {
        guard let provider = provider(for: providerID),
              let model = provider.models.first(where: { $0.id == modelID }) else { return }
        let stored: [String]?
        if let levels {
            switch RelayReasoningLevelOverride.normalized(
                levels, automatic: RelayReasoningLevelOverride.automaticModes(provider: provider, model: model)
            ) {
            case .reject: return
            case .clear: stored = nil
            case let .store(kept): stored = kept
            }
        } else {
            stored = nil
        }
        mutateRelayModel(providerID: providerID, modelID: modelID) { model in
            var overrides = model.relayCapabilityOverrides ?? RelayCapabilityOverrides()
            overrides.reasoningLevels = stored
            overrides.sources[.reasoningLevels] = stored == nil ? nil : .user
            model.relayCapabilityOverrides = overrides.isEmpty ? nil : overrides
        }
        // When the user changes the level override, clear the level-rejection record of the model's first-send protocol.
        Self.clearRelayNegativeCaches(
            connectionID: providerID.uuidString, modelID: modelID,
            transport: RelayFirstSendTransport.current(provider: provider, model: model),
            kinds: RelayReasoningTier.kinds
        )
    }

    /// Restore everything to automatic: clears all overrides (user + tested) and the model-level protocol whose source is `user`; the negative cache is not cleared.
    func restoreRelayModelAllAutomatic(providerID: UUID, modelID: String) {
        mutateRelayModel(providerID: providerID, modelID: modelID) { model in
            model.relayCapabilityOverrides = nil
            if model.relayTransportSource == .user {
                model.relayTransport = nil
                model.relayTransportSource = nil
            }
        }
    }

    /// A real send was delivered: if the model's protocol was found by probing (`reachable`) and still equals the protocol at the start of the send,
    /// promote it to `observed` and persist. Following the connection, `user`, `observed`, or a changed protocol are not written.
    func recordRelayDeliveredTransport(
        providerID: UUID,
        modelID: String,
        startedTransport: RelayTransport,
        switchedTo: RelayTransport? = nil
    ) {
        if let switchedTo {
            recordRelayFallbackTransport(
                providerID: providerID, modelID: modelID, startedTransport: startedTransport, switchedTo: switchedTo
            )
            return
        }
        guard var provider = provider(for: providerID), provider.kind == .relay,
              let model = provider.models.first(where: { $0.id == modelID })
                ?? provider.catalogModels.first(where: { $0.id == modelID }),
              model.relayTransport != nil,
              model.relayTransportSource == .reachable,
              RelayEndpointResolver.effectiveTransport(provider: provider, model: model) == startedTransport else { return }
        func promote(_ models: inout [AIModel]) {
            for index in models.indices
            where models[index].id == modelID && models[index].relayTransportSource == .reachable {
                models[index].relayTransportSource = .observed
            }
        }
        promote(&provider.models)
        promote(&provider.catalogModels)
        updateProvider(provider)
    }

    /// A protocol-level fallback succeeded: write the protocol it switched to onto the model as `observed` (the enabled list and the catalog entry with the same id).
    /// Not written when the model's effective protocol changed during the send, or its source became `user`.
    private func recordRelayFallbackTransport(
        providerID: UUID,
        modelID: String,
        startedTransport: RelayTransport,
        switchedTo: RelayTransport
    ) {
        guard var provider = provider(for: providerID), provider.kind == .relay,
              let model = provider.models.first(where: { $0.id == modelID })
                ?? provider.catalogModels.first(where: { $0.id == modelID }),
              model.relayTransportSource != .user,
              RelayEndpointResolver.effectiveTransport(provider: provider, model: model) == startedTransport else { return }
        func write(_ models: inout [AIModel]) {
            for index in models.indices
            where models[index].id == modelID && models[index].relayTransportSource != .user {
                models[index].relayTransport = switchedTo
                models[index].relayTransportSource = .observed
            }
        }
        write(&provider.models)
        write(&provider.catalogModels)
        updateProvider(provider)
    }

    /// Re-detect (a domain function; the UI entry is separate): clears each model's `reachable` (protocol and source together),
    /// clears this connection's capability rejection cache and tool-call memory, refreshes the catalog, and re-probes one by one the enabled models that have no protocol left,
    /// following R4. Leaves `user` / `observed` / capability overrides alone, deletes no enabled model and does not change the connection protocol. Returns whether the catalog refreshed.
    @discardableResult
    func redetectRelayModels(providerID: UUID) async -> Bool {
        guard var provider = provider(for: providerID), ProviderForm.of(provider) == .relay else { return false }
        func clearReachable(_ models: inout [AIModel]) {
            for index in models.indices where models[index].relayTransportSource == .reachable {
                models[index].relayTransport = nil
                models[index].relayTransportSource = nil
            }
        }
        let before = provider
        clearReachable(&provider.models)
        clearReachable(&provider.catalogModels)
        // Re-detecting clears every "checking / not reachable" of this connection; the models re-probed afterwards record anew.
        appState?.relayModelProbeStates[providerID] = nil
        ToolCallMemoryStore.shared.clear(connectionID: providerID)
        UnsupportedParamCache.shared.clearCapabilityRejections(connectionID: providerID.uuidString)
        Self.clearRelayNegativeCaches(connectionID: providerID.uuidString)
        if provider != before {
            updateProvider(provider)
        }
        let refreshed = await refreshRelayCatalog(providerID: providerID)
        // The "checked at" in the detail page header reads this: a catalog refresh does not touch the connection time, and only a successful re-detect records it.
        if refreshed, var current = self.provider(for: providerID) {
            current.lastCheckedAt = Date()
            updateProvider(current)
        }
        await refreshLocalEngineDeclarations(providerID: providerID)
        // After clearing reachable, re-probe all enabled models whose protocol is empty, in enable order; `user` / `observed` / `tested` still carry a protocol and are not probed.
        let unprobedIDs = self.provider(for: providerID)?.models
            .filter { $0.relayTransport == nil }
            .map(\.id) ?? []
        for modelID in unprobedIDs {
            await probeRelayModelTransport(providerID: providerID, modelID: modelID)
        }
        return refreshed
    }

    /// Re-detect a local connection: re-read the declarations through the local connector and replace by model id, swapping only when this time brought a new declaration;
    /// ones it did not provide are kept. Does not touch relayCapabilityOverrides, probe protocols or run a generation check; if reading fails, everything stays as it was.
    private func refreshLocalEngineDeclarations(providerID: UUID) async {
        guard let provider = provider(for: providerID),
              let requested = provider.relayRequested,
              let engine = requested.engineProfile.flatMap(LocalEngineKind.init(rawValue:)),
              let endpoint = provider.baseURLText,
              let declarations = try? await LocalEngineConnector.readDeclarations(
                  engine: engine,
                  endpoint: endpoint,
                  securityMode: requested.securityMode,
                  // The declaration hint uses the fallback model (enabled models only), never a catalog model.
                  modelHint: ProviderSelectionSnapshot.relayFallbackModel(
                      in: provider,
                      lastUsedModelRef: appState?.lastUsedModelRef
                  )?.id,
                  apiKey: ProviderCredentialResolver.apiKey(provider: provider, modelID: nil),
                  certificateFingerprint: requested.certificateFingerprint,
                  session: providerSession
              ),
              !declarations.isEmpty,
              var current = self.provider(for: providerID),
              RelayCatalogConnectionIdentity(provider: current) == RelayCatalogConnectionIdentity(provider: provider)
        else { return }
        func replace(_ models: inout [AIModel]) {
            for index in models.indices {
                if let declared = declarations[models[index].id] { models[index].engineDeclaration = declared }
            }
        }
        let before = current
        replace(&current.models)
        replace(&current.catalogModels)
        if current != before { updateProvider(current) }
    }

#if DEBUG
    /// Tests only: waits for the lazy check triggered by enabling from the model library to finish (returns at once when none is in flight).
    func waitForRelayModelProbeForTesting(providerID: UUID) async {
        let tasks = relayModelProbeTasks[providerID].map { Array($0.values) } ?? []
        for task in tasks { await task.value }
    }
#endif

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
        var manualModel = AIModel(
            id: modelID,
            name: ModelResolver.displayName(forManualModelID: modelID, providerKind: provider.kind),
            capabilities: orderedCaps,
            reasoningModeAvailable: mergedCaps.contains(.reasoning),
            isAvailable: true,
            isDefault: provider.kind != .relay && provider.models.isEmpty,
            priceTier: "",
            summary: provider.kind == .relay
                ? L10n.tr("Manual model")
                : L10n.tr("Manual fallback model"),
            groupKey: ModelResolver.groupKey(forManualModelID: modelID, providerKind: provider.kind),
            groupName: ModelResolver.groupName(forManualModelID: modelID, providerKind: provider.kind),
            imageGenProfile: mergedCaps.contains(.imageGen) ? "default" : nil,
            isManual: true
        )
        // An already enabled model keeps its binding; newly added ones are decided by bindCases (a single key writes nothing).
        if let enabled = provider.models.first(where: { ModelResolver.modelsShareSameRemoteModel($0, manualModel, providerKind: provider.kind) }) {
            manualModel.relayKeyID = enabled.relayKeyID
        } else if let keyID = Self.relayBoundKeyID(for: modelID, in: provider) {
            manualModel.relayKeyID = keyID
        }

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
        // The relay's negative cache is cleared as a whole entry together with the connection.
        Self.clearRelayNegativeCaches(connectionID: providerID.uuidString)
        // The connection-level web fragments live on this device only and go with the connection.
        RelayWebFragmentStore.shared.deleteConnection(providerID)
        // Web probe records live in the same layer as the negative cache and go with the connection.
        RelayWebProbeStore.shared.clearConnection(providerID.uuidString)
        // The on-device relay avatar choice goes away with the connection.
        RelayAvatarChoiceStore.shared.deleteConnection(providerID)
        ProviderAPIKeyStore.delete(providerID: providerID, uid: appState.sessionPartitionUID)
        return true
    }


    @discardableResult
    func upsertProvider(_ provider: Provider) -> Bool {
        var p = Self.relayWriteNormalized(provider)
        if let existing = providers.first(where: { $0.id == p.id }) {
            advanceCapabilityIdentity(from: existing, to: p)
        } else {
            _ = ProviderCapabilityIdentityStore.identity(providerID: p.id, partitionID: appState.sessionPartitionUID)
        }
        p.updatedAt = Date()
        // A relay's resolve-derived fields are finalized in the background, see `scheduleRelayFinalize`.
        if p.kind != .relay {
            p.cachedAvailableModelCount = ProviderCatalogResolver.resolve(provider: p).availableModelCount
        }
        if let index = providers.firstIndex(where: { $0.id == p.id }) {
            providers[index] = p
        } else {
            providers.insert(p, at: 0)
        }
        if p.kind == .relay {
            scheduleRelayFinalize(for: p)
        }
        return true
    }

    /// Relay write-side rule: a model's isDefault is always false and `relayRequested.modelID` is always empty.
    /// This only governs writes; decoding keeps old values untouched and the read side ignores them separately.
    nonisolated static func relayWriteNormalized(_ provider: Provider) -> Provider {
        guard provider.kind == .relay else { return provider }
        var p = provider
        if p.models.contains(where: \.isDefault) {
            p.models = ModelResolver.clearingDefaultFlags(p.models)
        }
        if p.catalogModels.contains(where: \.isDefault) {
            p.catalogModels = ModelResolver.clearingDefaultFlags(p.catalogModels)
        }
        if p.relayRequested?.modelID != nil {
            p.relayRequested = p.relayRequested?.withoutModelID
        }
        return p
    }

    func updateProvider(_ provider: Provider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        var p = Self.relayWriteNormalized(provider)
        advanceCapabilityIdentity(from: providers[index], to: p)
        if providers[index].authMode != p.authMode {
            ToolCallMemoryStore.shared.clear(connectionID: p.id)
        }
        p.updatedAt = Date()
        // A relay's resolve-derived fields are finalized in the background, see `scheduleRelayFinalize`.
        if p.kind != .relay {
            p.cachedAvailableModelCount = ProviderCatalogResolver.resolve(provider: p).availableModelCount
        }
        let replacedKeyIDs = Self.relayReplacedSecretKeyIDs(from: providers[index], to: p)
        providers[index] = p
        if p.kind == .relay {
            scheduleRelayFinalize(for: p)
        }
        // Every entry that replaces a value (replaceSecret on the key page, replacing the single key, saving an edited
        // connection with a changed key) ends up here, so it is decided once at the write.
        relayKeySecretsReplaced(providerID: p.id, keyIDs: replacedKeyIDs)
    }

    /// Ids of keys that are in the list both before and after, whose value changed and whose new value is non-empty;
    /// adding, deleting, renaming or reordering never changes a key's own value and does not count.
    private static func relayReplacedSecretKeyIDs(from old: Provider, to new: Provider) -> Set<String> {
        guard old.kind == .relay, new.kind == .relay else { return [] }
        let oldIDs = Set(RelayKeyBinding.keyIDs(old))
        return Set(RelayKeyBinding.keyIDs(new).filter { keyID in
            guard oldIDs.contains(keyID) else { return false }
            let secret = ProviderCredentialResolver.secret(provider: new, keyID: keyID)
            return !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && secret != ProviderCredentialResolver.secret(provider: old, keyID: keyID)
        })
    }

    /// Finalizes a relay write: the cached available-model count and the enriched capabilities written back into
    /// the models both derive from `ProviderCatalogResolver.resolve` over the whole catalog. A relay catalog comes
    /// from the user's own server (tens of thousands of models on some public relays), and enriching each one
    /// against every official catalog takes hundreds of milliseconds on the main thread. The caller has already
    /// stored the user's change synchronously; this only fills in the derived fields in the background.
    ///
    /// Ordering: the result is only merged into a Provider that is still exactly this write. Any later write (a
    /// new update/upsert always carries a new `updatedAt`, and a delete removes it) invalidates it. The newer write
    /// schedules its own finalize, so a result computed from older input never overwrites newer state and never
    /// brings a deleted Provider back.
    private func scheduleRelayFinalize(for written: Provider) {
        relayFinalizeTasks[written.id]?.cancel()
        // `self?.` keeps this object alive across the await but not the unowned AppState; hold AppState too so the
        // commit never reads a dangling reference.
        relayFinalizeTasks[written.id] = Task { [weak self, appStateRetainer = appState as AppState?] in
            _ = appStateRetainer
            let finalized = await Task.detached(priority: .userInitiated) {
                Self.relayFinalized(written)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.commitRelayFinalize(finalized, over: written)
        }
    }

    private func commitRelayFinalize(_ finalized: Provider, over written: Provider) {
        guard let index = providers.firstIndex(where: { $0.id == written.id }) else {
            relayFinalizeTasks[written.id] = nil
            return
        }
        guard providers[index] == written else { return }
        relayFinalizeTasks[written.id] = nil
        guard finalized != written else { return }
        providers[index] = finalized
    }

    /// Pure function: reads only the Provider value and MetadataClient's shared, lock-protected snapshot, so it can
    /// run on a background thread.
    nonisolated private static func relayFinalized(_ provider: Provider) -> Provider {
        let resolved = ProviderCatalogResolver.resolve(provider: provider)
        var p = provider
        p.cachedAvailableModelCount = resolved.availableModelCount
        // Write the enriched capabilities back into catalogModels and models, so the chat screen sees
        // per-model selections plus the capabilities of catalog matches when it reads provider.allModels.
        return applyRelayEnrichment(to: p, resolved: resolved)
    }

#if DEBUG
    /// Test-only: waits for this Provider's current relay finalize task (returns at once when none is in flight).
    func waitForRelayFinalizeForTesting(providerID: UUID) async {
        await relayFinalizeTasks[providerID]?.value
    }
#endif

    private func advanceCapabilityIdentity(from old: Provider, to new: Provider) {
        let partitionID = appState.sessionPartitionUID
        if ProviderCredentialResolver.apiKey(provider: old, modelID: nil) != ProviderCredentialResolver.apiKey(provider: new, modelID: nil) {
            ProviderCapabilityIdentityStore.advanceCredentialEpoch(providerID: new.id, partitionID: partitionID)
        }
        let connectionChanged = old.kind != new.kind
            || old.baseURLText != new.baseURLText
            || old.relayRequested != new.relayRequested
        if connectionChanged {
            ProviderCapabilityIdentityStore.advanceConnectionGeneration(providerID: new.id, partitionID: partitionID)
        }
    }

    nonisolated private static func applyRelayEnrichment(to provider: Provider, resolved: ResolvedProviderCatalog) -> Provider {
        var p = provider
        let enrichedById = resolved.catalog.reduce(into: [String: AIModel]()) { result, entry in
            if result.index(forKey: entry.model.id) == nil {
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
             .rateLimited, .emptyModelCatalog, .network, .upstream, .emptyResponse,
             .additionalRequestBodyRejected, .customFieldsRejected, .attachmentTextOverLimit:
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
