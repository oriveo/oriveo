import Foundation

class BaseAPIService {

    let session: URLSession
    let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        decoder = JSONDecoder()
    }

    // MARK: - HTTP Headers

    func applyHeaders(to request: inout URLRequest, apiKey: String) {
        applyJSONHeaders(to: &request)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    func applyJSONHeaders(to request: inout URLRequest, includeAccept: Bool = true) {
        if includeAccept {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(UserAgentProvider.nativeUserAgent, forHTTPHeaderField: "User-Agent")
    }

    func reasoningEffortFromProfile(
        providerKind: ProviderKind,
        modelID: String,
        reasoningMode: ReasoningMode
    ) -> String? {
        let resolved = MetadataClient.shared.syncResolveCatalogModel(
            modelID: modelID,
            providerKind: providerKind
        )
        return ProfileParamsResolver.reasoningMergeParams(
            providerKind: providerKind,
            modelID: modelID,
            reasoningMode: reasoningMode,
            resolved: resolved
        )?["reasoning_effort"] as? String
    }


    func encodeChatBody(
        _ body: inout [String: Any],
        options: ChatRequestOptions,
        resolved: MetadataClient.ResolvedModelMetadata?,
        finalRequest: URLRequest? = nil
    ) throws -> Data {
        ProfileParamsResolver.applyTemperatureGate(to: &body, resolved: resolved)
        ProfileParamsResolver.applyGenerationParameters(
            to: &body,
            options: options,
            profile: resolved?.generationProfile,
            finalRequest: finalRequest,
            effectiveTransport: resolved?.transport
        )
        // This is the actual final chat body boundary for all OpenAI-compatible providers:
        // generation/profile writes have finished, while JSON encoding has not begun. Applying the
        // lossless owner-scoped fragment here prevents a later default from silently overriding it.
        if !options.localSafeCustomBodyFragments.isEmpty {
            guard let identity = CapabilityEvidenceRequestContext.current?.query,
                  let providerKind = ProviderKind(rawValue: identity.providerKind) else {
                throw ProviderServiceError.invalidConfiguration(detail: "Rejected safe custom fragment: unknown_path")
            }
            try CapabilityRecipeExecution.applySafeCustomFragments(
                options.localSafeCustomBodyFragments, to: &body,
                providerKind: providerKind,
                modelID: identity.modelID,
                transport: resolved?.transport ?? identity.effectiveTransport
            )
        }
        let encoded = try JSONSerialization.data(withJSONObject: body)
        // This is the sole final body boundary.  Do not mark requested from HTTP status or from a
        // preflight compilation; only a successfully encoded final wire body earns the fact.
        CapabilityExecutionRuntime.confirmFinalWireEncoded()
        return encoded
    }


    func perform<T: Decodable>(_ request: URLRequest, isRelay: Bool = false) async throws -> T {
        let data: Data
        let response: URLResponse

        do {
            CapabilityExecutionRuntime.confirmRequestDispatched()
            (data, response) = try await session.relayData(for: request)
        } catch {
            throw ProviderServiceError.network(detail: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderServiceError.network(detail: "Missing HTTPURLResponse.")
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw mapHTTPError(statusCode: httpResponse.statusCode, data: data, request: request, isRelay: isRelay)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ProviderServiceError.network(detail: "Decoding failed: \(error.localizedDescription)")
        }
    }

    func performRaw(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse

        do {
            CapabilityExecutionRuntime.confirmRequestDispatched()
            (data, response) = try await session.relayData(for: request)
        } catch {
            throw ProviderServiceError.network(detail: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderServiceError.network(detail: "Missing HTTPURLResponse.")
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw mapHTTPError(statusCode: httpResponse.statusCode, data: data, request: request)
        }

        return (data, httpResponse)
    }


    struct ImagesAPIResponse: Decodable {
        struct Datum: Decodable {
            var b64_json: String?
            var url: String?
            var mime_type: String?
        }
        var data: [Datum]?

        var resolvedAttachments: [Attachment] {
            (data ?? []).compactMap { datum in
                let mime = (datum.mime_type?.isEmpty == false) ? datum.mime_type! : "image/png"
                let ext = mime.contains("jpeg") || mime.contains("jpg") ? "jpg"
                    : (mime.contains("webp") ? "webp" : "png")
                if let b64 = datum.b64_json, !b64.isEmpty {
                    return Attachment(id: UUID(), kind: .image, fileName: "generated_image.\(ext)", mimeType: mime, base64Data: b64)
                }
                if let urlString = datum.url, !urlString.isEmpty {
                    return Attachment(id: UUID(), kind: .image, fileName: "generated_image.\(ext)", mimeType: mime, base64Data: urlString)
                }
                return nil
            }
        }
    }

    func generateImageViaImagesAPI(
        apiKey: String,
        modelID: String,
        prompt: String,
        url: URL,
        requestDefaults: [String: Any]?
    ) async throws -> [Attachment] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        applyHeaders(to: &request, apiKey: apiKey)

        var payload: [String: Any] = ["model": modelID, "prompt": prompt]
        if let requestDefaults {
            for (key, value) in requestDefaults { payload[key] = value }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, _) = try await performRaw(request)
        let decoded: ImagesAPIResponse
        do {
            decoded = try decoder.decode(ImagesAPIResponse.self, from: data)
        } catch {
            throw ProviderServiceError.network(detail: "Decoding failed: \(error.localizedDescription)")
        }
        let attachments = decoded.resolvedAttachments
        guard !attachments.isEmpty else { throw ProviderServiceError.emptyResponse }
        return attachments
    }


    func imageRouteOrThrow(resolved: MetadataClient.ResolvedModelMetadata?) throws -> ImageGenRoute? {
        guard resolved?.capabilities.contains(.imageGen) == true else { return nil }
        let raw = MetadataClient.shared.syncImageGenRoute(profileName: resolved?.profiles.imageGen)
        guard let raw, let route = ImageGenRoute(rawValue: raw) else {
            throw ProviderServiceError.invalidConfiguration(
                detail: L10n.tr(
                    "This image model is missing a valid image generation route in its server profile. Please update the app or contact support.",
                    table: .providers
                )
            )
        }
        return route
    }

    func dispatchOfficialImageGeneration(
        providerKind: ProviderKind,
        userBaseURL: String?,
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        selectedModelSupportsImageGeneration: Bool
    ) async throws -> OfficialImageGenerationDispatch {
        guard providerKind != .relay else {
            return .notApplicable
        }

        await MetadataClient.shared.ensureInitialized()
        let resolved = MetadataClient.shared.syncResolveCatalogModel(
            modelID: modelID,
            providerKind: providerKind
        )
        let metadataDeclaresImageGeneration = resolved?.capabilities.contains(.imageGen) == true
        guard selectedModelSupportsImageGeneration || metadataDeclaresImageGeneration else {
            return .notApplicable
        }
        guard resolved != nil,
              let route = try imageRouteOrThrow(resolved: resolved) else {
            throw ProviderServiceError.invalidConfiguration(
                detail: L10n.tr(
                    "This image model is missing a valid image generation route in its server profile. Please update the app or contact support.",
                    table: .providers
                )
            )
        }

        guard route == .imagesAPI else {
            return .providerSpecific(route)
        }

        try validateAPIKey(apiKey)
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderServiceError.invalidConfiguration(detail: "Missing model identifier.")
        }
        guard let prompt = messages.reversed()
            .first(where: { $0.role == .user })?
            .text
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            throw ProviderServiceError.invalidConfiguration(
                detail: "Image generation requires a text prompt."
            )
        }

        let rawUserBase = userBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUserBase = rawUserBase.flatMap { value -> String? in
            guard !value.isEmpty else { return nil }
            return value.hasPrefix("http://") || value.hasPrefix("https://")
                ? value
                : "https://\(value)"
        }
        let endpoint: EndpointResolver.ResolvedEndpoint
        do {
            endpoint = try EndpointResolver.resolve(
                providerKind: providerKind,
                userBaseURL: normalizedUserBase,
                kind: .images,
                metadataTransport: MetadataClient.shared.syncProviderTransport(providerKind: providerKind)
            )
        } catch {
            throw ProviderServiceError.invalidConfiguration(
                detail: "Invalid image generation endpoint."
            )
        }

        let requestDefaults = MetadataClient.shared.syncImageGenRequestDefaults(
            profileName: resolved?.profiles.imageGen
        )
        let attachments = try await generateImageViaImagesAPI(
            apiKey: apiKey,
            modelID: modelID,
            prompt: prompt,
            url: endpoint.url,
            requestDefaults: requestDefaults
        )
        return .handled(
            ProviderChatResult(
                text: "",
                promptTokens: 0,
                completionTokens: 0,
                estimatedCost: 0,
                attachments: attachments
            )
        )
    }

    func generateImageViaMiniMaxImageGeneration(
        apiKey: String,
        modelID: String,
        prompt: String,
        url: URL,
        requestDefaults: [String: Any]?
    ) async throws -> [Attachment] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        applyHeaders(to: &request, apiKey: apiKey)

        var payload: [String: Any] = ["model": modelID, "prompt": prompt]
        if let requestDefaults {
            for (key, value) in requestDefaults { payload[key] = value }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, _) = try await performRaw(request)
        let decoded: MiniMaxImageGenerationResponse
        do {
            decoded = try decoder.decode(MiniMaxImageGenerationResponse.self, from: data)
        } catch {
            throw ProviderServiceError.network(detail: "Decoding failed: \(error.localizedDescription)")
        }
        let attachments = decoded.resolvedAttachments
        guard !attachments.isEmpty else { throw ProviderServiceError.emptyResponse }
        return attachments
    }

    func generateImageViaDashscopeMultimodal(
        apiKey: String,
        modelID: String,
        prompt: String,
        url: URL,
        requestDefaults: [String: Any]?
    ) async throws -> [Attachment] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        applyHeaders(to: &request, apiKey: apiKey)

        var payload: [String: Any] = [
            "model": modelID,
            "input": ["messages": [["role": "user", "content": [["text": prompt]]]]],
        ]
        if let requestDefaults {
            payload["parameters"] = requestDefaults
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, _) = try await performRaw(request)
        let decoded: DashscopeMultimodalImageResponse
        do {
            decoded = try decoder.decode(DashscopeMultimodalImageResponse.self, from: data)
        } catch {
            throw ProviderServiceError.network(detail: "Decoding failed: \(error.localizedDescription)")
        }
        let attachments = decoded.resolvedAttachments
        guard !attachments.isEmpty else { throw ProviderServiceError.emptyResponse }
        return attachments
    }

    /// Compatibility-named single-attempt executor. stops all automatic pre-strip/retry; only
    /// a structured exact locator may write the separate dormant cache and surface explicit resend.
    func performRawWithUnsupportedParamSelfHeal(
        providerKind: ProviderKind,
        modelID: String,
        effectiveTransport: String? = nil,
        relayEngineProfile: String? = nil,
        relayDeclaredProfile: GenerationProfileRef? = nil,
        shouldReturnWithoutMapping: (_ statusCode: Int, _ data: Data, _ request: URLRequest) -> Bool = { _, _, _ in false },
        makeRequest: (_ droppedParams: Set<String>) throws -> URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let request = try makeRequest([])
        let data: Data
        let response: URLResponse
        do {
            CapabilityExecutionRuntime.confirmRequestDispatched()
            (data, response) = try await session.relayData(for: request)
        } catch {
            throw ProviderServiceError.network(detail: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderServiceError.network(detail: "Missing HTTPURLResponse.")
        }
        guard !(200 ..< 300).contains(http.statusCode) else { return (data, http) }
        if shouldReturnWithoutMapping(http.statusCode, data, request) { return (data, http) }
        let mapped = mapHTTPError(statusCode: http.statusCode, data: data, url: request.url, request: request)
        recordCapabilityUpstreamRejection(
            mappedError: mapped, errorData: data,
            providerKind: providerKind, modelID: modelID,
            request: request, effectiveTransport: effectiveTransport,
            relayEngineProfile: relayEngineProfile, relayDeclaredProfile: relayDeclaredProfile
        )
        throw mapped
    }

    /// Streaming companion of the single-attempt executor above.
    func bytesWithUnsupportedParamSelfHeal(
        providerKind: ProviderKind,
        modelID: String,
        request originalRequest: URLRequest,
        effectiveTransport: String? = nil,
        relayEngineProfile: String? = nil,
        relayDeclaredProfile: GenerationProfileRef? = nil,
        subscriptionLane: SubscriptionLane? = nil
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        CapabilityExecutionRuntime.confirmRequestDispatched()
        let (bytes, response) = try await session.relayBytes(for: originalRequest)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderServiceError.network(detail: "Missing HTTPURLResponse.")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            let mapped = mapHTTPError(
                statusCode: http.statusCode, data: errorData,
                url: originalRequest.url, request: originalRequest,
                subscriptionLane: subscriptionLane
            )
            recordCapabilityUpstreamRejection(
                mappedError: mapped, errorData: errorData,
                providerKind: providerKind, modelID: modelID,
                request: originalRequest, effectiveTransport: effectiveTransport,
                relayEngineProfile: relayEngineProfile, relayDeclaredProfile: relayDeclaredProfile
            )
            throw mapped
        }
        return (bytes, response)
    }

    func recordCapabilityUpstreamRejection(
        mappedError: ProviderServiceError,
        errorData: Data,
        providerKind: ProviderKind,
        modelID: String,
        request: URLRequest,
        effectiveTransport: String?,
        relayEngineProfile: String?,
        relayDeclaredProfile: GenerationProfileRef?
    ) {
        guard case let ProviderServiceError.upstream(statusCode, detail) = mappedError,
              statusCode == 400,
              CapabilityExecutionRuntime.canOfferExplicitCustomRetry() else { return }
        _ = detail // Structured recovery intentionally ignores the human-readable error message.
        let rejections = CapabilityExecutionRuntime.recordUpstreamRejection(
            statusCode: statusCode, errorData: errorData
        )
        guard !rejections.isEmpty else { return }
        let identity = effectiveTransport.map {
            CapabilityEvidenceRequestContext.generationScope(
                for: request,
                effectiveTransport: $0,
                relayEngineProfile: relayEngineProfile,
                relayDeclaredProfile: relayDeclaredProfile
            )
        } ?? CapabilityEvidenceRequestContext.scope(for: request)
        guard let identity else { return }
        for rejection in rejections {
            guard let scopedIdentity = identity.resolvingRuntimeRevision(rejection.runtimeRevision) else { continue }
            if rejection.source == .providerRecipe {
                for pointer in rejection.locatedPointers {
                    let capabilityKeys: [String?] = rejection.capabilityKeys.isEmpty
                        ? [nil]
                        : rejection.capabilityKeys.sorted().map { Optional($0) }
                    for key in capabilityKeys {
                        UnsupportedParamCache.shared.markCapabilityRejected(
                            providerKind: providerKind,
                            modelID: scopedIdentity.query.effectiveModelID,
                            source: .providerRecipe,
                            owner: rejection.owner,
                            recipeRef: rejection.recipeRef,
                            setting: pointer,
                            capabilityKey: key,
                            endpointFingerprint: scopedIdentity.query.endpointFingerprint,
                            identity: scopedIdentity
                        )
                    }
                }
            } else {
                UnsupportedParamCache.shared.markCapabilityRejected(
                    providerKind: providerKind,
                    modelID: scopedIdentity.query.effectiveModelID,
                    source: .custom,
                    owner: rejection.owner,
                    setting: "owner:\(rejection.owner)",
                    endpointFingerprint: scopedIdentity.query.endpointFingerprint,
                    identity: scopedIdentity
                )
            }
        }
    }


    typealias SubscriptionLane = ProviderServiceError.SubscriptionLane

    func mapHTTPError(
        statusCode: Int,
        data: Data,
        url: URL? = nil,
        request: URLRequest? = nil,
        subscriptionLane: SubscriptionLane? = nil,
        isRelay: Bool = false
    ) -> ProviderServiceError {
        let upstreamSnippet = decodeErrorMessage(from: data, request: request)
        let detail = upstreamSnippet
            ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)

        if let subscriptionFailure = Self.subscriptionFailure(
            statusCode: statusCode, detail: detail, lane: subscriptionLane
        ) {
            return subscriptionFailure
        }

        // `{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}`
        if isRelay,
           let relayGuidance = Self.relayGuidanceFailure(
               statusCode: statusCode, data: data, url: url, upstreamSnippet: upstreamSnippet
           ) {
            return relayGuidance
        }

        let lowerBody = (String(data: data, encoding: .utf8) ?? "").lowercased()
        // Providers based in China return these error bodies in Chinese.
        let isQuota = lowerBody.range(of: "quota|daily limit|used up|insufficient quota|credit|billing hard limit|allowance|免费额度|额度已用完|额度耗尽|配额已用完", options: .regularExpression) != nil
        let isUnavailable = lowerBody.range(of: "temporarily unavailable|currently unavailable|not available|disabled|offline|maintenance|暂不可用|不可用|已停用|维护", options: .regularExpression) != nil

        switch statusCode {
        case 401, 403:
            if isQuota { return .quotaExceeded(detail: detail) }
            if isUnavailable { return .modelUnavailable(detail: detail) }
            return .invalidAPIKey(detail: detail)
        case 402:
            return .quotaExceeded(detail: detail)
        case 429:
            if isQuota { return .quotaExceeded(detail: detail) }
            if isUnavailable { return .modelUnavailable(detail: detail) }
            return .rateLimited(detail: detail)
        case 500...599:
            if isUnavailable { return .modelUnavailable(detail: detail) }
            return .upstream(statusCode: statusCode, detail: detail)
        default:
            return .upstream(statusCode: statusCode, detail: detail)
        }
    }

    private static func relayGuidanceFailure(
        statusCode: Int,
        data: Data,
        url: URL?,
        upstreamSnippet: String?
    ) -> ProviderServiceError? {
        let urlPath = url?.path ?? ""

        if statusCode == 403,
           let body = String(data: data, encoding: .utf8),
           Self.isCodexClientIdentityRejection(body) {
            return .upstream(
                statusCode: 403,
                detail: Self.relayGuidanceDetail(
                    L10n.tr("This relay still rejects Oriveo's Codex client identity. Try setting a custom User-Agent under Edit → Advanced HTTP, or switch to another relay / contact its administrator (the upstream account may be unauthorized or rate-limited).", table: .providers),
                    upstreamSnippet: upstreamSnippet
                )
            )
        }

        if statusCode == 404, urlPath.hasSuffix("/images/generations") {
            return .upstream(
                statusCode: 404,
                detail: Self.relayGuidanceDetail(
                    L10n.tr("This relay does not offer a dedicated image endpoint. Open Providers → this Relay → Advanced Settings → Transport and switch it to OpenAI Responses. Oriveo will then use the inline image tool path instead.", table: .providers),
                    upstreamSnippet: upstreamSnippet
                )
            )
        }

        if statusCode == 404,
           urlPath.contains("/chat/completions"),
           let url, Self.isCodexStyleHost(url) {
            return .upstream(
                statusCode: 404,
                detail: Self.relayGuidanceDetail(
                    L10n.tr("This relay only exposes /v1/responses and rejects /chat/completions. Open Providers → this Relay → Edit → Relay type and switch to “Codex style (Responses)”, then retry.", table: .providers),
                    upstreamSnippet: upstreamSnippet
                )
            )
        }

        if statusCode == 400, urlPath.hasSuffix("/images/generations"),
           let body = String(data: data, encoding: .utf8),
           body.localizedCaseInsensitiveContains("response_format") {
            return .upstream(
                statusCode: 400,
                detail: Self.relayGuidanceDetail(
                    L10n.tr("This image model does not accept the response_format parameter. Rename the model to start with gpt-image- or chatgpt-image-, or try a different image model ID.", table: .providers),
                    upstreamSnippet: upstreamSnippet
                )
            )
        }

        if statusCode == 502, let body = String(data: data, encoding: .utf8),
           Self.isUpstreamRelayError(body) {
            return .upstream(
                statusCode: 502,
                detail: Self.relayGuidanceDetail(
                    L10n.tr("The relay could not reach its upstream provider. This is not your configuration — the relay administrator's upstream account may be invalid, out of credits, or rate-limited. Please switch to another relay or contact its administrator.", table: .providers),
                    upstreamSnippet: upstreamSnippet
                )
            )
        }

        if (statusCode == 404 || statusCode == 400),
           let body = String(data: data, encoding: .utf8),
           Self.isUpstreamModelUnavailable(body) {
            return .upstream(
                statusCode: statusCode,
                detail: Self.relayGuidanceDetail(
                    L10n.tr("The relay's upstream does not offer this model. Open Providers → this Relay → Edit → Model and change it to one your relay actually supports (e.g. gpt-5.4). You can ask your relay administrator for the exact list of available model IDs.", table: .providers),
                    upstreamSnippet: upstreamSnippet
                )
            )
        }

        if statusCode == 400, let body = String(data: data, encoding: .utf8),
           Self.isUpstreamResponsesProtocolMismatch(body) {
            return .upstream(
                statusCode: 400,
                detail: Self.relayGuidanceDetail(
                    L10n.tr("This relay requires the OpenAI Responses protocol. Open Providers → this Relay → Edit → Relay type and switch to “Codex style (Responses)”, then retry.", table: .providers),
                    upstreamSnippet: upstreamSnippet
                )
            )
        }

        if statusCode == 400, let body = String(data: data, encoding: .utf8),
           Self.isUnknownStoreParameter(body) {
            return .upstream(
                statusCode: 400,
                detail: Self.relayGuidanceDetail(
                    L10n.tr("This relay rejects the “store/disable_response_storage” field. Open Providers → this Relay → Edit → Compatibility and turn off “Don't keep responses in the cloud”, then retry.", table: .providers),
                    upstreamSnippet: upstreamSnippet
                )
            )
        }

        if statusCode == 400, let body = String(data: data, encoding: .utf8),
           Self.isInvalidServiceTier(body) {
            return .upstream(
                statusCode: 400,
                detail: Self.relayGuidanceDetail(
                    L10n.tr("This relay does not accept the current OpenAI service tier value. Open Providers → this Relay → Edit → Compatibility and clear “OpenAI service tier”, then retry.", table: .providers),
                    upstreamSnippet: upstreamSnippet
                )
            )
        }

        if statusCode == 400, let body = String(data: data, encoding: .utf8),
           Self.isMissingMaxTokens(body) {
            return .upstream(
                statusCode: 400,
                detail: Self.relayGuidanceDetail(
                    L10n.tr("This relay requires the “max_tokens” parameter. Open the model settings for this relay and set a max_tokens value (e.g. 4096), then retry.", table: .providers),
                    upstreamSnippet: upstreamSnippet
                )
            )
        }

        if (statusCode == 401 || statusCode == 403),
           let body = String(data: data, encoding: .utf8),
           Self.isAnthropicAuthMismatch(body) {
            return .invalidAPIKey(
                detail: Self.relayGuidanceDetail(
                    L10n.tr("This relay expects an Anthropic-style x-api-key header. Open Providers → this Relay → Edit → Auth and switch to “x-api-key”, then retry.", table: .providers),
                    upstreamSnippet: upstreamSnippet
                )
            )
        }

        if statusCode == 400, let body = String(data: data, encoding: .utf8),
           Self.isImageUrlSchemaMismatch(body) {
            return .upstream(
                statusCode: 400,
                detail: Self.relayGuidanceDetail(
                    L10n.tr("Image attachments use the wrong schema for this relay's protocol. The model and protocol may not match — open Providers → this Relay → Edit → Relay type and switch to a type that fits your model, then retry.", table: .providers),
                    upstreamSnippet: upstreamSnippet
                )
            )
        }

        return nil
    }

    static func subscriptionFailure(
        statusCode: Int,
        detail: String,
        lane: SubscriptionLane?
    ) -> ProviderServiceError? {
        guard let lane else { return nil }
        let kind: ProviderServiceError.SubscriptionFailureKind
        switch statusCode {
        case 401: kind = .expired
        case 403: kind = .ineligible
        case 426: kind = .unavailable
        case 429: kind = .quotaExhausted
        default: return nil
        }
        let messageKey: String
        switch lane {
        case .grok:
            let error: GrokSubscriptionError
            switch kind {
            case .expired: error = .unauthorized
            case .ineligible: error = .subscriptionNotEligible
            case .unavailable: error = .clientVersionRejected
            case .quotaExhausted: error = .quotaExhausted
            }
            messageKey = error.userFacingMessageKey
        case .openAI:
            let error: OpenAISubscriptionError
            switch kind {
            case .expired: error = .unauthorized
            case .ineligible: error = .subscriptionNotEligible
            case .unavailable: error = .clientVersionRejected
            case .quotaExhausted: error = .quotaExhausted
            }
            messageKey = error.userFacingMessageKey
        }
        return .subscriptionFailure(lane: lane, kind: kind, messageKey: messageKey, detail: detail)
    }

    private static func isCodexClientIdentityRejection(_ body: String) -> Bool {
        let needles = [
            "Codex official clients",
            "Codex 官方客户端",      // Simplified Chinese
            "Codex 官方客戶端",      // Traditional Chinese
            "Codex 公式クライアント",  // Japanese
            "Codex 공식 클라이언트"    // Korean
        ]
        return needles.contains { body.localizedCaseInsensitiveContains($0) }
    }

    /// - `{"error":{"message":"Upstream timeout","type":"upstream_error"}}`
    /// - `{"error":{"message":"upstream service unavailable"}}`
    private static func isUpstreamRelayError(_ body: String) -> Bool {
        let needles = [
            "upstream_error",
            "Upstream authentication",
            "Upstream timeout",
            "upstream service",
            "上游认证",
            "上游服务"
        ]
        return needles.contains { body.localizedCaseInsensitiveContains($0) }
    }

    private static func isUpstreamResponsesProtocolMismatch(_ body: String) -> Bool {
        body.localizedCaseInsensitiveContains("Unknown parameter") && body.contains("input[")
    }

    private static func isCodexStyleHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let codexHosts = ["packy", "ylsagi", "code-for", "ccswitch", "cc-switch", "codex"]
        return codexHosts.contains(where: host.contains)
    }

    private static func isUnknownStoreParameter(_ body: String) -> Bool {
        let lower = body.lowercased()
        guard lower.contains("unknown parameter") || lower.contains("unrecognized parameter") else {
            return false
        }
        return lower.contains("'store'") || lower.contains("\"store\"")
            || lower.contains("disable_response_storage")
    }

    private static func isInvalidServiceTier(_ body: String) -> Bool {
        let lower = body.lowercased()
        guard lower.contains("service_tier") || lower.contains("service tier") else { return false }
        return lower.contains("invalid") || lower.contains("not allowed") || lower.contains("unsupported")
    }

    private static func isMissingMaxTokens(_ body: String) -> Bool {
        let lower = body.lowercased()
        guard lower.contains("max_tokens") else { return false }
        return lower.contains("required") || lower.contains("must include")
            || lower.contains("missing") || lower.contains("缺少")
    }

    private static func isAnthropicAuthMismatch(_ body: String) -> Bool {
        let lower = body.lowercased()
        let xApiKeyHints = lower.contains("x-api-key") || lower.contains("anthropic-version")
        let authErrorHints = lower.contains("authentication_error") || lower.contains("authentication failed")
        return xApiKeyHints && authErrorHints
    }

    private static func isImageUrlSchemaMismatch(_ body: String) -> Bool {
        let lower = body.lowercased()
        guard lower.contains("image_url") || lower.contains("image content") else { return false }
        return lower.contains("invalid") || lower.contains("not allowed")
            || lower.contains("unknown") || lower.contains("unsupported")
    }

    private static func isUpstreamModelUnavailable(_ body: String) -> Bool {
        let needles = [
            "不支持的模型",
            "請更換模型",     // Traditional Chinese
            "模型不存在",
            "model_not_found",
            "model not found",
            "model is not supported",
            "No available channel for model",
            "无可用渠道",
            "invalid model",
            "unknown model"
        ]
        return needles.contains { body.localizedCaseInsensitiveContains($0) }
    }

    private static func relayGuidanceDetail(_ guidance: String, upstreamSnippet: String?) -> String {
        guard let upstreamSnippet, !upstreamSnippet.isEmpty else { return guidance }
        return "\(guidance)\nUpstream error: \(upstreamSnippet)"
    }

    func decodeErrorMessage(from data: Data, request: URLRequest? = nil) -> String? {
        RelayErrorSnippet.extract(
            from: data,
            redacting: request.map(RelayRequestSecurity.credentialMaterial(in:)) ?? []
        )
    }


    /// - Parameters:
    func parseSSEStream(
        from bytes: URLSession.AsyncBytes,
        doneToken: String = "[DONE]",
        onLine: @escaping (String) throws -> SSELineResult
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.utf8Lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == doneToken { break }

                        do {
                            let result = try onLine(payload)
                            switch result {
                            case .events(let events):
                                for event in events {
                                    continuation.yield(event)
                                }
                            case .skip:
                                continue
                            }
                        } catch {
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func parseAnthropicSSEStream(
        from bytes: URLSession.AsyncBytes,
        onEvent: @escaping (String, String) throws -> SSELineResult
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var currentEvent = ""
                    for try await line in bytes.utf8Lines {
                        if Task.isCancelled { break }

                        if line.hasPrefix("event: ") {
                            currentEvent = String(line.dropFirst(7))
                            continue
                        }

                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))

                        do {
                            let result = try onEvent(currentEvent, payload)
                            switch result {
                            case .events(let events):
                                for event in events {
                                    continuation.yield(event)
                                }
                            case .skip:
                                break
                            }
                        } catch {
                        }
                        currentEvent = ""
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }


    func inlineTextFiles(text: String, fileAttachments: [Attachment]) -> (combinedText: String, binaryFiles: [Attachment]) {
        var textParts = [text]
        var binaryFiles: [Attachment] = []

        for f in fileAttachments {
            let b64 = f.resolvedBase64Data
            if let data = Data(base64Encoded: b64),
               let content = String(data: data, encoding: .utf8) {
                textParts.append("[\(f.fileName)]\n\(content)")
            } else {
                binaryFiles.append(f)
            }
        }

        return (textParts.joined(separator: "\n\n"), binaryFiles)
    }


    func markDefaultModel(in models: [AIModel], scoreFn: (AIModel) -> Int) -> [AIModel] {
        guard let preferredIndex = models.indices.max(by: { scoreFn(models[$0]) < scoreFn(models[$1]) }) else {
            return models
        }
        return models.enumerated().map { index, model in
            var m = model
            m.isDefault = index == preferredIndex
            return m
        }
    }

    func catalogModelSort(_ lhs: AIModel, _ rhs: AIModel) -> Bool {
        let lhsRank = lhs.sortRank ?? 0
        let rhsRank = rhs.sortRank ?? 0
        if lhsRank != rhsRank { return lhsRank > rhsRank }

        let lhsCreated = lhs.createdAt ?? 0
        let rhsCreated = rhs.createdAt ?? 0
        if lhsCreated != rhsCreated { return lhsCreated > rhsCreated }

        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    func selectDefaultBySortRank(_ models: [AIModel]) -> [AIModel] {
        if models.contains(where: \.isDefault) { return models }

        let available = models.filter(\.isAvailable)
        let pool = available.isEmpty ? models : available
        guard let best = pool.max(by: { ($0.sortRank ?? 0) < ($1.sortRank ?? 0) }) else {
            return models
        }

        return models.map { model in
            var m = model
            m.isDefault = m.id == best.id
            return m
        }
    }


    func validateAPIKey(_ apiKey: String) throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderServiceError.invalidAPIKey(detail: "API key is empty.")
        }
    }

    func normalizedBaseURL(_ baseURL: String?, default defaultBaseURL: String) -> String {
        let trimmed = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBaseURL: String
        if let trimmed, !trimmed.isEmpty {
            rawBaseURL = trimmed
        } else {
            rawBaseURL = defaultBaseURL
        }

        let normalizedBase = rawBaseURL.hasSuffix("/") ? String(rawBaseURL.dropLast()) : rawBaseURL
        if normalizedBase.hasPrefix("http://") || normalizedBase.hasPrefix("https://") {
            return normalizedBase
        }
        return "https://\(normalizedBase)"
    }
}

