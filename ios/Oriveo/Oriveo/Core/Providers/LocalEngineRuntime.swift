import Foundation

nonisolated struct LocalRuntimeSettings: Codable, Equatable, Sendable {
    var contextLength: Int?
    var keepAlive: String?
    var speculativeModel: String?
    var cacheReuseTokens: Int?
}

final class LocalRuntimeSettingsStore: @unchecked Sendable {
    static let shared = LocalRuntimeSettingsStore()
    private let defaults: UserDefaults
    private let key = "local_runtime_settings.v1"
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func fingerprint(endpoint: String, engine: LocalEngineKind) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(engine.rawValue)|\(endpoint)".utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }

    func load(endpointFingerprint: String) -> LocalRuntimeSettings {
        lock.lock(); defer { lock.unlock() }
        return recordsLocked()[endpointFingerprint] ?? .init()
    }

    func save(_ settings: LocalRuntimeSettings, endpointFingerprint: String) {
        lock.lock(); defer { lock.unlock() }
        var records = recordsLocked()
        records[endpointFingerprint] = settings
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: key) }
    }

    func remove(endpointFingerprint: String) {
        lock.lock(); defer { lock.unlock() }
        var records = recordsLocked()
        records.removeValue(forKey: endpointFingerprint)
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: key) }
    }

    private func recordsLocked() -> [String: LocalRuntimeSettings] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: LocalRuntimeSettings].self, from: data)) ?? [:]
    }
}

nonisolated struct LocalRuntimeSnapshot: Equatable, Sendable {
    var health: LocalEngineState?
    var loadedModelIDs: [String]
    var ttftMilliseconds: Double?
    var tokensPerSecond: Double?
    var contextUsed: Int?
    var contextLimit: Int?
    var queueDepth: Int?
    var cpuPercent: Double?
    var gpuPercent: Double?
}

nonisolated enum LocalPromptPreflight: Equatable, Sendable {
    case supported(tokens: Int, contextLimit: Int?, exceedsContext: Bool)
    case unavailable
}

/// Production parsers keep unavailable observations nil. Zero is preserved only when the engine actually reports zero.
enum LocalRuntimeParser {
    static func snapshot(
        engine: LocalEngineKind,
        statusJSON: Any?,
        metricsText: String? = nil,
        timingsJSON: Any? = nil
    ) -> LocalRuntimeSnapshot {
        let object = statusJSON as? [String: Any] ?? [:]
        let slots = object["slots"] as? [[String: Any]] ?? (statusJSON as? [[String: Any]]) ?? []
        let models = object["models"] as? [[String: Any]] ?? object["data"] as? [[String: Any]] ?? []
        let loaded = models.compactMap { ($0["name"] ?? $0["model"] ?? $0["id"]) as? String }
        let timings = timingsJSON as? [String: Any] ?? object["timings"] as? [String: Any] ?? [:]
        let promptMS = number(timings["prompt_ms"] ?? timings["prompt_eval_duration"])
        let predictedMS = number(timings["predicted_ms"] ?? timings["eval_duration"])
        let predictedN = number(timings["predicted_n"] ?? timings["eval_count"])
        let metricValues = parsePrometheus(metricsText)
        let contextUsed = integer(object["n_past"] ?? slots.compactMap { integer($0["n_past"]) }.max())
        let contextLimit = integer(object["n_ctx"] ?? object["context_length"] ?? slots.compactMap { integer($0["n_ctx"]) }.max())
        let queue = integer(object["queue"] ?? object["queue_depth"])
            ?? metricValues.first(suffix: "requests_waiting").map(Int.init)
        let tokensPerSecond = number(timings["predicted_per_second"] ?? timings["tokens_per_second"])
            ?? ((predictedMS ?? 0) > 0 && predictedN != nil ? predictedN! / predictedMS! * 1_000 : nil)
        return LocalRuntimeSnapshot(
            health: object.isEmpty && slots.isEmpty ? nil : .ready,
            loadedModelIDs: Array(Set(loaded)).sorted(),
            ttftMilliseconds: promptMS,
            tokensPerSecond: tokensPerSecond,
            contextUsed: contextUsed,
            contextLimit: contextLimit,
            queueDepth: queue,
            cpuPercent: number(object["cpu_percent"]) ?? metricValues.first(suffix: "cpu_percent"),
            gpuPercent: number(object["gpu_percent"]) ?? metricValues.first(suffix: "gpu_percent")
        )
    }

