import Foundation



/// `RuntimeConfigSelfHealPattern` / web `UnsupportedParamPatternDefinition`).
struct SelfHealPatternDefinition: Codable, Sendable, Equatable {
    let pattern: String
    let flags: String?
    let param: String?

    init(pattern: String, flags: String? = nil, param: String? = nil) {
        self.pattern = pattern
        self.flags = flags
        self.param = param
    }
}


enum UnsupportedParamClassifier {
    private static let baselinePatterns: [NSRegularExpression] = {
        let param = #"([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*)"#
        let raws = [
            #"does not support parameter ['"]?\#(param)"#,          // xAI
            #"Unsupported parameter\b:?\s*['"]?\#(param)"#,
            #"unrecognized request arguments? supplied:?\s*['"]?\#(param)"#, // OpenAI
            #"unknown (?:parameter|field|argument):?\s*['"]?\#(param)"#,
            #"unexpected (?:field|parameter):?\s*['"]?\#(param)"#,
            #"Unknown name ['"]?\#(param)"#,                        // Gemini
        ]
        return raws.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    private struct CompiledPattern {
        let regex: NSRegularExpression
        let fixedParam: String?
    }

    private static let runtimeLock = NSLock()
    private static var runtimePatterns: [CompiledPattern] = []

    private static let fixedParamShape = try? NSRegularExpression(pattern: #"^[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*$"#)

    static func setRuntimePatterns(_ definitions: [SelfHealPatternDefinition]) {
        let compiled: [CompiledPattern] = definitions.compactMap { def in
            guard !def.pattern.isEmpty, def.pattern.count <= 200 else { return nil }
            let options: NSRegularExpression.Options = def.flags == "i" ? [.caseInsensitive] : []
            guard let regex = try? NSRegularExpression(pattern: def.pattern, options: options) else { return nil }
            return CompiledPattern(regex: regex, fixedParam: sanitizedFixedParam(def.param))
        }
        runtimeLock.lock(); defer { runtimeLock.unlock() }
        runtimePatterns = compiled
    }

    private static func sanitizedFixedParam(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed.count <= 64,
              let shape = fixedParamShape else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return shape.firstMatch(in: trimmed, options: [], range: range) == nil ? nil : trimmed
    }

    private static func runtimePatternsSnapshot() -> [CompiledPattern] {
        runtimeLock.lock(); defer { runtimeLock.unlock() }
        return runtimePatterns
    }

    static func parameterName(status: Int, detail: String?) -> String? {
        guard status == 400, let detail, !detail.isEmpty else { return nil }
        let candidates = baselinePatterns.map { CompiledPattern(regex: $0, fixedParam: nil) }
            + runtimePatternsSnapshot()
        let range = NSRange(detail.startIndex..<detail.endIndex, in: detail)
        for candidate in candidates {
            guard let match = candidate.regex.firstMatch(in: detail, options: [], range: range) else { continue }
            if match.numberOfRanges > 1, let groupRange = Range(match.range(at: 1), in: detail) {
                return normalize(String(detail[groupRange]))
            }
            if let fixedParam = candidate.fixedParam {
                return normalize(fixedParam)
            }
        }
        return nil
    }

    nonisolated static func normalize(_ name: String) -> String {
        var out = ""
        for ch in name {
            if ch.isUppercase {
                if !out.isEmpty { out.append("_") }
                out.append(Character(ch.lowercased()))
            } else {
                out.append(ch)
            }
        }
        return out
    }
}


enum UnsupportedParamJSON {
    static func strippedBody(_ body: Data, dropping params: Set<String>) -> Data? {
        guard !params.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: body) else { return nil }

        var changed = false
        let value = strippedValue(root, dropping: params, pruneEmptyObjects: false, changed: &changed)

        guard changed,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value)
        else { return nil }
        return data
    }