enum UserAgentProvider {
    static var nativeUserAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        return "Oriveo/\(version) (iOS \(systemVersion))"
    }
}


enum ImageGenRoute: String {
    case imagesAPI = "images_api"
    case dashscopeMultimodal = "dashscope_multimodal"
    case minimaxImageGeneration = "minimax_image_generation"
    case chatAPI = "chat_api"
}

enum OfficialImageGenerationDispatch {
    case notApplicable
    case handled(ProviderChatResult)
    case providerSpecific(ImageGenRoute)
}

private struct MiniMaxImageGenerationResponse: Decodable {
    struct ImageData: Decodable {
        var image_base64: [String]?
    }
    var data: ImageData?

    var resolvedAttachments: [Attachment] {
        guard let base64Strings = data?.image_base64 else { return [] }
        return base64Strings.compactMap { base64 in
            guard !base64.isEmpty else { return nil }
            return Attachment(id: UUID(), kind: .image, fileName: "generated_image.png", mimeType: "image/png", base64Data: base64)
        }
    }
}

private struct DashscopeMultimodalImageResponse: Decodable {
    struct Output: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                struct ContentPart: Decodable { var image: String? }
                var content: [ContentPart]?
            }
            var message: Message?
        }
        var choices: [Choice]?
    }
    var output: Output?

    var resolvedAttachments: [Attachment] {
        (output?.choices ?? []).compactMap { choice in
            guard let urlString = choice.message?.content?.first(where: { $0.image != nil })?.image,
                  !urlString.isEmpty else { return nil }
            return Attachment(id: UUID(), kind: .image, fileName: "generated_image.png", mimeType: "image/png", base64Data: urlString)
        }
    }
}