    static func tokenCount(_ json: Any?) -> Int? {
        if let object = json as? [String: Any] {
            if let tokens = object["tokens"] as? [Any] { return tokens.count }
            return integer(object["count"] ?? object["n_tokens"])
        }
        if let tokens = json as? [Any] { return tokens.count }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue.isFinite ? value.doubleValue : nil }
        if let value = value as? String, let parsed = Double(value), parsed.isFinite { return parsed }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? { number(value).map(Int.init) }

    private static func parsePrometheus(_ text: String?) -> [String: Double] {
        guard let text else { return [:] }
        return text.split(separator: "\n").reduce(into: [:]) { result, line in
            guard !line.hasPrefix("#") else { return }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, let value = Double(parts.last!) else { return }
            result[String(parts[0])] = value
        }
    }
}

private extension Dictionary where Key == String, Value == Double {
    func first(suffix: String) -> Double? { first { $0.key.hasSuffix(suffix) }?.value }
}

enum LocalEngineRuntimeClient {
    static func status(
        endpoint: URL,
        engine: LocalEngineKind,
        requested: RelayRequestedConfig,
        apiKey: String = "",
        session: URLSession = .shared
    ) async -> LocalRuntimeSnapshot {
        let statusPath: String
        switch engine {
        case .llamacpp: statusPath = "/slots"
        case .ollama: statusPath = "/api/ps"
        case .lmstudio: statusPath = "/api/v1/models"
        case .vllm: statusPath = "/v1/models"
        case .openwebui: statusPath = "/api/models"
        }
        let statusJSON = try? await get(
            endpoint: endpoint, path: statusPath, requested: requested,
            apiKey: apiKey, session: session
        ).json
        let metrics = engine == .llamacpp || engine == .vllm
            ? try? await get(
                endpoint: endpoint, path: "/metrics", requested: requested,
                apiKey: apiKey, session: session
            ).text
            : nil
        return LocalRuntimeParser.snapshot(engine: engine, statusJSON: statusJSON, metricsText: metrics)
    }

    static func preflight(
        endpoint: URL,
        engine: LocalEngineKind,
        prompt: String,
        contextLimit: Int?,
        requested: RelayRequestedConfig,
        session: URLSession = .shared
    ) async -> LocalPromptPreflight {
        guard engine == .llamacpp else { return .unavailable }
        do {
            let templated = try await postJSON(
                endpoint: endpoint,
                path: "/apply-template",
                body: ["prompt": prompt, "add_generation_prompt": true],
                requested: requested,
                session: session
            )
            let finalPrompt = (templated as? [String: Any])?["prompt"] as? String ?? prompt
            let tokenized = try await postJSON(
                endpoint: endpoint,
                path: "/tokenize",
                body: ["content": finalPrompt],
                requested: requested,
                session: session
            )
            guard let count = LocalRuntimeParser.tokenCount(tokenized) else { return .unavailable }
            let observedLimit: Int?
            if let contextLimit {
                observedLimit = contextLimit
            } else {
                observedLimit = await status(
                    endpoint: endpoint, engine: engine, requested: requested, session: session
                ).contextLimit
            }
            return .supported(tokens: count, contextLimit: observedLimit, exceedsContext: observedLimit.map { count > $0 } ?? false)
        } catch {
            return .unavailable
        }
    }

    static func promptCache(
        endpoint: URL,
        slotID: Int,
        action: String,
        cacheName: String,
        requested: RelayRequestedConfig,
        session: URLSession = .shared
    ) async throws {
        guard action == "save" || action == "restore", slotID >= 0 else { throw URLError(.badURL) }
        let encoded = cacheName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        _ = try await postJSON(
            endpoint: endpoint,
            path: "/slots/\(slotID)?action=\(action)&filename=\(encoded)",
            body: [:],
            requested: requested,
            session: session
        )
    }

    private static func postJSON(
        endpoint: URL,
        path: String,
        body: [String: Any],
        requested: RelayRequestedConfig,
        session: URLSession
    ) async throws -> Any? {
        guard let url = URL(string: path, relativeTo: endpoint)?.absoluteURL else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.applyRelaySecurityMode(requested)
        let (data, response) = try await session.relayData(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func get(
        endpoint: URL,
        path: String,
        requested: RelayRequestedConfig,
        apiKey: String = "",
        session: URLSession
    ) async throws -> (json: Any?, text: String) {
        guard let url = URL(string: path, relativeTo: endpoint)?.absoluteURL else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.applyRelaySecurityMode(requested)
        let (data, response) = try await session.relayData(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return (try? JSONSerialization.jsonObject(with: data), String(decoding: data, as: UTF8.self))
    }
}