    static func strippedObject(
        _ object: [String: Any],
        dropping params: Set<String>,
        pruneEmptyObjects: Bool = false
    ) -> [String: Any]? {
        guard !params.isEmpty else { return nil }
        var changed = false
        let value = strippedValue(object, dropping: params, pruneEmptyObjects: pruneEmptyObjects, changed: &changed)
        guard changed else { return nil }
        return value as? [String: Any]
    }

    static func isEffectivelyEmpty(_ object: [String: Any]) -> Bool {
        object.values.allSatisfy { value in
            if let nested = value as? [String: Any] {
                return isEffectivelyEmpty(nested)
            }
            return false
        }
    }

    private static func strippedValue(
        _ value: Any,
        dropping params: Set<String>,
        pruneEmptyObjects: Bool,
        changed: inout Bool
    ) -> Any {
        var output = value
        for param in params {
            output = removeAtPath(output, path: [param], changed: &changed)
            for path in candidateNestedPaths(param) {
                output = removeAtPath(output, path: path, changed: &changed)
            }
        }
        return pruneEmptyObjects ? prunedEmptyObjects(output) : output
    }

    private static func comparableKey(_ value: String) -> String {
        UnsupportedParamClassifier.normalize(value)
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
    }

    private static func removeAtPath(_ value: Any, path: [String], changed: inout Bool) -> Any {
        guard !path.isEmpty else { return value }
        if let dict = value as? [String: Any] {
            let head = comparableKey(path[0])
            var output: [String: Any] = [:]
            for (key, child) in dict {
                guard comparableKey(key) == head else {
                    output[key] = child
                    continue
                }
                if path.count == 1 {
                    changed = true
                    continue
                }
                if child is [String: Any] || child is [Any] {
                    output[key] = removeAtPath(child, path: Array(path.dropFirst()), changed: &changed)
                } else {
                    output[key] = child
                }
            }
            return output
        }
        return value
    }

