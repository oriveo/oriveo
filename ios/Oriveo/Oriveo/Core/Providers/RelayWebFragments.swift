import Foundation

/// Connection-level web-search fragments for relays (capability spec: "RELAY x web search").
///
/// A connection stores one JSON object per protocol; once stored, it is always sent with every chat request on that protocol, merged in after the builder's output
/// and before the extra request body is attached. Auxiliary requests such as capability tests and titles do not carry it. The rules for validation, merging and citation inference match
/// the shared fixture `shared/test-fixtures/relay/web-fragment.v1.json` case by case.
nonisolated enum RelayWebFragments {
    /// Section order on the settings page (Chat Completions / Responses / Messages / Gemini).
    static let transports: [RelayTransport] = [
        .openaiChatCompletions, .openaiResponses, .anthropicMessages, .geminiGenerateContent,
    ]
    static let maxBytes = 8_192
    /// The order matters: on error, the first key hit in this order is reported.
    static let forbiddenTopLevelKeys = [
        "model", "messages", "input", "contents", "system", "systemInstruction", "system_instruction",
        "instructions", "stream", "stream_options", "previous_response_id", "tool_choice",
        "toolConfig", "tool_config",
    ]
    private static let functionToolKeys = ["functionDeclarations", "function_declarations"]

    /// The original text of "Fill in template".
    static func template(for transport: RelayTransport) -> String? {
        switch transport {
        case .openaiResponses: return #"{"tools":[{"type":"web_search"}]}"#
        case .openaiChatCompletions: return #"{"web_search_options":{}}"#
        case .anthropicMessages: return #"{"tools":[{"type":"web_search_20250305","name":"web_search","max_uses":5}]}"#
        case .geminiGenerateContent: return #"{"tools":[{"googleSearch":{}}]}"#
        case .auto, .llamacppNative: return nil
        }
    }

    // MARK: - Validation

    enum ValidationError: Error, Equatable, Sendable {
        case notJSON, notObject, empty, tooLarge, forbiddenKey(String), invalidTools, functionTool

        /// Same names as the fixture's `validateCases.expect.error`.
        var code: String {
            switch self {
            case .notJSON: return "not_json"
            case .notObject: return "not_object"
            case .empty: return "empty"
            case .tooLarge: return "too_large"
            case .forbiddenKey: return "forbidden_key"
            case .invalidTools: return "invalid_tools"
            case .functionTool: return "function_tool"
            }
        }
    }

    /// Check order: not_json -> not_object -> empty -> too_large -> forbidden_key -> invalid_tools -> function_tool.
    static func validate(_ raw: String) -> Result<[String: Any], ValidationError> {
        guard let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .failure(.notJSON)
        }
        guard let object = parsed as? [String: Any] else { return .failure(.notObject) }
        guard !object.isEmpty else { return .failure(.empty) }
        guard data.count <= maxBytes else { return .failure(.tooLarge) }
        if let key = forbiddenTopLevelKeys.first(where: { object[$0] != nil }) {
            return .failure(.forbiddenKey(key))
        }
        if let tools = object["tools"] {
            guard let list = tools as? [Any], list.allSatisfy({ $0 is [String: Any] }) else {
                return .failure(.invalidTools)
            }
            let isFunction = list.compactMap { $0 as? [String: Any] }.contains { tool in
                (tool["type"] as? String) == "function" || functionToolKeys.contains { tool[$0] != nil }
            }
            if isFunction { return .failure(.functionTool) }
        }
        return .success(object)
    }

    // MARK: - Merge

    /// Merges the fragment into the request body produced by the builder, and returns the part actually merged this round (used for citation inference).
    /// `tools` is appended after the builder's tools (when Gemini already has function declarations, the fragment's tools are not added at all); other keys are deep-merged,
    /// and on a leaf or type conflict the builder wins.
    @discardableResult
    static func merge(
        transport: RelayTransport, into body: inout [String: Any], fragment: [String: Any]
    ) -> [String: Any] {
        var applied = fragment
        for (key, value) in fragment {
            if key == "tools", let fragmentTools = value as? [Any] {
                guard let existing = body["tools"] else {
                    body["tools"] = fragmentTools
                    continue
                }
                guard let builderTools = existing as? [Any] else {
                    applied["tools"] = nil
                    continue
                }
                let hasFunctionDeclarations = transport == .geminiGenerateContent && builderTools.contains { tool in
                    guard let tool = tool as? [String: Any] else { return false }
                    return functionToolKeys.contains { tool[$0] != nil }
                }
                if hasFunctionDeclarations {
                    applied["tools"] = nil
                } else {
                    body["tools"] = builderTools + fragmentTools
                }
                continue
            }
            body[key] = deepMerge(builder: body[key], fragment: value)
        }
        return applied
    }

    private static func deepMerge(builder: Any?, fragment: Any) -> Any {
        guard let builder else { return fragment }
        guard var builderObject = builder as? [String: Any],
              let fragmentObject = fragment as? [String: Any] else { return builder }
        for (key, value) in fragmentObject {
            builderObject[key] = deepMerge(builder: builderObject[key], fragment: value)
        }
        return builderObject
    }

    /// The single entry point of the chat send path: takes out the fragment for this protocol, merges it, and returns the part actually merged. Without a fragment the request body is untouched.
    @discardableResult
    static func apply(
        _ set: RelayWebFragmentSet?, transport: RelayTransport, to body: inout [String: Any]
    ) -> [String: Any]? {
        guard let fragment = set?.object(for: transport) else { return nil }
        return merge(transport: transport, into: &body, fragment: fragment)
    }

    // MARK: - Citations

    /// Infers the citation-parsing profile from the fragment merged this round (fixture `citationCases`), then goes through the existing stream-shape lookup.
    static func citationProfile(transport: RelayTransport, fragment: [String: Any]?) -> String? {
        guard let fragment else { return nil }
        let tools = (fragment["tools"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        let toolTypes = tools.compactMap { $0["type"] as? String }
        switch transport {
        case .openaiResponses:
            return toolTypes.contains { $0.hasPrefix("web_search") } ? "oai_responses_web" : nil
        case .anthropicMessages:
            return toolTypes.contains { $0.hasPrefix("web_search_") } ? "ant_web_tool" : nil
        case .geminiGenerateContent:
            let keys = ["googleSearch", "google_search", "google_search_retrieval", "googleSearchRetrieval"]
            return tools.contains { tool in keys.contains { tool[$0] != nil } } ? "gem_web" : nil
        case .openaiChatCompletions, .auto:
            let plugins = (fragment["plugins"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            if plugins.contains(where: { ($0["id"] as? String) == "web" }) { return "or_web" }
            if fragment["web_search_options"] != nil { return "oai_web_tool" }
            if toolTypes.contains("web_search") { return "zhipu_web" }
            return nil
        case .llamacppNative:
            return nil
        }
    }

    // MARK: - Metadata needed for legacy field mapping

    /// `profiles.webSearch[<name>].mergeParams` of production metadata; a profile that exists without mergeParams is treated as an empty object.
    static func metadataProfiles() -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for name in MetadataClient.shared.syncKnownWebSearchProfileNames() {
            out[name] = MetadataClient.shared.syncWebSearchMergeParams(profileName: name) ?? [:]
        }
        return out
    }

    // MARK: - Presentation

    /// Web-search facts read jointly by the model options panel and the outbound gate (fixture `presentationCases`).
    static func panelFact(
        engineProfile: String?, effectiveTransport: RelayTransport, fragments: RelayWebFragmentSet,
        probe: RelayWebProbeRecord.Result? = nil
    ) -> ModelOptionCapabilityShape.RelayWeb {
        if engineProfile?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return .localEngine }
        return fragments.object(for: effectiveTransport) != nil ? .saved(probe: probe) : .notSaved
    }
}

/// The effective fragments of a connection: key = the protocol's wire value, value = the original text. It travels with a request inside the process only (not encoded, not synced).
nonisolated struct RelayWebFragmentSet: Hashable, Sendable {
    var raw: [String: String] = [:]

    var isEmpty: Bool { raw.isEmpty }

    func text(for transport: RelayTransport) -> String? { raw[transport.rawValue] }

    func object(for transport: RelayTransport) -> [String: Any]? {
        guard let text = raw[transport.rawValue], let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Built from an object (the result of legacy field mapping): serialized with sorted keys; this original text is what the settings page shows.
    static func from(objects: [String: [String: Any]]) -> Self {
        var raw: [String: String] = [:]
        for (key, object) in objects {
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { continue }
            raw[key] = String(decoding: data, as: UTF8.self)
        }
        return Self(raw: raw)
    }
}

/// Local key-value store `relay_web_fragments.v1`: stores `{protocol: original text}` by connection id. Excluded from cloud sync and backups, and the whole entry is removed when the connection is deleted.
nonisolated final class RelayWebFragmentStore: @unchecked Sendable {
    static let storageKey = "relay_web_fragments.v1"
    static let shared = RelayWebFragmentStore()

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func stored(connectionID: UUID) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return load()[connectionID.uuidString] ?? [:]
    }

    /// Store one fragment: validate first, and do not write if it fails.
    @discardableResult
    func save(connectionID: UUID, transport: RelayTransport, raw: String) -> RelayWebFragments.ValidationError? {
        if case let .failure(error) = RelayWebFragments.validate(raw) { return error }
        mutate { all in
            var entry = all[connectionID.uuidString] ?? [:]
            entry[transport.rawValue] = raw
            all[connectionID.uuidString] = entry
        }
        return nil
    }

    func clear(connectionID: UUID, transport: RelayTransport) {
        mutate { all in
            var entry = all[connectionID.uuidString] ?? [:]
            entry[transport.rawValue] = nil
            all[connectionID.uuidString] = entry.isEmpty ? nil : entry
        }
    }

    func deleteConnection(_ connectionID: UUID) {
        mutate { all in all[connectionID.uuidString] = nil }
    }

    /// Effective fragments: if the store has any fragment, use only the store; otherwise map from the legacy fields in memory (not written back).
    func effective(
        provider: Provider, profiles: () -> [String: [String: Any]] = { RelayWebFragments.metadataProfiles() }
    ) -> RelayWebFragmentSet {
        let saved = stored(connectionID: provider.id)
        if !saved.isEmpty { return RelayWebFragmentSet(raw: saved) }
        guard let requested = provider.relayRequested else { return RelayWebFragmentSet() }
        return RelayWebFragmentSet.from(objects: requested.legacyWebFragments(profiles: profiles))
    }

    /// Fragments carried by a chat send: only for relay-form, non-local-engine connections; returns nil when there is no fragment.
    func chatFragments(for provider: Provider) -> RelayWebFragmentSet? {
        guard ProviderForm.of(provider) == .relay,
              provider.relayRequested?.engineProfile?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        else { return nil }
        let set = effective(provider: provider)
        return set.isEmpty ? nil : set
    }

    /// Whether the connection has an effective fragment on this protocol (shared by the panel, badge and truth).
    func hasEffectiveFragment(provider: Provider, transport: RelayTransport) -> Bool {
        chatFragments(for: provider)?.object(for: transport) != nil
    }

    private func load() -> [String: [String: String]] {
        (defaults.dictionary(forKey: Self.storageKey) as? [String: [String: String]]) ?? [:]
    }

    private func mutate(_ change: (inout [String: [String: String]]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var all = load()
        change(&all)
        if all.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else {
            defaults.set(all, forKey: Self.storageKey)
        }
    }
}
