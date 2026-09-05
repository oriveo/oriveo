import Foundation

nonisolated enum LocalEngineKind: String, Codable, CaseIterable, Sendable {
    case llamacpp, ollama, lmstudio, vllm, openwebui
}

nonisolated struct LocalEngineAuthenticationPolicy: Equatable, Sendable {
    let authMode: RelayAuthMode
    let requiresCredential: Bool
    let allowedSecurityModes: Set<RelayConnectionSecurityMode>

    static func policy(for engine: LocalEngineKind) -> Self {
        if engine == .openwebui {
            return Self(
                authMode: .bearer,
                requiresCredential: true,
                allowedSecurityModes: [.remoteHTTPS, .tofuHTTPS]
            )
        }
        return Self(
            authMode: .none,
            requiresCredential: false,
            allowedSecurityModes: [.remoteHTTPS, .localHTTP, .privateVPN, .tofuHTTPS]
        )
    }

    func permits(securityMode: RelayConnectionSecurityMode, hasCredential: Bool) -> Bool {
        allowedSecurityModes.contains(securityMode) && (!requiresCredential || hasCredential)
    }
}

nonisolated enum LocalConnectionRecoveryAction: String, Equatable, Sendable {
    case editAddress
    case chooseEngine
    case waitAndRetry
    case chooseModel
    case startEngine
    case freeMemory
    case shortenContext
    case openSettings

    static func action(for error: LocalEngineConnectionError) -> Self {
        switch error {
        case .invalidEndpoint, .cleartextCredentials: .editAddress
        case .wrongEngine: .chooseEngine
        case .engineLoading, .timeout: .waitAndRetry
        case .noModels: .chooseModel
        case .engineStopped: .startEngine
        case .outOfMemory: .freeMemory
        case .contextExceeded: .shortenContext
        case .localNetworkDenied: .openSettings
        }
    }
}

enum LocalEngineState: String, Equatable {
    case ready, loading, wrongEngine = "wrong_engine", parameterRejected = "parameter_rejected", unreachable
}

struct LocalEngineTemplate: Equatable {
    let engine: LocalEngineKind
    let defaultEndpoint: String
    let probeMethod: String
    let probePath: String
    let catalogPath: String
    let introspectionMethod: String
    let introspectionPath: String
    let generationPaths: [String]
    /// Candidate service paths only. A caller must still prove support by engine introspection/runtime success.
    let capabilityPaths: [String: [String]]

    static let all: [LocalEngineKind: Self] = [
        .llamacpp: .init(engine: .llamacpp, defaultEndpoint: "http://127.0.0.1:8080", probeMethod: "GET", probePath: "/health", catalogPath: "/v1/models", introspectionMethod: "GET", introspectionPath: "/props", generationPaths: ["/v1/chat/completions", "/v1/messages", "/completion"], capabilityPaths: ["embedding": ["/embedding", "/v1/embeddings"], "rerank": ["/rerank", "/v1/rerank"]]),
        .ollama: .init(engine: .ollama, defaultEndpoint: "http://127.0.0.1:11434", probeMethod: "GET", probePath: "/api/tags", catalogPath: "/api/tags", introspectionMethod: "POST", introspectionPath: "/api/show", generationPaths: ["/api/chat", "/v1/chat/completions"], capabilityPaths: ["embedding": ["/api/embed", "/api/embeddings"]]),
        .lmstudio: .init(engine: .lmstudio, defaultEndpoint: "http://127.0.0.1:1234", probeMethod: "GET", probePath: "/api/v0/models", catalogPath: "/api/v0/models", introspectionMethod: "GET", introspectionPath: "/api/v0/models", generationPaths: ["/v1/chat/completions", "/v1/responses"], capabilityPaths: ["embedding": ["/v1/embeddings"]]),
        .vllm: .init(engine: .vllm, defaultEndpoint: "http://127.0.0.1:8000", probeMethod: "GET", probePath: "/v1/models", catalogPath: "/v1/models", introspectionMethod: "GET", introspectionPath: "/health", generationPaths: ["/v1/chat/completions", "/v1/responses"], capabilityPaths: ["embedding": ["/v1/embeddings"], "rerank": ["/rerank", "/v1/rerank"]]),
        .openwebui: .init(engine: .openwebui, defaultEndpoint: "https://127.0.0.1:3000", probeMethod: "GET", probePath: "/api/models", catalogPath: "/api/models", introspectionMethod: "GET", introspectionPath: "/api/models", generationPaths: ["/api/chat/completions"], capabilityPaths: ["embedding": ["/api/embeddings"]])
    ]
}

