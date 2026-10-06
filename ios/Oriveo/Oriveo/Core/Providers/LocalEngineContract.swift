import Foundation

nonisolated enum LocalEngineKind: String, Codable, CaseIterable, Sendable {
    case llamacpp, ollama, lmstudio, vllm, openwebui

    /// Transport for a new connection. llama.cpp uses the chat transport too, so the engine applies
    /// the chat template that ships with the model; the native `/completion` endpoint stays
    /// available as a manual choice.
    var defaultTransport: RelayTransport { .openaiChatCompletions }
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

/// Parameter tables for engines running on the user's own hardware. The source of truth is
/// `localEngineProfiles` in the shared contract `generation_parameter_contract.v1.json`, taken from
/// each engine's official documentation; `LocalEngineProfileContractTests` reconciles the tables
/// row by row, so a change here must change the contract too.
enum LocalEngineGenerationProfiles {
    static func profile(for engineProfile: String?, transport: RelayTransport? = nil) -> GenerationProfileRef? {
        let isChat = transport == nil || transport == .auto || transport == .openaiChatCompletions
        switch engineProfile {
        case "llamacpp":
            // The chat endpoint accepts every native sampling field at the top level; the two
            // transports differ in only three wire names.
            if transport == .llamacppNative {
                return makeProfile(template: "llamacpp_native", transport: "llamacpp_native", rows: llamaRows(native: true))
            }
            guard isChat else { return genericRelayProfile(transport: transport) }
            return makeProfile(template: "openai_chat_completions", rows: llamaRows(native: false))
        case "ollama":
            guard isChat else { return genericRelayProfile(transport: transport) }
            return makeProfile(template: "openai_chat_completions", rows: ollamaRows)
        case "lmstudio":
            guard isChat else { return genericRelayProfile(transport: transport) }
            return makeProfile(template: "openai_chat_completions", rows: lmStudioRows)
        case "vllm":
            guard isChat else { return genericRelayProfile(transport: transport) }
            // The template name is an identifier shared across clients; the extended parameters
            // actually sit flat at the top level of the request body.
            return makeProfile(template: "vllm_extra_body", rows: vllmRows)
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

    /// Types and ranges for the generic tables (hosted custom endpoints, Open WebUI). A numeric
    /// parameter must be declared numeric: the panel stores `.number` or `.string` by schema, so a
    /// parameter declared as a string would be sent as one.
    private static func parameter(_ id: String, support: String = "accepted_unverified") -> GenerationParameterRef {
        let schema: String
        let range: GenerationParameterRange?
        switch id {
        case "max_output_tokens": schema = "integer"; range = .init(min: 1, max: nil)
        case "top_k": schema = "integer"; range = .init(min: 0, max: nil)
        case "seed", "top_logprobs", "reasoning_budget": schema = "integer"; range = nil
        case "top_p", "min_p": schema = "number"; range = .init(min: 0, max: 1)
        case "temperature", "frequency_penalty", "presence_penalty": schema = "number"; range = nil
        case "repeat_penalty": schema = "number"; range = .init(min: 0, max: nil)
        case "logprobs": schema = "boolean"; range = nil
        case "json_schema": schema = "json-schema"; range = nil
        case "stop": schema = "string-list"; range = nil
        default: schema = "string"; range = nil
        }
        return GenerationParameterRef(
            id: id,
            support: support,
            source: "user_declared",
            group: genericGroup(id),
            valueSchema: schema,
            range: range,
            portability: portability(id),
            risk: risk(id)
        )
    }

    private static func genericGroup(_ id: String) -> String {
        if ["max_output_tokens", "stop"].contains(id) { return "budget" }
        if ["reasoning_effort", "reasoning_budget", "reasoning_mode"].contains(id) { return "reasoning" }
        if ["frequency_penalty", "presence_penalty", "repeat_penalty"].contains(id) { return "repetition" }
        if id == "seed" { return "reproducibility" }
        if ["json_schema", "logprobs"].contains(id) { return "output_contract" }
        return "sampling"
    }

    private static func portability(_ id: String) -> String {
        ["top_k", "min_p", "repeat_penalty"].contains(id) ? "engine_scoped" : "transport_scoped"
    }

    private static func risk(_ id: String) -> String {
        ["top_k", "min_p"].contains(id) ? "experimental" : "normal"
    }

    // MARK: - Engine tables

    private struct Row {
        let id: String
        let wire: String
        let schema: String
        let group: String
        var range: GenerationParameterRange? = nil
        var enumValues: [GenerationParameterValue]? = nil
        var defaultValue: GenerationParameterValue? = nil
    }

    private static func makeProfile(
        template: String,
        transport: String = "openai_chat_completions",
        rows: [Row]
    ) -> GenerationProfileRef {
        .init(
            template: template,
            parameters: rows.map { row in
                GenerationParameterRef(
                    id: row.id,
                    support: "accepted_unverified",
                    source: "user_declared",
                    group: row.group,
                    valueSchema: row.schema,
                    range: row.range,
                    enumValues: row.enumValues,
                    defaultDescription: row.defaultValue,
                    portability: portability(row.id),
                    risk: risk(row.id)
                )
            },
            wire: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.wire) }),
            transport: transport
        )
    }

    private static func int(_ id: String, _ wire: String? = nil, _ group: String, min: Double? = nil, max: Double? = nil, default value: Double? = nil) -> Row {
        Row(id: id, wire: wire ?? id, schema: "integer", group: group,
            range: min == nil && max == nil ? nil : .init(min: min, max: max),
            defaultValue: value.map(GenerationParameterValue.number))
    }

    private static func num(_ id: String, _ wire: String? = nil, _ group: String, min: Double? = nil, max: Double? = nil, minExclusive: Double? = nil, default value: Double? = nil) -> Row {
        Row(id: id, wire: wire ?? id, schema: "number", group: group,
            range: min == nil && max == nil && minExclusive == nil ? nil : .init(min: min, max: max, minExclusive: minExclusive),
            defaultValue: value.map(GenerationParameterValue.number))
    }

    private static func bool(_ id: String, _ group: String, default value: Bool? = nil) -> Row {
        Row(id: id, wire: id, schema: "boolean", group: group, defaultValue: value.map(GenerationParameterValue.boolean))
    }

    private static func list(_ id: String, _ group: String) -> Row {
        Row(id: id, wire: id, schema: "string-list", group: group)
    }

    private static let responseFormatRow = Row(
        id: "response_format", wire: "response_format", schema: "enum", group: "output_contract",
        enumValues: [.string("text"), .string("json")]
    )

    private static func schemaRow(wire: String = "response_format") -> Row {
        Row(id: "json_schema", wire: wire, schema: "json-schema", group: "output_contract")
    }

    /// Defaults come from `/props` on a real llama-server (the documented defaults for
    /// repeat_penalty and dry_penalty_last_n differ from what the server reports).
    private static func llamaRows(native: Bool) -> [Row] {
        var rows: [Row] = [
            int("max_output_tokens", native ? "n_predict" : "max_tokens", "budget", min: 1),
            list("stop", "budget"),
            num("temperature", nil, "sampling", min: 0, default: 0.8),
            num("top_p", nil, "sampling", min: 0, max: 1, default: 0.95),
            int("top_k", nil, "sampling", min: 0, default: 40),
            num("min_p", nil, "sampling", min: 0, max: 1, default: 0.05),
            num("typical_p", nil, "sampling", min: 0, max: 1, default: 1),
            num("top_n_sigma", nil, "sampling", default: -1),
            num("presence_penalty", nil, "repetition", default: 0),
            num("frequency_penalty", nil, "repetition", default: 0),
            num("repeat_penalty", nil, "repetition", min: 0, default: 1),
            int("repeat_last_n", nil, "repetition", min: 0, default: 64),
            int("mirostat", nil, "sampling", min: 0, max: 2, default: 0),
            num("mirostat_tau", nil, "sampling", min: 0, default: 5),
            num("mirostat_eta", nil, "sampling", min: 0, default: 0.1),
            num("dry_multiplier", nil, "repetition", min: 0, default: 0),
            num("dry_base", nil, "repetition", min: 1, default: 1.75),
            int("dry_allowed_length", nil, "repetition", min: 0, default: 2),
            int("dry_penalty_last_n", nil, "repetition", min: -1, default: -1),
            list("dry_sequence_breakers", "repetition"),
            num("xtc_probability", nil, "sampling", min: 0, max: 1, default: 0),
            num("xtc_threshold", nil, "sampling", min: 0, max: 1, default: 0.1),
            num("dynatemp_range", nil, "sampling", min: 0, default: 0),
            num("dynatemp_exponent", nil, "sampling", default: 1),
            list("samplers", "sampling"),
            int("min_keep", nil, "sampling", min: 0, default: 0),
            int("n_keep", nil, "sampling", min: -1, default: 0),
            int("n_indent", nil, "sampling", min: 0, default: 0),
            int("t_max_predict_ms", nil, "budget", min: 0, default: 0),
            bool("ignore_eos", "budget", default: false),
            int("seed", nil, "reproducibility"),
            Row(id: "grammar", wire: "grammar", schema: "string", group: "output_contract"),
            schemaRow(wire: native ? "json_schema" : "response_format"),
        ]
        if native {
            rows.append(int("n_probs", nil, "output_contract", min: 0, default: 0))
        } else {
            rows.append(bool("logprobs", "output_contract", default: false))
            rows.append(int("top_logprobs", nil, "output_contract", min: 0))
        }
        rows.append(bool("post_sampling_probs", "output_contract", default: false))
        return rows
    }

    /// The fields the OpenAI-compatible endpoint documents; `num_ctx` / `keep_alive` are runtime
    /// resource settings and are not part of this table.
    private static let ollamaRows: [Row] = [
        int("max_output_tokens", "max_tokens", "budget", min: 1),
        list("stop", "budget"),
        Row(id: "reasoning_effort", wire: "reasoning_effort", schema: "string", group: "reasoning"),
        num("temperature", nil, "sampling", min: 0),
        num("top_p", nil, "sampling", min: 0, max: 1),
        num("presence_penalty", nil, "repetition"),
        num("frequency_penalty", nil, "repetition"),
        int("seed", nil, "reproducibility"),
        responseFormatRow,
        schemaRow(),
    ]

    /// The LM Studio documentation gives no defaults or ranges, so they are left empty.
    private static let lmStudioRows: [Row] = [
        int("max_output_tokens", "max_tokens", "budget", min: 1),
        list("stop", "budget"),
        num("temperature", nil, "sampling", min: 0),
        num("top_p", nil, "sampling", min: 0, max: 1),
        int("top_k", nil, "sampling", min: 0),
        num("presence_penalty", nil, "repetition"),
        num("frequency_penalty", nil, "repetition"),
        num("repeat_penalty", nil, "repetition", min: 0),
        int("seed", nil, "reproducibility"),
        schemaRow(),
    ]

    private static let vllmRows: [Row] = [
        // max_tokens is deprecated upstream in favor of max_completion_tokens, but older servers
        // ignore the new name (leaving output unbounded) while newer ones still accept the old.
        int("max_output_tokens", "max_tokens", "budget", min: 1),
        int("min_tokens", nil, "budget", min: 0, default: 0),
        list("stop", "budget"),
        bool("ignore_eos", "budget", default: false),
        num("temperature", nil, "sampling", min: 0, max: 2, default: 1),
        num("top_p", nil, "sampling", max: 1, minExclusive: 0, default: 1),
        int("top_k", nil, "sampling", min: -1, default: 0),
        num("min_p", nil, "sampling", min: 0, max: 1, default: 0),
        num("presence_penalty", nil, "repetition", min: -2, max: 2, default: 0),
        num("frequency_penalty", nil, "repetition", min: -2, max: 2, default: 0),
        num("repeat_penalty", "repetition_penalty", "repetition", minExclusive: 0, default: 1),
        int("seed", nil, "reproducibility"),
        bool("skip_special_tokens", "output_contract", default: true),
        responseFormatRow,
        schemaRow(),
        bool("logprobs", "output_contract", default: false),
        int("top_logprobs", nil, "output_contract", min: 0, default: 0),
    ]
}

