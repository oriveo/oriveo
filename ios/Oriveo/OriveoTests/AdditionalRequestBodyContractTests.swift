import Foundation
import Testing
@testable import Oriveo

/// Additional request body. The rules are `additionalBodyRules` in
/// `shared/model-contracts/generation_parameter_contract.v1.json`; the cases are
/// `additionalBodyCases` in `generation_parameter_contract.v1.cases.json` next to it. Every client
/// consumes the same table.
@Suite("additional request body contract", .serialized)
struct AdditionalRequestBodyContractTests {

    @Test("Every additionalBodyCase matches production parsing and merging exactly")
    func additionalBodyCases() throws {
        let contract = try GenerationOutboundPerItemContractTests.loadContract()
        let cases = try #require(contract["additionalBodyCases"] as? [[String: Any]])
        #expect(cases.count >= 21)

        for item in cases {
            let caseID = try #require(item["caseId"] as? String)
            let raw = try #require(item["raw"] as? String, "\(caseID) has no raw")
            let original = try #require(item["body"] as? [String: Any], "\(caseID) has no body")
            let expect = try #require(item["expect"] as? [String: Any])
            let expectedBody = try #require(expect["body"] as? [String: Any])
            let accepted = try #require(expect["accepted"] as? Bool)

            // Goes through the same entry point builders call at the final request-body boundary.
            var body = original
            var rejection: AdditionalRequestBodyRejection?
            do {
                try AdditionalRequestBody.apply(.init(raw: raw), to: &body)
            } catch let ProviderServiceError.additionalRequestBodyRejected(reason) {
                rejection = reason
            }

            #expect((rejection == nil) == accepted, "\(caseID) acceptance mismatch: \(String(describing: rejection))")
            #expect(
                NSDictionary(dictionary: body).isEqual(to: expectedBody),
                "\(caseID) body mismatch: \(body) != \(expectedBody)"
            )
            guard !accepted else { continue }
            #expect(rejection?.reason.rawValue == expect["reason"] as? String, "\(caseID) rejection reason mismatch")
            if let field = expect["field"] as? String {
                #expect(rejection?.field == field, "\(caseID) does not name field \(field)")
            }
            // requestSent=false: the entry point throws, so a builder never reaches JSON encoding or sending.
            #expect(expect["requestSent"] as? Bool == false)
            // marksConnectionFailed=false: decided by the production error classification.
            let error = ProviderServiceError.additionalRequestBodyRejected(try #require(rejection))
            #expect(error.marksConnectionFailed == (expect["marksConnectionFailed"] as? Bool))
        }
    }

    @Test("Protected fields, blocked segments, limits and rejection reasons equal the contract and the wire-hardening lists")
    func rulesMatchProductionConstants() throws {
        let contract = try GenerationOutboundPerItemContractTests.loadContract()
        let rules = try #require(contract["additionalBodyRules"] as? [String: Any])
        let protected = try #require(rules["protectedRootFields"] as? [String])
        #expect(Set(protected) == ProfileParamsResolver.builderOwnedRootFields)
        #expect(AdditionalRequestBody.protectedRootFields == ProfileParamsResolver.builderOwnedRootFields)
        #expect(Set(try #require(rules["blockedSegments"] as? [String])) == AdditionalRequestBody.blockedSegments)
        #expect(AdditionalRequestBody.blockedSegments == ProfileParamsResolver.blockedWireSegments)

        let limits = try #require(rules["limits"] as? [String: Any])
        #expect(limits["maxBytes"] as? Int == AdditionalRequestBody.maxBytes)
        #expect(limits["maxDepth"] as? Int == AdditionalRequestBody.maxDepth)
        #expect(
            Set(try #require(rules["rejectReasons"] as? [String]))
                == Set(AdditionalRequestBodyRejection.Reason.allCases.map(\.rawValue))
        )
    }