enum LocalEngineContract {
    static func classify(engine: LocalEngineKind, status: Int, contentType: String, json: Any?) -> LocalEngineState {
        guard let object = json as? [String: Any] else { return .wrongEngine }
        if status == 400, let error = object["error"] as? [String: Any], error["type"] as? String == "invalid_request_error" { return .parameterRejected }
        if status == 503 { return .loading }
        guard (200..<300).contains(status), contentType.lowercased().contains("json") else { return .wrongEngine }
        switch engine {
        case .llamacpp:
            if object["status"] as? String == "ok" { return .ready }
            return object["status"] as? String == "loading model" ? .loading : .wrongEngine
        case .ollama:
            return object["models"] is [[String: Any]] ? .ready : .wrongEngine
        case .lmstudio:
            guard let data = object["data"] as? [[String: Any]] else { return .wrongEngine }
            return data.contains { $0["state"] is String } ? .ready : .wrongEngine
        case .vllm:
            guard let data = object["data"] as? [[String: Any]] else { return .wrongEngine }
            return data.allSatisfy { $0["id"] is String && $0["state"] == nil } ? .ready : .wrongEngine
        case .openwebui:
            let rows = object["data"] as? [[String: Any]] ?? object["models"] as? [[String: Any]]
            return rows?.allSatisfy { $0["id"] is String || $0["name"] is String } == true ? .ready : .wrongEngine
        }
    }

    static func locality(engine: LocalEngineKind, modelID: String) -> String {
        engine == .ollama && modelID.lowercased().hasSuffix(":cloud") ? "cloud" : "local"
    }
}

enum LocalEngineGenerationProfiles {
    static func profile(for engineProfile: String?, transport: RelayTransport? = nil) -> GenerationProfileRef? {
        switch engineProfile {
        case "llamacpp":
            return .init(
                template: "llamacpp_native", parameters: llamaIDs.map { parameter($0) },
                wire: Dictionary(uniqueKeysWithValues: llamaIDs.map { ($0, $0 == "max_output_tokens" ? "n_predict" : $0) }),
                transport: "llamacpp_native"
            )
        case "vllm":
            return .init(
                template: "vllm_extra_body", parameters: vllmIDs.map { id in
                    var value = parameter(id)
                    if id == "top_k" { value.group = "engine_runtime" }
                    return value
                },
                wire: Dictionary(uniqueKeysWithValues: vllmIDs.map { id in
                    if id == "max_output_tokens" { return (id, "max_tokens") }
                    if ["top_k", "min_p", "typical_p", "repeat_penalty"].contains(id) {
                        return (id, "extra_body." + (id == "repeat_penalty" ? "repetition_penalty" : id))
                    }
                    return (id, id)
                }),
                transport: "openai_chat_completions"
            )
        case "openwebui":
            let ids = ["max_output_tokens", "stop", "temperature", "top_p", "frequency_penalty", "presence_penalty", "seed", "response_format", "json_schema", "verbosity", "logprobs", "top_logprobs"]
            return .init(
                template: "openai_chat_completions",
                parameters: ids.map { parameter($0) },
                wire: ["max_output_tokens": "max_tokens", "stop": "stop", "temperature": "temperature", "top_p": "top_p", "frequency_penalty": "frequency_penalty", "presence_penalty": "presence_penalty", "seed": "seed", "response_format": "response_format", "json_schema": "response_format", "verbosity": "verbosity", "logprobs": "logprobs", "top_logprobs": "top_logprobs"],
                transport: "openai_chat_completions"
            )
        default:
            return genericRelayProfile(transport: transport)
        }
    }

