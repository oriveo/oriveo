import Foundation

struct LocalEngineConnection: Sendable {
    let engine: LocalEngineKind
    let endpoint: String
    let apiBaseURL: String
    let modelIDs: [String]
    let runtimeMetadata: [String: LocalModelRuntimeMetadata]
    let selectedModelID: String
    let requested: RelayRequestedConfig
    /// Context window: taken only from responses already received at connect time (llama.cpp `/props`, LM Studio `/api/v0/models`),
    /// with no extra request made for it; nil for other engines or when the response lacks it (the UI shows "N/A", never 0).
    var contextLength: Int? = nil
}

enum LocalEngineConnectionError: LocalizedError, Equatable {
    case invalidEndpoint
    case wrongEngine
    case engineLoading
    case noModels
    case engineStopped
    case outOfMemory
    case contextExceeded
    case timeout
    case localNetworkDenied
    case cleartextCredentials

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return L10n.tr("Invalid local address", table: .providers)
        case .wrongEngine: return L10n.tr("The service at this address is not the selected engine.", table: .providers)
        case .engineLoading: return L10n.tr("The local model is still loading.", table: .providers)
        case .noModels: return L10n.tr("No local models were found.", table: .providers)
        case .engineStopped: return L10n.tr("The local engine is not running.", table: .providers)
        case .outOfMemory: return L10n.tr("The local engine ran out of memory.", table: .providers)
        case .contextExceeded: return L10n.tr("The message exceeds this model's context window.", table: .providers)
        case .timeout: return L10n.tr("The local model took too long to load.", table: .providers)
        case .localNetworkDenied: return L10n.tr("Allow local network access in Settings.", table: .providers)
        case .cleartextCredentials:
            return L10n.tr("An unencrypted connection can't carry a key. Change the address and connection type to Public HTTPS.", table: .providers)
        }
    }
}

enum LocalEngineConnector {
    static func connect(
        engine: LocalEngineKind,
        endpoint rawEndpoint: String,
        securityMode: RelayConnectionSecurityMode,
        modelHint: String? = nil,
        apiKey: String = "",
        certificateFingerprint: String? = nil,
        channel: RelayTransport? = nil,
        session: URLSession = .shared
    ) async throws -> LocalEngineConnection {
        let inspection = try await inspect(
            engine: engine,
            endpoint: rawEndpoint,
            securityMode: securityMode,
            modelHint: modelHint,
            apiKey: apiKey,
            certificateFingerprint: certificateFingerprint,
            channel: channel,
            session: session
        )
        let endpoint = inspection.endpoint
        let requested = inspection.requested
        let selected = inspection.selected
        do {
            _ = try await OpenAIService(session: session).pingRelay(
                apiKey: apiKey,
                baseURL: requested.resolvedAPIBaseURL ?? endpoint,
                modelID: selected,
                relayRequested: requested
            )
        } catch {
            throw classifyNetworkError(error)
        }
        var connectionMetadata: [String: LocalModelRuntimeMetadata] = inspection.runtimeMetadata.isEmpty
            ? [selected: .init(loadState: .unknown, executionLocality: executionLocality(engine: engine, modelID: selected))]
            : inspection.runtimeMetadata
        for modelID in connectionMetadata.keys {
            connectionMetadata[modelID]?.engineDeclaration = inspection.declarations[modelID]
        }
        return LocalEngineConnection(
            engine: engine,
            endpoint: endpoint,
            apiBaseURL: requested.resolvedAPIBaseURL ?? endpoint,
            modelIDs: catalogModelIDs(discovered: inspection.discovered, selected: selected),
            runtimeMetadata: connectionMetadata,
            selectedModelID: selected,
            requested: requested,
            contextLength: inspection.contextLength
        )
    }