/// One-time transport migration for existing llama.cpp connections (shared contract
/// `llamacppMigrationCases`). The native `/completion` endpoint flattens the conversation into
/// plain text and bypasses the model's chat template, so the default is now the chat transport;
/// once migrated, a native transport the user picks is never rewritten.
enum LlamaCppChannelMigration {
    static func migrated(_ requested: RelayRequestedConfig, alreadyMigrated: Bool) -> RelayRequestedConfig? {
        guard !alreadyMigrated,
              requested.engineProfile == LocalEngineKind.llamacpp.rawValue,
              requested.transport == .llamacppNative else { return nil }
        var copy = requested
        copy.transport = .openaiChatCompletions
        if let base = requested.resolvedAPIBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
            copy.resolvedAPIBaseURL = chatAPIBaseURL(fromOrigin: base)
        }
        return copy
    }

    /// llama-server serves its OpenAI-compatible endpoints under `/v1` and the native ones at the
    /// server root.
    static func chatAPIBaseURL(fromOrigin origin: String) -> String {
        let trimmed = origin.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.lowercased().hasSuffix("/v1") ? trimmed : "\(trimmed)/v1"
    }

    static func nativeRoot(fromBase base: String) -> String {
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.lowercased().hasSuffix("/v1") ? String(trimmed.dropLast(3)) : trimmed
    }
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