enum SSELineResult {
    case events([StreamEvent])
    case skip

    static func delta(_ text: String) -> SSELineResult {
        .events([.delta(text)])
    }

    static func done(_ result: ProviderChatResult) -> SSELineResult {
        .events([.done(result)])
    }
}


private struct GenericErrorEnvelope: Decodable {
    let error: ErrorDetail?

    struct ErrorDetail: Decodable {
        let message: String?
    }
}


extension BaseAPIService {

    /// - Parameters:
    ///   - attachments: msg.attachments
    static func injectFileAttachmentsAsText(
        userText: String,
        attachments: [Attachment],
        provider: ProviderKind,
        model: AIModel?,
        imagePlaceholderText: String? = nil
    ) -> (text: String, skipped: [(fileName: String, reason: AttachmentInjector.SkipReason)]) {
        let limits = FileExtractionLimits.resolve(model: model)
        let wrapper = AttachmentWrapperVersion.resolve(provider: provider)

        var effectiveUserText = userText
        if let placeholder = imagePlaceholderText {
            let imageCount = attachments.filter { $0.kind == .image }.count
            if imageCount > 0 {
                let placeholders = Array(repeating: placeholder, count: imageCount)
                effectiveUserText = ([effectiveUserText] + placeholders)
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
            }
        }

        let fileAttachments: [(fileName: String, mimeType: String, sizeBytes: Int, extracted: ExtractedText?, errorCode: ExtractionErrorCode?)] = attachments.compactMap { att in
            guard att.kind == .file else { return nil }

            if let codeStr = att.extractionErrorCode,
               let code = ExtractionErrorCode(rawValue: codeStr) {
                return (att.fileName, att.mimeType, att.extractedSizeBytes ?? 0, nil, code)
            }

            let content = decodeAttachmentText(att.resolvedBase64Data) ?? ""
            let extracted = ExtractedText(
                content: content,
                totalLines: att.extractedTotalLines ?? content.components(separatedBy: "\n").count,
                truncated: att.extractedTruncated ?? false,
                truncationReason: nil,
                sizeBytes: att.extractedSizeBytes ?? Data(content.utf8).count
            )
            return (att.fileName, att.mimeType, extracted.sizeBytes, extracted, nil)
        }

        return AttachmentInjector.injectAll(
            intoUserText: effectiveUserText,
            fileAttachments: fileAttachments,
            limits: limits,
            wrapper: wrapper
        )
    }

    static func partitionAttachmentsByRoute(
        _ attachments: [Attachment],
        provider: ProviderKind,
        model: AIModel?
    ) -> (native: [Attachment], text: [Attachment]) {
        guard let model = model else { return ([], attachments) }
        var native: [Attachment] = []
        var text: [Attachment] = []
        for att in attachments {
            switch AttachmentRouter.decide(attachment: att, provider: provider, model: model) {
            case .native: native.append(att)
            case .clientExtract: text.append(att)
            }
        }
        return (native, text)
    }

    static func appendAttachmentSystemGuidance(
        to systemPrompt: String,
        hasAttachments: Bool
    ) -> String {
        guard hasAttachments else { return systemPrompt }
        if systemPrompt.isEmpty {
            return AttachmentInjector.systemPromptGuidance
        }
        return systemPrompt + "\n\n" + AttachmentInjector.systemPromptGuidance
    }

    private static func decodeAttachmentText(_ base64: String?) -> String? {
        guard let base64 = base64, !base64.isEmpty,
              let d = Data(base64Encoded: base64) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