    /// Re-detect the local connection: only re-reads each model's engine declaration. No 1-token generation check and no protocol probing.
    static func readDeclarations(
        engine: LocalEngineKind,
        endpoint: String,
        securityMode: RelayConnectionSecurityMode,
        modelHint: String? = nil,
        apiKey: String = "",
        certificateFingerprint: String? = nil,
        session: URLSession = .shared
    ) async throws -> [String: EngineDeclaration] {
        try await inspect(
            engine: engine,
            endpoint: endpoint,
            securityMode: securityMode,
            modelHint: modelHint,
            apiKey: apiKey,
            certificateFingerprint: certificateFingerprint,
            channel: nil,
            session: session
        ).declarations
    }

    private struct Inspection {
        let endpoint: String
        let requested: RelayRequestedConfig
        let discovered: [String]
        let runtimeMetadata: [String: LocalModelRuntimeMetadata]
        let selected: String
        let declarations: [String: EngineDeclaration]
        let contextLength: Int?
    }

    /// Probe liveness, fetch the catalog, verify the engine identity, and parse declarations: shared by `connect` and re-detection; the generation check is not done here.
    private static func inspect(
        engine: LocalEngineKind,
        endpoint rawEndpoint: String,
        securityMode: RelayConnectionSecurityMode,
        modelHint: String?,
        apiKey: String,
        certificateFingerprint: String?,
        channel: RelayTransport?,
        session: URLSession
    ) async throws -> Inspection {
        guard supports(securityMode: securityMode) else {
            throw LocalEngineConnectionError.invalidEndpoint
        }
        let authPolicy = LocalEngineAuthenticationPolicy.policy(for: engine)
        let hasCredential = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        try validateAuthenticationPolicy(
            authPolicy,
            securityMode: securityMode,
            hasCredential: hasCredential
        )
        let endpoint: String
        do {
            endpoint = try RelayEndpointPolicy.requireConfigured(
                rawEndpoint,
                securityMode: securityMode,
                credentials: .init(authMode: authPolicy.authMode, hasKey: hasCredential)
            )
        } catch ProviderServiceError.invalidConfiguration(let reason) where reason == "cleartext_credentials" {
            throw LocalEngineConnectionError.cleartextCredentials
        } catch {
            throw LocalEngineConnectionError.invalidEndpoint
        }
        guard let template = LocalEngineTemplate.all[engine] else {
            throw LocalEngineConnectionError.wrongEngine
        }
        // The channel is connection-level, so only that engine's channel set may be taken (passed in when the add page manually picks the llama.cpp native channel).
        let transport = channel ?? engine.defaultTransport
        guard LocalEngineChannelCandidates.candidates(engineProfile: engine.rawValue).contains(transport) else {
            throw LocalEngineConnectionError.wrongEngine
        }
        let chatBase = apiBaseURL(for: endpoint, engine: engine)
        let requested = RelayRequestedConfig(
            transport: transport,
            authMode: authPolicy.authMode,
            securityMode: securityMode,
            stream: true,
            resolvedAPIBaseURL: transport == .llamacppNative
                ? LlamaCppChannelMigration.nativeRoot(fromBase: chatBase)
                : chatBase,
            engineProfile: engine.rawValue,
            certificateFingerprint: certificateFingerprint
        )

        let fingerprint = try await get(
            endpoint: endpoint,
            path: template.probePath,
            requested: requested,
            apiKey: apiKey,
            session: session
        )
        switch LocalEngineContract.classify(
            engine: engine,
            status: fingerprint.status,
            contentType: fingerprint.contentType,
            json: fingerprint.json
        ) {
        case .ready: break
        case .loading: throw LocalEngineConnectionError.engineLoading
        default: throw LocalEngineConnectionError.wrongEngine
        }

        let catalog = template.catalogPath == template.probePath
            ? fingerprint
            : try await get(endpoint: endpoint, path: template.catalogPath, requested: requested, apiKey: apiKey, session: session)
        let discovered = modelIDs(engine: engine, json: catalog.json)
        let runtimeMetadata = modelRuntimeMetadata(engine: engine, json: catalog.json, modelIDs: discovered)
        let hinted = modelHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = hinted.flatMap { $0.isEmpty ? nil : $0 } ?? discovered.first
        guard let selected else { throw LocalEngineConnectionError.noModels }

        let introspection = try await request(
            endpoint: endpoint,
            method: template.introspectionMethod,
            path: template.introspectionPath,
            jsonBody: engine == .ollama ? ["model": selected] : nil,
            requested: requested,
            apiKey: apiKey,
            session: session
        )
        guard introspectionMatches(engine: engine, snapshot: introspection) else {
            throw LocalEngineConnectionError.wrongEngine
        }
        let declarations = LocalEngineDeclarations.parse(
            engine: engine, catalogJSON: catalog.json, introspectionJSON: introspection.json
        )
        return Inspection(
            endpoint: endpoint,
            requested: requested,
            discovered: discovered,
            runtimeMetadata: runtimeMetadata,
            selected: selected,
            declarations: declarations,
            contextLength: contextLength(
                engine: engine,
                catalogJSON: catalog.json,
                introspectionJSON: introspection.json,
                selectedModelID: selected
            )
        )
    }

