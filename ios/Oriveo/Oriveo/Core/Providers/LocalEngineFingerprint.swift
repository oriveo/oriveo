import Foundation

/// Result of auto-detection. The channel is connection-level; generic / manual carry no engineProfile.
nonisolated enum LocalEngineFingerprintOutcome: Equatable, Sendable {
    case engine(LocalEngineKind, channel: RelayTransport)
    case generic(channel: RelayTransport)
    case manual

    var engineProfile: String? {
        if case .engine(let engine, _) = self { return engine.rawValue }
        return nil
    }
}

/// Fingerprint criteria (the shared fixture `engine-expectations.v1.json#fingerprint` is the source of truth).
///
/// Only a 2xx JSON object with the right shape counts: the status code alone never decides the result -- LM Studio answers an unknown path with
/// 200 + `{"error": ...}`. Exactly one engine matching -> that engine; two or more -> manual; when no engine matches,
/// generic only if the `/v1/models` shape matches, otherwise manual.
nonisolated enum LocalEngineFingerprint {
    static let requestPaths = ["/props", "/api/tags", "/api/v0/models", "/version", "/v1/models"]

    /// - Parameter objects: path -> the 2xx JSON object of that path; paths with a non-2xx status, a non-object body or a network failure are not included.
    static func evaluate(_ objects: [String: [String: Any]]) -> LocalEngineFingerprintOutcome {
        var hits: [LocalEngineKind] = []
        if let props = objects["/props"],
           props["modalities"] is [String: Any] || props["default_generation_settings"] is [String: Any] {
            hits.append(.llamacpp)
        }
        if let tags = objects["/api/tags"],
           let models = tags["models"] as? [Any],
           models.allSatisfy({ ($0 as? [String: Any])?["name"] is String }) {
            hits.append(.ollama)
        }
        if let lmModels = objects["/api/v0/models"],
           let data = lmModels["data"] as? [Any],
           data.allSatisfy({ ($0 as? [String: Any])?["type"] is String }) {
            hits.append(.lmstudio)
        }
        if let version = objects["/version"], version["version"] is String, version["error"] == nil {
            hits.append(.vllm)
        }
        if hits.count == 1, let engine = hits.first {
            return .engine(engine, channel: engine.defaultTransport)
        }
        if hits.count > 1 { return .manual }
        if let models = objects["/v1/models"], models["data"] is [Any] {
            return .generic(channel: .openaiChatCompletions)
        }
        return .manual
    }
}

/// Per-model capability declarations (the shared fixture `engine-expectations.v1.json#declarations` is the source of truth).
/// It only reads responses the connector already requests and sends no extra request for declarations.
nonisolated enum LocalEngineDeclarations {
    /// An LM Studio row with `type: embeddings` is not a chat model and does not enter the chat catalog.
    static func isChatCatalogRow(engine: LocalEngineKind, row: [String: Any]) -> Bool {
        !(engine == .lmstudio && row["type"] as? String == "embeddings")
    }

    /// - Parameters:
    ///   - catalogJSON: catalog response (Ollama `/api/tags`, LM Studio `/api/v0/models`, llama.cpp `/v1/models`).
    ///   - introspectionJSON: introspection response (llama.cpp `/props`, applies to every model of that connection).
    /// - Returns: model id -> non-empty declaration; models without any known key are not in the result.
    static func parse(engine: LocalEngineKind, catalogJSON: Any?, introspectionJSON: Any?) -> [String: EngineDeclaration] {
        let catalog = catalogJSON as? [String: Any]
        var result: [String: EngineDeclaration] = [:]
        func store(_ id: String?, _ declaration: EngineDeclaration) {
            guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                  !declaration.isEmpty, result[id] == nil else { return }
            result[id] = declaration
        }

        switch engine {
        case .ollama:
            for row in catalog?["models"] as? [[String: Any]] ?? [] {
                // Rows without a capabilities key are entirely unknown; when the key is present, a missing word means false.
                guard let words = row["capabilities"] as? [String] else { continue }
                store(row["name"] as? String, EngineDeclaration(
                    image: words.contains("vision"),
                    toolCall: words.contains("tools"),
                    thinking: words.contains("thinking")
                ))
            }
        case .lmstudio:
            for row in catalog?["data"] as? [[String: Any]] ?? [] where isChatCatalogRow(engine: engine, row: row) {
                let image: Bool? = switch row["type"] as? String {
                case "vlm": true
                case "llm": false
                default: nil
                }
                let toolCall = (row["capabilities"] as? [String]).map { $0.contains("tool_use") }
                store(row["id"] as? String, EngineDeclaration(image: image, toolCall: toolCall))
            }
        case .llamacpp:
            let props = introspectionJSON as? [String: Any]
            let image = (props?["modalities"] as? [String: Any])?["vision"] as? Bool
            // supports_tools == false is not a negative declaration; only true is recorded.
            let tools = (props?["chat_template_caps"] as? [String: Any])?["supports_tools"] as? Bool
            let declaration = EngineDeclaration(image: image, toolCall: tools == true ? true : nil)
            for row in catalog?["data"] as? [[String: Any]] ?? [] {
                store(row["id"] as? String, declaration)
            }
        case .vllm, .openwebui:
            break
        }
        return result
    }
}