    private static func genericRelayProfile(transport: RelayTransport?) -> GenerationProfileRef? {
        let template: String
        let ids: [String]
        let wire: [String: String]
        switch transport {
        case .openaiChatCompletions:
            template = "openai_chat_completions"
            ids = ["max_output_tokens", "stop", "reasoning_effort", "reasoning_budget", "reasoning_mode", "temperature", "top_p", "top_k", "min_p", "frequency_penalty", "presence_penalty", "repeat_penalty", "seed", "logprobs"]
            wire = ["max_output_tokens": "max_tokens", "stop": "stop", "reasoning_effort": "reasoning_effort", "reasoning_budget": "reasoning_budget", "reasoning_mode": "reasoning_mode", "temperature": "temperature", "top_p": "top_p", "top_k": "top_k", "min_p": "min_p", "frequency_penalty": "frequency_penalty", "presence_penalty": "presence_penalty", "repeat_penalty": "repeat_penalty", "seed": "seed", "logprobs": "logprobs"]
        case .openaiResponses:
            template = "openai_responses"
            ids = ["max_output_tokens", "reasoning_effort", "temperature", "top_p", "seed", "logprobs"]
            wire = ["max_output_tokens": "max_output_tokens", "reasoning_effort": "reasoning.effort", "temperature": "temperature", "top_p": "top_p", "seed": "seed", "logprobs": "logprobs"]
        case .anthropicMessages:
            template = "anthropic_messages"
            ids = ["max_output_tokens", "stop", "temperature", "top_p", "top_k"]
            wire = ["max_output_tokens": "max_tokens", "stop": "stop_sequences", "temperature": "temperature", "top_p": "top_p", "top_k": "top_k"]
        case .geminiGenerateContent:
            template = "gemini_generate_content"
            ids = ["max_output_tokens", "stop", "temperature", "top_p", "top_k", "presence_penalty", "frequency_penalty", "seed", "logprobs"]
            wire = ["max_output_tokens": "generationConfig.maxOutputTokens", "stop": "generationConfig.stopSequences", "temperature": "generationConfig.temperature", "top_p": "generationConfig.topP", "top_k": "generationConfig.topK", "presence_penalty": "generationConfig.presencePenalty", "frequency_penalty": "generationConfig.frequencyPenalty", "seed": "generationConfig.seed", "logprobs": "generationConfig.responseLogprobs"]
        default:
            return nil
        }
        return .init(
            template: template,
            parameters: ids.map { parameter($0, support: "unknown") },
            wire: wire,
            transport: template
        )
    }

    private static func parameter(_ id: String, support: String = "accepted_unverified") -> GenerationParameterRef {
        let schema: String
        let range: GenerationParameterRange?
        switch id {
        case "max_output_tokens": schema = "integer"; range = .init(min: 1, max: nil)
        case "top_k", "seed": schema = "integer"; range = id == "top_k" ? .init(min: 0, max: nil) : nil
        case "top_p", "min_p", "typical_p", "xtc_probability", "xtc_threshold": schema = "number"; range = .init(min: 0, max: 1)
        case "mirostat", "repeat_last_n", "dry_allowed_length", "dry_penalty_last_n", "min_keep", "n_keep", "n_indent", "t_max_predict_ms", "n_probs": schema = "integer"; range = nil
        case "samplers": schema = "string-list"; range = nil
        case "ignore_eos", "post_sampling_probs", "logprobs": schema = "boolean"; range = nil
        case "json_schema": schema = "json-schema"; range = nil
        case "temperature": schema = "number"; range = nil
        case "repeat_penalty": schema = "number"; range = .init(min: 0, max: nil)
        case "stop": schema = "string-list"; range = nil
        default: schema = "string"; range = nil
        }
        return GenerationParameterRef(
            id: id,
            support: support,
            source: "user_declared",
            group: parameterGroup(id),
            valueSchema: schema,
            range: range,
            portability: ["top_k", "min_p", "repeat_penalty"].contains(id) ? "engine_scoped" : "transport_scoped",
            risk: ["top_k", "min_p"].contains(id) ? "experimental" : "normal"
        )
    }

    private static func parameterGroup(_ id: String) -> String {
        if ["max_output_tokens", "stop"].contains(id) { return "budget" }
        if ["reasoning_effort", "reasoning_budget", "reasoning_mode"].contains(id) { return "reasoning" }
        if ["frequency_penalty", "presence_penalty", "repeat_penalty"].contains(id) { return "repetition" }
        if id == "seed" { return "reproducibility" }
        if ["json_schema", "logprobs"].contains(id) { return "output_contract" }
        return "sampling"
    }