    /// Value of the "Context" cell on the add page's detection card: for llama.cpp take `n_ctx` from `/props`
    /// or `default_generation_settings.n_ctx`; for LM Studio take `max_context_length` from the default model's row in `/api/v0/models`;
    /// nil for other engines. Any non-positive value is treated as absent.
    nonisolated static func contextLength(
        engine: LocalEngineKind,
        catalogJSON: Any?,
        introspectionJSON: Any?,
        selectedModelID: String
    ) -> Int? {
        func positive(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber, number.intValue > 0 else { return nil }
            return number.intValue
        }
        switch engine {
        case .llamacpp:
            let props = introspectionJSON as? [String: Any]
            return positive(props?["n_ctx"])
                ?? positive((props?["default_generation_settings"] as? [String: Any])?["n_ctx"])
        case .lmstudio:
            let rows = (catalogJSON as? [String: Any])?["data"] as? [[String: Any]] ?? []
            return positive(rows.first { $0["id"] as? String == selectedModelID }?["max_context_length"])
        case .ollama, .vllm, .openwebui:
            return nil
        }
    }

    /// Auto-detection: send five read-only GETs to the endpoint and decide with `LocalEngineFingerprint`.
    /// It uses the same secure executor as `connect`; a failure on any one request only means that probe did not match, and an invalid address or nothing reachable falls to manual.
    static func fingerprint(
        endpoint rawEndpoint: String,
        securityMode: RelayConnectionSecurityMode,
        certificateFingerprint: String? = nil,
        session: URLSession = .shared
    ) async -> LocalEngineFingerprintOutcome {
        guard supports(securityMode: securityMode),
              let endpoint = try? RelayEndpointPolicy.requireConfigured(
                  rawEndpoint,
                  securityMode: securityMode,
                  credentials: .init(authMode: .none, hasKey: false)
              ) else {
            return .manual
        }
        let requested = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .none,
            securityMode: securityMode,
            stream: true,
            certificateFingerprint: certificateFingerprint
        )
        let objects = await withTaskGroup(of: (String, FingerprintObject?).self) { group in
            for path in LocalEngineFingerprint.requestPaths {
                group.addTask {
                    guard let snapshot = try? await get(
                        endpoint: endpoint, path: path, requested: requested, apiKey: "", session: session
                    ), (200..<300).contains(snapshot.status),
                    let object = snapshot.json as? [String: Any] else { return (path, nil) }
                    return (path, FingerprintObject(value: object))
                }
            }
            var result: [String: [String: Any]] = [:]
            for await (path, object) in group {
                if let object { result[path] = object.value }
            }
            return result
        }
        return LocalEngineFingerprint.evaluate(objects)
    }

    /// A read-only object produced by JSONSerialization, passed across tasks only once inside the task group.
    private struct FingerprintObject: @unchecked Sendable {
        let value: [String: Any]
    }

    nonisolated static func catalogModelIDs(discovered: [String], selected: String) -> [String] {
        discovered.contains(selected) ? discovered : [selected] + discovered
    }

    /// Lightweight discovery proof. It verifies the selected engine's signature through the
    /// production security executor but deliberately does not claim generation success.
    static func verifyCandidate(
        engine: LocalEngineKind,
        endpoint rawEndpoint: String,
        securityMode: RelayConnectionSecurityMode,
        apiKey: String = "",
        session: URLSession = .shared
    ) async throws -> String {
        let authPolicy = LocalEngineAuthenticationPolicy.policy(for: engine)
        let hasCredential = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        try validateAuthenticationPolicy(
            authPolicy,
            securityMode: securityMode,
            hasCredential: hasCredential
        )
        let endpoint: String
        do {
            endpoint = try RelayEndpointPolicy.requireConfigured(
                rawEndpoint,
                securityMode: securityMode,
                credentials: .init(authMode: authPolicy.authMode, hasKey: hasCredential)
            )
        } catch ProviderServiceError.invalidConfiguration(let reason) where reason == "cleartext_credentials" {
            throw LocalEngineConnectionError.cleartextCredentials
        } catch {
            throw LocalEngineConnectionError.invalidEndpoint
        }
        guard let template = LocalEngineTemplate.all[engine] else {
            throw LocalEngineConnectionError.wrongEngine
        }
        let requested = RelayRequestedConfig(
            transport: engine.defaultTransport,
            authMode: authPolicy.authMode,
            securityMode: securityMode,
            stream: true,
            resolvedAPIBaseURL: apiBaseURL(for: endpoint, engine: engine),
            engineProfile: engine.rawValue
        )
        let snapshot = try await get(
            endpoint: endpoint,
            path: template.probePath,
            requested: requested,
            apiKey: apiKey,
            session: session
        )
        switch LocalEngineContract.classify(
            engine: engine,
            status: snapshot.status,
            contentType: snapshot.contentType,
            json: snapshot.json
        ) {
        case .ready: return endpoint
        case .loading: throw LocalEngineConnectionError.engineLoading
        default: throw LocalEngineConnectionError.wrongEngine
        }
    }

    nonisolated static func supports(securityMode: RelayConnectionSecurityMode) -> Bool {
        switch securityMode {
        case .remoteHTTPS, .localHTTP, .privateVPN, .tofuHTTPS: return true
        }
    }

    private static func validateAuthenticationPolicy(
        _ policy: LocalEngineAuthenticationPolicy,
        securityMode: RelayConnectionSecurityMode,
        hasCredential: Bool
    ) throws {
        if policy.requiresCredential, hasCredential, securityMode == .localHTTP {
            throw LocalEngineConnectionError.cleartextCredentials
        }
        guard policy.permits(securityMode: securityMode, hasCredential: hasCredential) else {
            throw LocalEngineConnectionError.invalidEndpoint
        }
    }

    nonisolated static func apiBaseURL(for endpoint: String, engine: LocalEngineKind) -> String {
        let trimmed = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if engine == .openwebui { return trimmed + "/api" }
        return trimmed.lowercased().hasSuffix("/v1") ? trimmed : "\(trimmed)/v1"
    }

    private static func get(
        endpoint: String,
        path: String,
        requested: RelayRequestedConfig,
        apiKey: String,
        session: URLSession
    ) async throws -> (status: Int, contentType: String, json: Any?) {
        try await request(endpoint: endpoint, method: "GET", path: path, jsonBody: nil, requested: requested, apiKey: apiKey, session: session)
    }

    private static func request(
        endpoint: String,
        method: String,
        path: String,
        jsonBody: [String: Any]?,
        requested: RelayRequestedConfig,
        apiKey: String,
        session: URLSession
    ) async throws -> (status: Int, contentType: String, json: Any?) {
        guard let base = URL(string: endpoint),
              let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw LocalEngineConnectionError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        if let jsonBody {
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.applyRelaySecurityMode(requested)
        if requested.authMode == .bearer { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.relayData(for: request)
        } catch {
            throw classifyNetworkError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw LocalEngineConnectionError.wrongEngine }
        return (
            http.statusCode,
            http.value(forHTTPHeaderField: "Content-Type") ?? "",
            try? JSONSerialization.jsonObject(with: data)
        )
    }

    private static func introspectionMatches(
        engine: LocalEngineKind,
        snapshot: (status: Int, contentType: String, json: Any?)
    ) -> Bool {
        guard (200..<300).contains(snapshot.status) else { return false }
        if engine == .vllm { return true }
        guard snapshot.contentType.lowercased().contains("json"), let object = snapshot.json as? [String: Any] else { return false }
        switch engine {
        case .llamacpp: return object["default_generation_settings"] is [String: Any]
        case .ollama: return object["capabilities"] is [Any] || object["parameters"] is String
        case .lmstudio: return object["data"] is [[String: Any]] || object["models"] is [[String: Any]]
        case .vllm: return true
        case .openwebui: return object["data"] is [[String: Any]] || object["models"] is [[String: Any]]
        }
    }

    private static func modelIDs(engine: LocalEngineKind, json: Any?) -> [String] {
        guard let object = json as? [String: Any] else { return [] }
        let raw: [String]
        if engine == .ollama {
            raw = (object["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        } else if engine == .openwebui {
            raw = (object["data"] as? [[String: Any]] ?? object["models"] as? [[String: Any]] ?? [])
                .compactMap { $0["id"] as? String ?? $0["name"] as? String }
        } else {
            raw = (object["data"] as? [[String: Any]] ?? [])
                .filter { LocalEngineDeclarations.isChatCatalogRow(engine: engine, row: $0) }
                .compactMap { $0["id"] as? String }
        }
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    private static func modelRuntimeMetadata(
        engine: LocalEngineKind,
        json: Any?,
        modelIDs: [String]
    ) -> [String: LocalModelRuntimeMetadata] {
        guard let object = json as? [String: Any] else { return [:] }
        let rows = engine == .ollama
            ? (object["models"] as? [[String: Any]] ?? [])
            : (object["data"] as? [[String: Any]] ?? [])
        return Dictionary(uniqueKeysWithValues: modelIDs.map { modelID in
            let row = rows.first { ($0[engine == .ollama ? "name" : "id"] as? String) == modelID }
            let rawState = (row?["state"] as? String)?.lowercased()
            let state: LocalModelLoadState = switch rawState {
            case "loaded": .loaded
            case "loading": .loading
            case "unloaded": .unloaded
            default: engine == .vllm || engine == .openwebui ? .loaded : .unknown
            }
            return (modelID, .init(
                loadState: state,
                executionLocality: executionLocality(engine: engine, modelID: modelID)
            ))
        })
    }

    private static func executionLocality(engine: LocalEngineKind, modelID: String) -> ModelExecutionLocality {
        LocalEngineContract.locality(engine: engine, modelID: modelID) == "cloud" ? .proxiedCloud : .local
    }

    static func classifyNetworkError(_ error: Error) -> LocalEngineConnectionError {
        if isLocalNetworkPermissionDenied(error) { return .localNetworkDenied }
        if let urlError = error as? URLError {
            if urlError.code == .timedOut { return .timeout }
            if [.cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost]
                .contains(urlError.code) { return .engineStopped }
        }
        let message = error.localizedDescription.lowercased()
        if message.contains("out of memory") || message.contains("oom") { return .outOfMemory }
        if message.contains("context") && (message.contains("length") || message.contains("window") || message.contains("too long")) {
            return .contextExceeded
        }
        return .wrongEngine
    }

    private static func isLocalNetworkPermissionDenied(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        for _ in 0..<6 {
            guard let candidate = current else { break }
            let diagnostic = ([candidate.localizedDescription] + candidate.userInfo.values.map { String(describing: $0) })
                .joined(separator: " ")
                .lowercased()
            if diagnostic.contains("local network prohibited") || diagnostic.contains("localnetworkdenied") {
                return true
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