    @Test("Limits: exactly 64 KiB and 32 levels pass, one step over is rejected")
    func limits() {
        let padding = String(repeating: "a", count: AdditionalRequestBody.maxBytes - #"{"k":""}"#.utf8.count)
        let atLimit = #"{"k":""# + padding + #""}"#
        #expect(atLimit.utf8.count == AdditionalRequestBody.maxBytes)
        #expect(Self.reason(atLimit) == nil)
        #expect(Self.reason(#"{"k":""# + padding + #"a"}"#) == .tooLarge)

        func nested(_ levels: Int) -> String {
            String(repeating: #"{"a":"#, count: levels - 1) + "{}" + String(repeating: "}", count: levels - 1)
        }
        #expect(Self.reason(nested(AdditionalRequestBody.maxDepth)) == nil)
        #expect(Self.reason(nested(AdditionalRequestBody.maxDepth + 1)) == .tooDeep)
        // An array counts as a level too.
        #expect(Self.reason(#"{"a":"# + String(repeating: "[", count: 32) + String(repeating: "]", count: 32) + "}") == .tooDeep)
    }

    @Test("Protected fields apply at the root only; blocked segments are rejected at any depth; rejections carry a line number")
    func locatesTheOffendingField() throws {
        #expect(Self.reason(#"{"extra":{"model":"x","messages":[]}}"#) == nil, "a nested key of the same name is not part of the request skeleton")
        #expect(Self.reason("5") == .notObject)
        #expect(Self.reason("") == .invalidJSON)

        let protected = try #require(Self.rejection("{\n  \"top_k\": 1,\n  \"note\": \"model\",\n  \"model\": \"x\"\n}"))
        #expect(protected.reason == .protectedField)
        #expect(protected.field == "model")
        #expect(protected.line == 4, "model inside a value does not count; the line must point at the key")
        #expect(protected.safeCode == "additional_request_body_rejected:protected_field:model@4")

        let blocked = try #require(Self.rejection("{\"a\": [\n {\"ok\": 1},\n {\"constructor\": 1}\n]}"))
        #expect(blocked.reason == .blockedSegment)
        #expect(blocked.field == "constructor")
        #expect(blocked.line == 3)

        // The nested tools does not count, only the one at the root, and the line points at that one.
        let nestedFirst = try #require(Self.rejection("{\n \"a\": {\"tools\": 1},\n \"tools\": []\n}"))
        #expect(nestedFirst.field == "tools")
        #expect(nestedFirst.line == 3)

        // When both match, the blocked segment is reported first (same order as wire hardening).
        #expect(Self.reason(#"{"model":"x","a":{"__proto__":1}}"#) == .blockedSegment)
    }

    @Test("Merge: objects merge level by level, arrays and scalars (including null) replace, unmentioned keys stay")
    func mergeSemantics() throws {
        var body: [String: Any] = [
            "generationConfig": ["temperature": 0.5, "thinkingConfig": ["thinkingBudget": 1024]],
            "stop": ["a"], "temperature": 0.7, "keep": true,
        ]
        try AdditionalRequestBody.apply(.init(raw: """
        {"generationConfig": {"thinkingConfig": {"thinkingBudget": 0}, "topK": 3}, "stop": [], "temperature": null}
        """), to: &body)
        let config = try #require(body["generationConfig"] as? [String: Any])
        #expect(config["temperature"] as? Double == 0.5)
        #expect(config["topK"] as? Int == 3)
        #expect((config["thinkingConfig"] as? [String: Any])?["thinkingBudget"] as? Int == 0)
        #expect((body["stop"] as? [Any])?.isEmpty == true)
        #expect(body["temperature"] is NSNull)
        #expect(body["keep"] as? Bool == true)
    }

    @Test("Error classification: a local rejection does not mark the connection as failing")
    func rejectionClassification() {
        let rejection = AdditionalRequestBodyRejection(reason: .protectedField, field: "messages", line: 2)
        let error = ProviderServiceError.additionalRequestBodyRejected(rejection)
        #expect(!error.marksConnectionFailed)
        #expect(ProviderServiceError.invalidConfiguration(detail: "x").marksConnectionFailed)
        #expect(error.diagnosticCode == "additional_request_body_rejected")
        #expect(error.titleKey == AdditionalRequestBody.localRejectionTitleKey)
        #expect(error.technicalDetail == "additional_request_body_rejected:protected_field:messages@2")
        #expect(error.message.contains("messages"), "the message has to name the field")
    }

    @Test("Retry disposition: only a message rejected upstream while carrying the additional request body retries without it")
    func explicitRetryDisposition() {
        #expect(LocalCustomFragmentDisposition.forExplicitRetry(
            errorTitle: AdditionalRequestBody.upstreamRejectionTitleKey, recoveryDescriptorCount: nil
        ) == .omitAdditionalBodyForExplicitRetry)
        #expect(LocalCustomFragmentDisposition.forExplicitRetry(
            errorTitle: AdditionalRequestBody.localRejectionTitleKey, recoveryDescriptorCount: nil
        ) == .include)
        #expect(LocalCustomFragmentDisposition.forExplicitRetry(
            errorTitle: "Custom request fields error", recoveryDescriptorCount: nil
        ) == .omitForExplicitRetry)
        #expect(LocalCustomFragmentDisposition.forExplicitRetry(
            errorTitle: "Custom request fields error", recoveryDescriptorCount: 1
        ) == .include)
        #expect(LocalCustomFragmentDisposition.forExplicitRetry(
            errorTitle: "Provider Request Failed", recoveryDescriptorCount: nil
        ) == .include)
    }

    @Test("The retry offer needs all three: the body was merged, a 400 before any event, and no tool side effect")
    func recoveryGate() {
        func tracker(applied: Bool, status: Int?, event: Bool = false, sideEffect: Bool = false) -> Bool {
            let tracker = CapabilityExecutionTracker()
            if applied { tracker.recordAdditionalBodyApplied() }
            if event { tracker.recordUpstreamResponse() }
            if sideEffect { tracker.recordSideEffect() }
            if let status { tracker.recordUpstreamHTTPFailure(statusCode: status) }
            return tracker.canOfferRetryWithoutAdditionalBody
        }
        #expect(tracker(applied: true, status: 400))
        #expect(!tracker(applied: false, status: 400), "a 400 for a request without the additional request body is unrelated to it")
        #expect(!tracker(applied: true, status: nil))
        #expect(!tracker(applied: true, status: 401))
        #expect(!tracker(applied: true, status: 429))
        #expect(!tracker(applied: true, status: 500))
        #expect(!tracker(applied: true, status: 400, event: true), "a failure after the stream started does not count")
        #expect(!tracker(applied: true, status: 400, sideEffect: true), "a request must not be resent once a tool has run")

        // An event arriving afterwards closes the window too.
        let late = CapabilityExecutionTracker()
        late.recordAdditionalBodyApplied()
        late.recordUpstreamHTTPFailure(statusCode: 400)
        late.recordSideEffect()
        #expect(!late.canOfferRetryWithoutAdditionalBody)

        // An empty object is a no-op and does not count as carrying an additional request body.
        let empty = CapabilityExecutionTracker()
        CapabilityExecutionRuntime.$current.withValue(empty) {
            var body: [String: Any] = ["model": "m"]
            try? AdditionalRequestBody.apply(.init(raw: "{}"), to: &body)
        }
        empty.recordUpstreamHTTPFailure(statusCode: 400)
        #expect(!empty.canOfferRetryWithoutAdditionalBody)
    }

    // MARK: - Storage, migration, device-local

    @Test("Storage: switch and content are stored separately; a conversation without a record falls back to the model default; switched off keeps the content unsent")
    func storeScopesAndToggle() {
        let (store, defaults, suite) = Self.makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = UUID(), conversation = UUID()

        #expect(store.activeAdditionalRequestBody(providerID: provider, modelID: "m", conversationID: conversation) == nil)
        store.setAdditionalRequestBody(
            .init(rawJSON: #"{"top_k":40}"#, sendsWithRequest: true),
            providerID: provider, modelID: "m", conversationID: nil
        )
        #expect(store.activeAdditionalRequestBody(
            providerID: provider, modelID: "m", conversationID: conversation
        )?.raw == #"{"top_k":40}"#, "a conversation without a record uses the model default")
        #expect(store.activeAdditionalRequestBody(providerID: provider, modelID: "other", conversationID: nil) == nil)
        #expect(store.activeAdditionalRequestBody(providerID: UUID(), modelID: "m", conversationID: nil) == nil)

        // Switched off explicitly in the conversation: content stays, is not sent, and the model
        // default does not override it.
        store.setAdditionalRequestBody(
            .init(rawJSON: #"{"top_k":1}"#, sendsWithRequest: false),
            providerID: provider, modelID: "m", conversationID: conversation
        )
        #expect(store.activeAdditionalRequestBody(providerID: provider, modelID: "m", conversationID: conversation) == nil)
        #expect(store.effectiveAdditionalRequestBody(
            providerID: provider, modelID: "m", conversationID: conversation
        ) == .init(rawJSON: #"{"top_k":1}"#, sendsWithRequest: false))

        // Invalid content is still handed to the send boundary to reject; it is neither
        // pre-validated nor silently dropped here.
        store.setAdditionalRequestBody(
            .init(rawJSON: #"{"model":"#, sendsWithRequest: true),
            providerID: provider, modelID: "m", conversationID: conversation
        )
        #expect(store.activeAdditionalRequestBody(
            providerID: provider, modelID: "m", conversationID: conversation
        )?.raw == #"{"model":"#)

        // It follows a draft conversation that becomes a real one, and is removed together with
        // its conversation or connection.
        let real = UUID()
        store.migrateAdditionalRequestBody(providerID: provider, modelID: "m", from: conversation, to: real)
        #expect(store.additionalRequestBody(providerID: provider, modelID: "m", conversationID: conversation) == nil)
        #expect(store.additionalRequestBody(providerID: provider, modelID: "m", conversationID: real)?.sendsWithRequest == true)
        store.removeCapabilityScopes(conversationID: real)
        #expect(store.additionalRequestBody(providerID: provider, modelID: "m", conversationID: real) == nil)
        #expect(store.additionalRequestBody(providerID: provider, modelID: "m", conversationID: nil) != nil)
        store.removeCapabilityScopes(providerID: provider)
        #expect(store.additionalRequestBody(providerID: provider, modelID: "m", conversationID: nil) == nil)
    }

    @Test("Migration of stored fragments: one-shot, idempotent, lossless; invalid or switched-off content becomes an unsent draft")
    func legacyGenerationFragmentsMigrate() throws {
        let suite = "additional-body-migration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = UUID(), sending = UUID(), paused = UUID(), broken = UUID(), protected = UUID(), empty = UUID()
        let old = Date(timeIntervalSince1970: 1_000), new = Date(timeIntervalSince1970: 2_000)

        func legacy(
            _ conversation: UUID?, _ raw: String, mode: String?, namespace: String = "generationPatch",
            transport: String = "r1.a.b", at: Date = new
        ) -> [String: Any] {
            var record: [String: Any] = [
                "providerID": provider.uuidString, "modelID": "m", "transportIdentity": transport,
                "namespace": namespace, "rawJSON": raw, "updatedAt": at.timeIntervalSinceReferenceDate,
            ]
            if let conversation { record["conversationID"] = conversation.uuidString }
            if let mode { record["mode"] = mode }
            return record
        }
        let seeded: [[String: Any]] = [
            legacy(sending, #"{"top_k":40}"#, mode: "custom"),
            // A copy of the same scope under an older recipe revision: the most recently edited one wins.
            legacy(sending, #"{"top_k":1}"#, mode: "custom", transport: "r1.a.old", at: old),
            legacy(paused, #"{"min_p":0.1}"#, mode: "automatic"),
            legacy(broken, #"{"top_k": "#, mode: "custom"),
            legacy(protected, #"{"model":"x"}"#, mode: nil),
            legacy(empty, "  ", mode: "custom"),
            legacy(nil, #"{"seed":7}"#, mode: nil),
            legacy(sending, #"{"enable_search":true}"#, mode: "custom", namespace: "webPatch"),
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: seeded), forKey: "capability_preference_local_custom.v1"
        )

        let store = GenerationParameterSettingsStore(defaults: defaults)
        func config(_ conversation: UUID?) -> AdditionalRequestBodyConfiguration? {
            store.additionalRequestBody(providerID: provider, modelID: "m", conversationID: conversation)
        }
        #expect(config(sending) == .init(rawJSON: #"{"top_k":40}"#, sendsWithRequest: true))
        #expect(config(paused) == .init(rawJSON: #"{"min_p":0.1}"#, sendsWithRequest: false))
        #expect(config(broken) == .init(rawJSON: #"{"top_k": "#, sendsWithRequest: false), "truncated JSON is kept verbatim and not sent")
        #expect(config(protected) == .init(rawJSON: #"{"model":"x"}"#, sendsWithRequest: false))
        #expect(config(empty) == nil)
        // The oldest records have no mode; they were being sent at the time.
        #expect(config(nil) == .init(rawJSON: #"{"seed":7}"#, sendsWithRequest: true))

        // Generation records are gone from the old storage; web search and thinking ones are untouched.
        #expect(store.activeLocalCustomFragments(
            providerID: provider, modelID: "m", conversationID: sending, transportIdentity: "r1.a.b"
        ).map(\.owner) == ["web"])
        let remainingData = try #require(defaults.data(forKey: "capability_preference_local_custom.v1"))
        let remaining = try #require(JSONSerialization.jsonObject(with: remainingData) as? [[String: Any]])
        #expect(remaining.map { $0["namespace"] as? String } == ["webPatch"])

        // Idempotent: later edits are not overwritten when the store is constructed again.
        store.setAdditionalRequestBody(
            .init(rawJSON: #"{"top_k":2}"#, sendsWithRequest: false),
            providerID: provider, modelID: "m", conversationID: sending
        )
        let again = GenerationParameterSettingsStore(defaults: defaults)
        #expect(again.additionalRequestBody(
            providerID: provider, modelID: "m", conversationID: sending
        ) == .init(rawJSON: #"{"top_k":2}"#, sendsWithRequest: false))
        #expect(again.additionalRequestBody(providerID: provider, modelID: "m", conversationID: paused) != nil)
    }

    @Test("Device-local: absent from both sync envelopes and the parameter export, and not persisted with request options")
    func localOnly() throws {
        let (store, defaults, suite) = Self.makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = UUID(), conversation = UUID()
        let marker = "zz_local_only_marker_\(UUID().uuidString.prefix(8))"
        store.setAdditionalRequestBody(
            .init(rawJSON: #"{"\#(marker)": "\#(marker)-value"}"#, sendsWithRequest: true),
            providerID: provider, modelID: "m", conversationID: conversation
        )
        // A syncing panel parameter in the same store proves the export really read this store.
        store.setConnectionDefaults(
            .init(values: ["temperature": .init(state: .value, value: .number(0.3))]), providerID: provider
        )

        let generationPayload = GenerationParameterSyncContract.exportPayload(settings: store, defaults: defaults)
        #expect(!generationPayload.records.isEmpty, "the export did not read this store, so the assertions below would be meaningless")
        let generationJSON = String(decoding: try JSONEncoder().encode(generationPayload), as: UTF8.self)
        #expect(!generationJSON.contains(marker))
        let capabilityJSON = String(
            decoding: try JSONEncoder().encode(CapabilityPreferenceSyncContract.exportPayload(settings: store)),
            as: UTF8.self
        )
        #expect(!capabilityJSON.contains(marker))

        // The copy that travels with a request lives in memory only: encoded request options omit it.
        var options = ChatRequestOptions(systemPrompt: "brief")
        options.localAdditionalRequestBody = store.activeAdditionalRequestBody(
            providerID: provider, modelID: "m", conversationID: conversation
        )
        options.localCustomFragmentDisposition = .omitAdditionalBodyForExplicitRetry
        #expect(options.localAdditionalRequestBody != nil)
        let encoded = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
        #expect(!encoded.contains(marker))
        let decoded = try JSONDecoder().decode(ChatRequestOptions.self, from: Data(encoded.utf8))
        #expect(decoded.localAdditionalRequestBody == nil)
        #expect(decoded.localCustomFragmentDisposition == .include)

        // On disk only the device-local key holds it.
        let holders = defaults.dictionaryRepresentation().filter { _, value in
            (value as? Data).map { String(decoding: $0, as: UTF8.self).contains(marker) } ?? "\(value)".contains(marker)
        }.keys.sorted()
        #expect(holders == ["additional_request_body.v1"])
    }

    // MARK: - Copy

    private static let locales = [
        "ar", "de", "en", "es", "fr", "hi", "id", "ja", "ko", "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant",
    ]

    /// Additional-request-body copy ships with the English source and Simplified Chinese first; the
    /// other 14 languages follow once each has been written and reviewed by a native speaker. This
    /// list may only shrink.
    private static let pendingFullLocalization: Set<String> = [
        "Additional request body",
        "Send with requests",
        "Enter a JSON object. Its fields are merged into each request and override parameter settings for the same field.",
        "This JSON is merged into each request.",
        "Saved, but not sent. Turn on “Send with requests” to use it.",
        "Stays on this device. It isn’t synced or included in backups.",
        "The additional request body isn’t valid JSON.",
        "The additional request body must be a JSON object wrapped in { }.",
        "“%@” is filled in by Oriveo and can’t be set in the additional request body.",
        "“%@” can’t be used as a field name in the additional request body.",
        "The additional request body is larger than 64 KB.",
        "The additional request body is nested more than 32 levels deep.",
        "Line %lld: %@",
        "This message wasn’t sent.",
        "Check the additional request body",
        "Request with additional request body was rejected",
        "Retry without additional request body",
    ]

    @Test("Every additional-request-body string has an English source and Simplified Chinese; a key with all 16 languages must leave the pending list")
    func copyHasSourceAndSimplifiedChinese() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try #require(JSONSerialization.jsonObject(with: Data(
            contentsOf: root.appendingPathComponent("Oriveo").appendingPathComponent("Chat.xcstrings")
        )) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])

        // Every key production code uses must be on the list: a new string that was not registered fails here.
        var used: Set<String> = [AdditionalRequestBody.localRejectionTitleKey, AdditionalRequestBody.upstreamRejectionTitleKey]
        for path in [
            ["Oriveo", "Core", "Providers", "AdditionalRequestBody.swift"],
            ["Oriveo", "Features", "Chat", "ModelControls", "CustomRequestFieldsPage.swift"],
        ] {
            let source = try String(contentsOf: path.reduce(root) { $0.appendingPathComponent($1) }, encoding: .utf8)
            var scoped = source
            if path.last == "CustomRequestFieldsPage.swift" {
                // This page also carries copy for the web search and thinking sections; take only
                // the additional-request-body part.
                let section = source.components(separatedBy: "// MARK: - Additional request body").dropFirst().first?
                    .components(separatedBy: "// MARK: - ").first
                scoped = try #require(section)
            }
            let pattern = try NSRegularExpression(pattern: #"L10n\.tr\(\s*"([^"]+)",\s*table: \.chat\s*\)"#)
            for match in pattern.matches(in: scoped, range: NSRange(scoped.startIndex..., in: scoped)) {
                if let range = Range(match.range(at: 1), in: scoped) { used.insert(String(scoped[range])) }
            }
        }
        // These two are the page's existing scope notes. They already have all 16 languages and are not on this list.
        used.subtract([
            "Scope: this conversation, connection, model, and transport.",
            "Scope: this model on this connection, used as the default for its conversations.",
        ])
        // Two more strings live elsewhere: the recovery card's primary button
        // (AssistantMessageRecoveryBuilder) and the closing sentence of the error message
        // (ProviderServiceError.message).
        used.formUnion(["Retry without additional request body", "This message wasn’t sent."])
        #expect(used == Self.pendingFullLocalization, "keys used by production code differ from the pending list: \(used.symmetricDifference(Self.pendingFullLocalization))")

        var problems: [String] = []
        for key in Self.pendingFullLocalization.sorted() {
            let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            for locale in ["en", "zh-Hans"] {
                let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
                guard let value = unit?["value"] as? String, !value.isEmpty else {
                    problems.append("\(key) [\(locale)] has no translation")
                    continue
                }
                if locale == "en", value != key { problems.append("\(key) English source differs from the key") }
                if locale != "en", value == key { problems.append("\(key) [\(locale)] repeats the English source") }
            }
            // Once all 16 languages are present this fails, forcing the key off the list.
            if Self.locales.allSatisfy({ localizations[$0] != nil }) {
                problems.append("\(key) has all 16 languages; remove it from pendingFullLocalization")
            }
        }
        #expect(problems.isEmpty, "\n\(problems.joined(separator: "\n"))")
    }

    // MARK: - Fixtures

    private static func rejection(_ raw: String) -> AdditionalRequestBodyRejection? {
        if case let .failure(rejection) = AdditionalRequestBody.parse(raw) { return rejection }
        return nil
    }

    private static func reason(_ raw: String) -> AdditionalRequestBodyRejection.Reason? {
        rejection(raw)?.reason
    }

    private static func makeStore() -> (GenerationParameterSettingsStore, UserDefaults, String) {
        let suite = "additional-request-body-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (GenerationParameterSettingsStore(defaults: defaults), defaults, suite)
    }
}
