import Foundation

struct LocalEngineConnection: Sendable {
    let engine: LocalEngineKind
    let endpoint: String
    let apiBaseURL: String
    let modelIDs: [String]
    let runtimeMetadata: [String: LocalModelRuntimeMetadata]
    let selectedModelID: String
    let requested: RelayRequestedConfig
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
        session: URLSession = .shared
    ) async throws -> LocalEngineConnection {
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
        let requested = RelayRequestedConfig(
            transport: engine == .llamacpp ? .llamacppNative : .openaiChatCompletions,
            authMode: authPolicy.authMode,
            securityMode: securityMode,
            stream: true,
            resolvedAPIBaseURL: apiBaseURL(for: endpoint, engine: engine),
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
        return LocalEngineConnection(
            engine: engine,
            endpoint: endpoint,
            apiBaseURL: requested.resolvedAPIBaseURL ?? endpoint,
            modelIDs: catalogModelIDs(discovered: discovered, selected: selected),
            runtimeMetadata: runtimeMetadata.isEmpty
                ? [selected: .init(loadState: .unknown, executionLocality: executionLocality(engine: engine, modelID: selected))]
                : runtimeMetadata,
            selectedModelID: selected,
            requested: requested
        )
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
            transport: engine == .llamacpp ? .llamacppNative : .openaiChatCompletions,
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

    private static func apiBaseURL(for endpoint: String, engine: LocalEngineKind) -> String {
        let trimmed = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if engine == .llamacpp { return trimmed }
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
            raw = (object["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
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