    private static let llamaIDs = [
        "max_output_tokens", "stop", "temperature", "top_p", "top_k", "min_p", "typical_p",
        "repeat_penalty", "repeat_last_n", "mirostat", "mirostat_tau", "mirostat_eta",
        "dry_multiplier", "dry_base", "dry_allowed_length", "dry_penalty_last_n",
        "xtc_probability", "xtc_threshold", "samplers", "ignore_eos", "top_n_sigma",
        "dynatemp_range", "dynatemp_exponent", "min_keep", "n_keep", "n_indent",
        "t_max_predict_ms", "n_probs", "post_sampling_probs", "seed", "json_schema", "logprobs",
    ]
    private static let vllmIDs = [
        "max_output_tokens", "stop", "temperature", "top_p", "top_k", "min_p", "typical_p",
        "presence_penalty", "frequency_penalty", "repeat_penalty", "seed", "json_schema", "logprobs", "top_logprobs",
    ]
}

nonisolated enum GenerationParameterEntryScope: String, Sendable {
    case session
    case connectionDefaults
}

enum GenerationParameterAvailability {
    static func projection(
        provider: Provider,
        model: AIModel,
        identity: CapabilityEvidenceRequestIdentity? = nil,
        explicitParameterIDs: Set<String> = []
    ) -> GenerationParameterEvidenceProjection {
        CapabilityEvidenceProductionAdapter.generationProjection(
            provider: provider, model: model, identity: identity,
            explicitParameterIDs: explicitParameterIDs
        )
    }

    static func profile(
        provider: Provider,
        model: AIModel,
        identity: CapabilityEvidenceRequestIdentity? = nil
    ) -> GenerationProfileRef? {
        projection(provider: provider, model: model, identity: identity).profile
    }

    static func isReasoningParameter(_ parameter: GenerationParameterRef) -> Bool {
        parameter.group == "reasoning" || (parameter.id ?? "").hasPrefix("reasoning_")
    }

    static func sessionActionable(
        provider: Provider,
        model: AIModel,
        identity: CapabilityEvidenceRequestIdentity? = nil,
        explicitParameterIDs: Set<String> = []
    ) -> [GenerationParameterRef] {
        let projection = projection(
            provider: provider, model: model, identity: identity,
            explicitParameterIDs: explicitParameterIDs
        )
        guard let profile = projection.profile else { return [] }
        return profile.parameters?.filter { parameter in
            guard let id = parameter.id, profile.wire?[id]?.isEmpty == false else { return false }
            if isReasoningParameter(parameter) { return false }
            return projection.isVisible(parameter, scope: .session)
        } ?? []
    }

    static func connectionConfigurable(
        provider: Provider,
        model: AIModel,
        identity: CapabilityEvidenceRequestIdentity? = nil,
        explicitParameterIDs: Set<String> = []
    ) -> [GenerationParameterRef] {
        let projection = projection(
            provider: provider, model: model, identity: identity,
            explicitParameterIDs: explicitParameterIDs
        )
        guard let profile = projection.profile else { return [] }
        return profile.parameters?.filter { parameter in
            projection.isVisible(parameter, scope: .connectionDefaults)
        } ?? []
    }

    static func entryVisible(
        provider: Provider,
        model: AIModel,
        scope: GenerationParameterEntryScope,
        identity: CapabilityEvidenceRequestIdentity? = nil,
        explicitParameterIDs: Set<String> = []
    ) -> Bool {
        switch scope {
        case .session:
            return !sessionActionable(
                provider: provider, model: model, identity: identity,
                explicitParameterIDs: explicitParameterIDs
            ).isEmpty
        case .connectionDefaults:
            return !connectionConfigurable(
                provider: provider, model: model, identity: identity,
                explicitParameterIDs: explicitParameterIDs
            ).isEmpty
        }
    }

    static func editable(
        provider: Provider,
        model: AIModel,
        parameter: GenerationParameterRef,
        scope: GenerationParameterEntryScope = .connectionDefaults,
        identity: CapabilityEvidenceRequestIdentity? = nil,
        hasExplicitValue: Bool = false
    ) -> Bool {
        guard let id = parameter.id,
              let projection = Optional(projection(
                provider: provider, model: model, identity: identity,
                explicitParameterIDs: hasExplicitValue ? [id] : []
              )),
              projection.profile?.wire?[id]?.isEmpty == false else { return false }
        return projection.isEditable(parameter, scope: scope)
    }
}