    private static func prunedEmptyObjects(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var output: [String: Any] = [:]
            for (key, child) in dict {
                let pruned = prunedEmptyObjects(child)
                if let nested = pruned as? [String: Any],
                   nested.isEmpty || isEffectivelyEmpty(nested) {
                    continue
                }
                output[key] = pruned
            }
            return output
        }
        if let array = value as? [Any] {
            return array.map { prunedEmptyObjects($0) }
        }
        return value
    }

    private static func splitPath(_ name: String) -> [String] {
        if name.contains(".") {
            return name.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        }
        if name.contains("_") {
            return name.split(separator: "_").map(String.init).filter { !$0.isEmpty }
        }

        var parts: [String] = []
        var current = ""
        for ch in name {
            if ch.isUppercase, !current.isEmpty {
                parts.append(current)
                current = String(ch).lowercased()
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func candidateNestedPaths(_ param: String) -> [[String]] {
        let canonical = UnsupportedParamClassifier.normalize(param)
        var paths: [[String]] = param.contains(".")
            ? [param.split(separator: ".").map(String.init).filter { !$0.isEmpty }]
            : []
        let words = splitPath(param)
        if words.count == 2, ["reasoning", "text", "output", "generation"].contains(words[0]) {
            paths.append(words)
        }
        let aliases = [canonical, snakeToCamel(canonical)]
        for wrapper in ["generationConfig", "generation_config", "extra_body", "output_config"] {
            for alias in aliases { paths.append([wrapper, alias]) }
        }
        if canonical == "thinking_config" {
            paths.append(contentsOf: [["generationConfig", "thinkingConfig"], ["generation_config", "thinking_config"]])
        }
        if canonical == "reasoning_effort" || canonical == "effort" {
            paths.append(["reasoning", "effort"])
        }
        return paths
    }

    private static func snakeToCamel(_ value: String) -> String {
        let parts = value.split(separator: "_")
        guard let first = parts.first else { return value }
        return String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + String($0.dropFirst()) }.joined()
    }
}

final class UnsupportedParamCache: @unchecked Sendable {
    static let shared = UnsupportedParamCache()

    private struct Entry: Codable, Sendable {
        let partitionID: String
        let connectionInstanceID: String
        let connectionGeneration: String
        let credentialEpoch: String
        let providerKind: String
        let modelID: String
        let transport: String
        let endpointFingerprint: String
        let metadataRevision: String?
        let generationRevision: String?
        let runtimeRevision: String?
        let parameter: String
        let observedAt: Date
    }

    private struct CapabilityEntry: Codable, Sendable {
        let connectionID: String
        let canonicalModelID: String
        let finalTransport: String
        let runtimeRevision: String
        let source: CapabilityRejectionSource
        let owner: String
        let recipeRef: String?
        let setting: String
        let capabilityKey: String?
        let observedAt: Date
    }

    private let lock = NSLock()
    private var unsupported: [String: Entry] = [:]
    private var capabilityRejected: [String: CapabilityEntry] = [:]
    private let defaults: UserDefaults
    private let defaultsKey = "unsupported_parameter_cache.v2"
    private let capabilityDefaultsKey = "capability_runtime_rejection_cache.v1"
    private let ttl: TimeInterval = 24 * 60 * 60
    private let maximumEntries = 500

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey),
           let stored = try? JSONDecoder().decode([String: Entry].self, from: data) {
            unsupported = stored
        }
        if let data = defaults.data(forKey: capabilityDefaultsKey),
           let stored = try? JSONDecoder().decode([String: CapabilityEntry].self, from: data) {
            capabilityRejected = stored
        }
    }

    private func canonicalParamName(_ param: String) -> String {
        UnsupportedParamClassifier.normalize(param.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func prefix(
        _ providerKind: ProviderKind,
        _ modelID: String,
        _ endpointFingerprint: String?,
        identity: CapabilityEvidenceRequestIdentity? = nil,
        requiresRuntimeRevision: Bool = false
    ) -> String? {
        // A task with a capability identity is production traffic. Missing any identity component
        // then means "retry this request only", never fall back to the old broad cache key.
        if let identity {
            let query = identity.query
            guard query.providerKind == providerKind.rawValue,
                  query.modelID == modelID || query.effectiveModelID == modelID,
                  query.endpointFingerprint == endpointFingerprint,
                  !query.partitionID.isEmpty,
                  !query.connectionInstanceID.isEmpty,
                  !query.connectionGeneration.isEmpty,
                  !query.credentialEpoch.isEmpty,
                  query.metadataRevision != nil || query.generationRevision != nil || identity.runtimeRevision != nil,
                  !requiresRuntimeRevision
                    || !(identity.runtimeRevision?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                  !query.effectiveTransport.isEmpty else { return nil }
            return [
                query.partitionID, query.connectionInstanceID, query.connectionGeneration,
                query.credentialEpoch, providerKind.rawValue, query.effectiveModelID, query.effectiveTransport,
                endpointFingerprint ?? "", query.metadataRevision ?? "", query.generationRevision ?? "",
                identity.runtimeRevision ?? "",
            ].map(Self.keyComponent).joined(separator: "|") + "|"
        }
        return nil
    }

    nonisolated private static func keyComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private func key(
        _ providerKind: ProviderKind,
        _ modelID: String,
        _ param: String,
        _ endpointFingerprint: String?,
        identity: CapabilityEvidenceRequestIdentity? = nil
    ) -> String? {
        let canonical = canonicalParamName(param)
        return prefix(
            providerKind, modelID, endpointFingerprint, identity: identity,
            requiresRuntimeRevision: canonical.hasPrefix(Self.capabilityNamespace)
        ).map { "\($0)\(canonical)" }
    }

    func canReuseAcrossRequests(
        providerKind: ProviderKind,
        modelID: String,
        endpointFingerprint: String?,
        identity: CapabilityEvidenceRequestIdentity?
    ) -> Bool {
        prefix(providerKind, modelID, endpointFingerprint, identity: identity) != nil
    }

    @discardableResult
    func markUnsupported(
        providerKind: ProviderKind,
        modelID: String,
        param: String,
        endpointFingerprint: String? = nil,
        identity: CapabilityEvidenceRequestIdentity? = nil
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        guard let cacheKey = key(providerKind, modelID, param, endpointFingerprint, identity: identity) else { return false }
        let firstTime = unsupported[cacheKey] == nil
        if let identity {
            let query = identity.query
            unsupported[cacheKey] = Entry(
                partitionID: query.partitionID, connectionInstanceID: query.connectionInstanceID,
                connectionGeneration: query.connectionGeneration, credentialEpoch: query.credentialEpoch,
                providerKind: providerKind.rawValue, modelID: query.effectiveModelID, transport: query.effectiveTransport,
                endpointFingerprint: endpointFingerprint ?? "", metadataRevision: query.metadataRevision,
                generationRevision: query.generationRevision, runtimeRevision: identity.runtimeRevision,
                parameter: canonicalParamName(param), observedAt: Date()
            )
        }
        if unsupported.count > maximumEntries,
           let oldest = unsupported.min(by: { $0.value.observedAt < $1.value.observedAt })?.key {
            unsupported.removeValue(forKey: oldest)
        }
        persistLocked()
        return firstTime
    }

    func isUnsupported(
        providerKind: ProviderKind,
        modelID: String,
        param: String,
        endpointFingerprint: String? = nil,
        identity: CapabilityEvidenceRequestIdentity? = nil
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        guard let cacheKey = key(providerKind, modelID, param, endpointFingerprint, identity: identity) else { return false }
        persistLocked()
        return unsupported[cacheKey] != nil
    }

    func droppedParams(
        providerKind: ProviderKind,
        modelID: String,
        endpointFingerprint: String? = nil,
        identity: CapabilityEvidenceRequestIdentity? = nil
    ) -> Set<String> {
        Set(rawEntryNames(
            providerKind: providerKind, modelID: modelID,
            endpointFingerprint: endpointFingerprint, identity: identity
        ).filter { !$0.hasPrefix(Self.capabilityNamespace) })
    }

    /// Legacy generation-param namespace stays readable until but capability rejection never
    /// uses its broad provider/model/endpoint/metadata prefix. The new cache below has one frozen
    /// identity: connection + canonical model + final transport + runtime revision + source/setting.
    static let capabilityNamespace = "capability:"

    nonisolated private static func hex(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func capabilityKey(
        connectionID: String,
        canonicalModelID: String,
        finalTransport: String,
        runtimeRevision: String,
        source: CapabilityRejectionSource,
        owner: String,
        recipeRef: String?,
        setting: String
    ) -> String {
        [connectionID, canonicalModelID, finalTransport, runtimeRevision, source.rawValue, owner,
         recipeRef ?? "", setting]
            .map(hex).joined(separator: "|")
    }

    private func capabilityIdentity(
        providerKind: ProviderKind,
        modelID: String,
        identity: CapabilityEvidenceRequestIdentity
    ) -> (connectionID: String, canonicalModelID: String, finalTransport: String, runtimeRevision: String)? {
        let query = identity.query
        let revision = identity.runtimeRevision?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard query.providerKind == providerKind.rawValue,
              query.modelID == modelID || query.effectiveModelID == modelID,
              !query.connectionInstanceID.isEmpty,
              !query.effectiveModelID.isEmpty,
              !query.effectiveTransport.isEmpty,
              !revision.isEmpty else { return nil }
        return (query.connectionInstanceID, query.effectiveModelID, query.effectiveTransport, revision)
    }

    @discardableResult
    func markCapabilityRejected(
        providerKind: ProviderKind,
        modelID: String,
        source: CapabilityRejectionSource = .providerRecipe,
        owner: String,
        recipeRef: String? = nil,
        setting: String,
        capabilityKey: String? = nil,
        endpointFingerprint: String?,
        identity: CapabilityEvidenceRequestIdentity
    ) -> Bool {
        _ = endpointFingerprint // Endpoint, metadata and generation revisions are not part of the identity.
        guard let exact = capabilityIdentity(
            providerKind: providerKind, modelID: modelID, identity: identity
        ), !owner.isEmpty, !setting.isEmpty,
           source != .providerRecipe || !(recipeRef?.isEmpty ?? true) else { return false }
        let key = Self.capabilityKey(
            connectionID: exact.connectionID, canonicalModelID: exact.canonicalModelID,
            finalTransport: exact.finalTransport, runtimeRevision: exact.runtimeRevision,
            source: source, owner: owner, recipeRef: recipeRef, setting: setting
        )
        lock.lock()
        defer { lock.unlock() }
        pruneCapabilityLocked()
        let firstTime = capabilityRejected[key] == nil
        capabilityRejected[key] = .init(
            connectionID: exact.connectionID, canonicalModelID: exact.canonicalModelID,
            finalTransport: exact.finalTransport, runtimeRevision: exact.runtimeRevision,
            source: source, owner: owner, recipeRef: recipeRef, setting: setting,
            capabilityKey: capabilityKey, observedAt: Date()
        )
        if capabilityRejected.count > maximumEntries,
           let oldest = capabilityRejected.min(by: { $0.value.observedAt < $1.value.observedAt })?.key {
            capabilityRejected.removeValue(forKey: oldest)
        }
        persistCapabilityLocked()
        return firstTime
    }

    func capabilityRejectedCandidates(
        providerKind: ProviderKind,
        modelID: String,
        endpointFingerprint: String?,
        identity: CapabilityEvidenceRequestIdentity
    ) -> [CapabilityEvidenceFacade.Candidate] {
        _ = endpointFingerprint
        guard let exact = capabilityIdentity(
            providerKind: providerKind, modelID: modelID, identity: identity
        ) else { return [] }
        let cutoff = Date().addingTimeInterval(-ttl)
        lock.lock()
        let entries = capabilityRejected.values.filter {
            $0.observedAt >= cutoff
                && $0.connectionID == exact.connectionID
                && $0.canonicalModelID == exact.canonicalModelID
                && $0.finalTransport == exact.finalTransport
                && $0.runtimeRevision == exact.runtimeRevision
                && $0.source == .providerRecipe
                && $0.capabilityKey != nil
        }
        lock.unlock()
        return entries.compactMap { entry in
            guard let capabilityKey = entry.capabilityKey else { return nil }
            return CapabilityEvidenceProductionAdapter.runtimeRejectedCandidate(
                capabilityKey: capabilityKey, identity: identity, observedAt: entry.observedAt
            )
        }
    }

    /// Custom settings use the same durable identity but never become typed facade candidates.
    /// Endpoint is intentionally ignored here: the identity is connection + canonical model +
    /// final transport + runtime revision, and filtering happens before a provider builder has a URL.
    func customRejectedPointers(
        providerKind: ProviderKind,
        modelID: String,
        owner: String,
        identity: CapabilityEvidenceRequestIdentity
    ) -> Set<String> {
        guard let exact = capabilityIdentity(
            providerKind: providerKind, modelID: modelID, identity: identity
        ) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        pruneCapabilityLocked()
        persistCapabilityLocked()
        return Set(capabilityRejected.values.compactMap { entry in
            guard entry.connectionID == exact.connectionID,
                  entry.canonicalModelID == exact.canonicalModelID,
                  entry.finalTransport == exact.finalTransport,
                  entry.runtimeRevision == exact.runtimeRevision,
                  entry.source == .custom,
                  entry.owner == owner else { return nil }
            return entry.setting
        })
    }

    func recipeRejectedPointers(
        providerKind: ProviderKind,
        modelID: String,
        owner: String,
        recipeRef: String,
        identity: CapabilityEvidenceRequestIdentity
    ) -> Set<String> {
        guard let exact = capabilityIdentity(
            providerKind: providerKind, modelID: modelID, identity: identity
        ) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        pruneCapabilityLocked()
        persistCapabilityLocked()
        return Set(capabilityRejected.values.compactMap { entry in
            guard entry.connectionID == exact.connectionID,
                  entry.canonicalModelID == exact.canonicalModelID,
                  entry.finalTransport == exact.finalTransport,
                  entry.runtimeRevision == exact.runtimeRevision,
                  entry.source == .providerRecipe,
                  entry.owner == owner,
                  entry.recipeRef == recipeRef else { return nil }
            return entry.setting
        })
    }

    /// Editing or explicitly reselecting a custom fragment is reconfirmation for that source only.
    /// Recipe rejections sharing the same owner remain dormant and vice versa.
    func clearCustomRejections(
        providerKind: ProviderKind,
        modelID: String,
        owner: String,
        identity: CapabilityEvidenceRequestIdentity
    ) {
        guard let exact = capabilityIdentity(
            providerKind: providerKind, modelID: modelID, identity: identity
        ) else { return }
        lock.lock()
        defer { lock.unlock() }
        capabilityRejected = capabilityRejected.filter { _, entry in
            guard entry.connectionID == exact.connectionID,
                  entry.canonicalModelID == exact.canonicalModelID,
                  entry.finalTransport == exact.finalTransport,
                  entry.runtimeRevision == exact.runtimeRevision,
                  entry.source == .custom,
                  entry.owner == owner else { return true }
            return false
        }
        persistCapabilityLocked()
    }

    func clearCapabilityRejections(connectionID: String) {
        guard !connectionID.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        capabilityRejected = capabilityRejected.filter { $0.value.connectionID != connectionID }
        persistCapabilityLocked()
    }

    private func rawEntryNames(
        providerKind: ProviderKind,
        modelID: String,
        endpointFingerprint: String?,
        identity: CapabilityEvidenceRequestIdentity?
    ) -> [String] {
        let requiresRuntimeRevision = !(identity?.runtimeRevision?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard let prefix = prefix(
            providerKind, modelID, endpointFingerprint, identity: identity,
            requiresRuntimeRevision: requiresRuntimeRevision
        ) else { return [] }
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        persistLocked()
        return unsupported.keys.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
    }

    func runtimeRejectedCandidate(
        providerKind: ProviderKind,
        modelID: String,
        param: String,
        endpointFingerprint: String?,
        identity: CapabilityEvidenceRequestIdentity
    ) -> CapabilityEvidenceFacade.Candidate? {
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        guard let cacheKey = key(providerKind, modelID, param, endpointFingerprint, identity: identity),
              let entry = unsupported[cacheKey] else { return nil }
        return CapabilityEvidenceProductionAdapter.runtimeRejectedCandidate(
            parameterID: param,
            identity: identity,
            observedAt: entry.observedAt
        )
    }

    func facadeDroppedParams(
        providerKind: ProviderKind,
        modelID: String,
        endpointFingerprint: String?,
        identity: CapabilityEvidenceRequestIdentity
    ) -> Set<String> {
        droppedParams(
            providerKind: providerKind,
            modelID: modelID,
            endpointFingerprint: endpointFingerprint,
            identity: identity
        ).filter { parameter in
            guard let candidate = runtimeRejectedCandidate(
                providerKind: providerKind,
                modelID: modelID,
                param: parameter,
                endpointFingerprint: endpointFingerprint,
                identity: identity
            ) else { return false }
            let result = CapabilityEvidenceFacade.resolve(
                key: candidate.key,
                query: identity.query,
                candidates: [candidate]
            )
            return result.requestPolicy == .omitRuntimeRejected
        }
    }

    func clear(
        providerKind: ProviderKind,
        modelID: String,
        identity: CapabilityEvidenceRequestIdentity
    ) {
        let query = identity.query
        guard query.providerKind == providerKind.rawValue,
              query.effectiveModelID == modelID,
              !query.partitionID.isEmpty,
              !query.connectionInstanceID.isEmpty,
              !query.connectionGeneration.isEmpty,
              !query.credentialEpoch.isEmpty else { return }
        // User clear deliberately spans endpoint/revision variants of this exact connection+model,
        // but cannot reach another partition, credential epoch, or deleted/recreated connection.
        lock.lock(); defer { lock.unlock() }
        unsupported = unsupported.filter { _, entry in
            !(entry.partitionID == query.partitionID
                && entry.connectionInstanceID == query.connectionInstanceID
                && entry.connectionGeneration == query.connectionGeneration
                && entry.credentialEpoch == query.credentialEpoch
                && entry.providerKind == providerKind.rawValue
                && entry.modelID == query.effectiveModelID)
        }
        capabilityRejected = capabilityRejected.filter { _, entry in
            !(entry.connectionID == query.connectionInstanceID
                && entry.canonicalModelID == query.effectiveModelID)
        }
        persistLocked()
        persistCapabilityLocked()
    }

    private func pruneLocked() {
        let cutoff = Date().addingTimeInterval(-ttl)
        unsupported = unsupported.filter { $0.value.observedAt >= cutoff }
    }

    private func pruneCapabilityLocked() {
        let cutoff = Date().addingTimeInterval(-ttl)
        capabilityRejected = capabilityRejected.filter { $0.value.observedAt >= cutoff }
    }

    private func persistLocked() {
        if unsupported.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(unsupported) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    private func persistCapabilityLocked() {
        if capabilityRejected.isEmpty {
            defaults.removeObject(forKey: capabilityDefaultsKey)
        } else if let data = try? JSONEncoder().encode(capabilityRejected) {
            defaults.set(data, forKey: capabilityDefaultsKey)
        }
    }

    #if DEBUG
    func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        unsupported.removeAll()
        capabilityRejected.removeAll()
        defaults.removeObject(forKey: defaultsKey)
        defaults.removeObject(forKey: capabilityDefaultsKey)
    }
    #endif
}

enum UnsupportedParamSelfHealReporter {
    @discardableResult
    static func markDropped(
        providerKind: ProviderKind,
        modelID: String,
        param: String,
        endpointFingerprint: String? = nil,
        identity: CapabilityEvidenceRequestIdentity? = nil
    ) -> Bool {
        let canReuseAcrossRequests = UnsupportedParamCache.shared.canReuseAcrossRequests(
            providerKind: providerKind,
            modelID: modelID,
            endpointFingerprint: endpointFingerprint,
            identity: identity
        )
        let firstTime = UnsupportedParamCache.shared.markUnsupported(
            providerKind: providerKind,
            modelID: modelID,
            param: param,
            endpointFingerprint: endpointFingerprint,
            identity: identity
        )
        // Missing identity/revision is no-cache only: the successful retry remains a real producer event.
        // A complete identity may suppress side effects only after its exact cache entry already exists.
        if firstTime || !canReuseAcrossRequests {
            Task(priority: .utility) {
                await MetadataClient.shared.forceRefresh()
            }
        }
        return firstTime
    }

}

enum UnsupportedParamSelfHeal {
    /// the original shape; lack of runtime identity can never authorize a strip/retry.
    static func wrapStream<Event>(
        providerKind: ProviderKind,
        modelID: String,
        endpointFingerprint: String? = nil,
        makeStream: @escaping (_ droppedParams: Set<String>) -> AsyncThrowingStream<Event, Error>
    ) -> AsyncThrowingStream<Event, Error> {
        _ = providerKind
        _ = modelID
        _ = endpointFingerprint
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in makeStream([]) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
