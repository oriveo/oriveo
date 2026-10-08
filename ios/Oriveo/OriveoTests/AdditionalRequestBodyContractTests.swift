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

    /// Every string on the additional request body and advanced settings pages. Each one has been
    /// written in all 16 languages and reviewed by a native speaker. A new string that production
    /// code uses but this list does not name fails the test below.
    private static let moduleCopy: Set<String> = [
        "%1$@ Remove line %2$lld to send.",
        "%@ is on, so this setting isn’t used.",
        "%lld adjusted",
        "%lld entries",
        "%lld fields",
        "Add",
        "Add fields that aren’t listed above, as JSON",
        "Included",
        "Additional request body",
        "Allowed range: %@",
        "Also covers %@",
        "Attachments are filled in by Oriveo.",
        "Can’t be changed",
        "Can’t be sent together with %@, so this setting is left out.",
        "Changed in this conversation",
        "Check the additional request body",
        "Conflicts with another setting, so this one is left out.",
        "Crossed-out settings are being handled by %@.",
        "Depends on another setting that isn’t set, so it isn’t sent.",
        "Discourages repeating whole passages from earlier text",
        "Don’t send this setting",
        "Dynamic temperature",
        "Enter a number. This setting won’t be sent until it’s fixed; your other settings aren’t affected.",
        "Enter a whole number. This setting won’t be sent until it’s fixed; your other settings aren’t affected.",
        "Fields here are added to the request as written; Oriveo doesn’t check whether your server accepts them. If one has the same name as an advanced setting, the one here is used, and your other settings are sent as usual.",
        "Grey numbers are %@’s own defaults. They aren’t sent unless you change them.",
        "Keeps the randomness of the output steady around a target, in place of Top K and Top P.",
        "Learning rate",
        "Line %lld: %@",
        "Model defaults",
        "More sampling",
        "New stop sequence",
        "No limit",
        "Not adjusted",
        "Not set",
        "Off",
        "On",
        "Only sent when %@ is set as well.",
        "Oriveo decides how the reply is streamed.",
        "Paste",
        "Pasting replaces the current content with what’s on the clipboard.",
        "Plain text",
        "Random each time",
        "Remove %@",
        "Repetition",
        "Replace",
        "Replace what’s here?",
        "Request with additional request body was rejected",
        "Reset model defaults",
        "Reset this conversation’s changes",
        "Reset this conversation’s settings?",
        "Reset this model’s defaults?",
        "Retry without additional request body",
        "Saved on this device only, not synced",
        "See which fields %@ supports",
        "Send with requests",
        "Set",
        "Smaller than the reasoning budget, so the default is sent instead.",
        "Sometimes skips the most likely word for more varied wording",
        "Temperature shifts with how confident the model is",
        "The additional request body is larger than 64 KB.",
        "The additional request body is nested more than 32 levels deep.",
        "The additional request body isn’t valid JSON.",
        "The additional request body must be a JSON object wrapped in { }.",
        "The conversation is filled in by Oriveo.",
        "The highest value this model accepts is %@. This setting won’t be sent until it’s fixed; your other settings aren’t affected.",
        "The lowest value this model accepts is %@. This setting won’t be sent until it’s fixed; your other settings aren’t affected.",
        "The model doesn’t accept this while thinking is on, so it isn’t sent.",
        "The model is the one you chose in Oriveo.",
        "The model stops as soon as it writes any one of these. A sequence can contain commas, spaces and line breaks.",
        "The system prompt is filled in by Oriveo.",
        "This clears only the parameters you changed in this conversation. Your model defaults and the additional request body stay as they are.",
        "This clears the default parameters you set for this model on this connection. Changes made inside individual conversations stay as they are.",
        "This conversation only",
        "This field is filled in by Oriveo.",
        "This isn’t a valid JSON Schema. This setting won’t be sent until it’s fixed; your other settings aren’t affected.",
        "This isn’t valid JSON yet, so nothing was changed.",
        "This message wasn’t sent.",
        "This model can write at most %@. This setting won’t be sent until it’s fixed; your other settings aren’t affected.",
        "This model doesn’t accept this value, so this setting isn’t sent.",
        "This model doesn’t accept this value. This setting won’t be sent until it’s fixed; your other settings aren’t affected.",
        "This model requires this field, so the default is still sent.",
        "This must be greater than %@. This setting won’t be sent until it’s fixed; your other settings aren’t affected.",
        "This must be less than %@. This setting won’t be sent until it’s fixed; your other settings aren’t affected.",
        "This name can’t be used as a field name.",
        "Target entropy",
        "Tidy up",
        "Tools are managed by Oriveo.",
        "Use model default",
        "Using the model default you set",
        "Web search and thinking fields",
        "When off, the content is kept but not sent",
        "When sending",
        "Write your own",
        "Your default",
        "“%@” can’t be used as a field name in the additional request body.",
        "“%@” is filled in by Oriveo and can’t be set in the additional request body.",
    ]

    /// Strings from `moduleCopy` that only have the English source and Simplified Chinese so far.
    /// Empty today; it may only shrink. Anything not listed here must have all 16 languages.
    private static let pendingFullLocalization: Set<String> = []

    /// Words used on the same pages that already have all 16 languages; they are not part of this module's list.
    private static let alreadyFullyLocalized: Set<String> = [
        "More",
        "Output",
    ]

    /// New copy on the provider detail page (the Providers table), held to the same rule.
    private static let providersCopy: Set<String> = [
        "Apply preset",
        "Apply this preset?",
        "“%1$@” replaces everything you’ve set for this model: %2$@.",
    ]
    private static let pendingProvidersLocalization: Set<String> = []

    @Test("Every additional-request-body string has an English source and Simplified Chinese; anything off the pending list has all 16 languages")
    func copyHasSourceAndSimplifiedChinese() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try #require(JSONSerialization.jsonObject(with: Data(
            contentsOf: root.appendingPathComponent("Oriveo").appendingPathComponent("Chat.xcstrings")
        )) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])

        // Every key production code uses must be on the list: a new string that was not registered fails here.
        var used: Set<String> = [AdditionalRequestBody.localRejectionTitleKey, AdditionalRequestBody.upstreamRejectionTitleKey]
        // The additional request body and advanced settings pages: the editor, the per-field list, rows
        // and groups, and the entry to them on the provider detail page.
        let modelControls = ["Oriveo", "Features", "Chat", "ModelControls"]
        for path in [
            ["Oriveo", "Core", "Providers", "AdditionalRequestBody.swift"],
            modelControls + ["AdditionalRequestBodyPage.swift"],
            modelControls + ["AdditionalRequestBodyInspector.swift"],
            modelControls + ["AdvancedSettingsModel.swift"],
            modelControls + ["AdvancedParameterRowView.swift"],
            modelControls + ["AdvancedSettingsPage.swift"],
            ["Oriveo", "Features", "Providers", "GenerationParameterDefaultsSheet.swift"],
        ] {
            let source = try String(contentsOf: path.reduce(root) { $0.appendingPathComponent($1) }, encoding: .utf8)
            // The second form covers validation copy that carries a number: `bound("…%@…", value)`.
            for expression in [#"L10n\.tr\(\s*"([^"]+)",\s*table: \.chat\s*\)"#, #"bound\(\s*"([^"]+)""#] {
                let pattern = try NSRegularExpression(pattern: expression)
                for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                    if let range = Range(match.range(at: 1), in: source) { used.insert(String(source[range])) }
                }
            }
        }
        used.subtract(Self.alreadyFullyLocalized)
        // Two more strings live elsewhere: the recovery card's primary button
        // (AssistantMessageRecoveryBuilder) and the closing sentence of the error message
        // (ProviderServiceError.message).
        used.formUnion(["Retry without additional request body", "This message wasn’t sent."])
        #expect(used == Self.moduleCopy, "keys used by production code differ from the module list: \(used.symmetricDifference(Self.moduleCopy))")
        #expect(Self.pendingFullLocalization.isSubset(of: Self.moduleCopy))
        #expect(Self.pendingProvidersLocalization.isSubset(of: Self.providersCopy))

        var problems: [String] = []
        for key in Self.moduleCopy.sorted() {
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
            problems += Self.completenessProblems(
                key: key, localizations: localizations, pending: Self.pendingFullLocalization.contains(key)
            )
        }
        let providers = try #require(JSONSerialization.jsonObject(with: Data(
            contentsOf: root.appendingPathComponent("Oriveo").appendingPathComponent("Providers.xcstrings")
        )) as? [String: Any])
        let providerStrings = try #require(providers["strings"] as? [String: Any])
        for key in Self.providersCopy.sorted() {
            let localizations = (providerStrings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            for locale in ["en", "zh-Hans"] {
                let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
                guard let value = unit?["value"] as? String, !value.isEmpty else {
                    problems.append("\(key) [Providers.\(locale)] has no translation")
                    continue
                }
                if locale == "en", value != key { problems.append("\(key) English source differs from the key") }
            }
            problems += Self.completenessProblems(
                key: key, localizations: localizations, pending: Self.pendingProvidersLocalization.contains(key)
            )
        }
        let zhTerm = ((strings["Additional request body"] as? [String: Any])?["localizations"] as? [String: Any])?["zh-Hans"]
        #expect(((zhTerm as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String == "\u{9644}\u{52A0}\u{8BF7}\u{6C42}\u{4F53}")
        #expect(problems.isEmpty, "\n\(problems.joined(separator: "\n"))")
    }

    /// Both sides of the unlock rule: a pending string with all 16 languages must leave the pending
    /// list, and a string off the list that misses any language fails.
    private static func completenessProblems(key: String, localizations: [String: Any], pending: Bool) -> [String] {
        let missing = locales.filter { locale in
            let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
            return ((unit?["value"] as? String) ?? "").isEmpty
        }
        if pending { return missing.isEmpty ? ["\(key) has all 16 languages; remove it from the pending list"] : [] }
        return missing.isEmpty ? [] : ["\(key) is missing \(missing.joined(separator: ", "))"]
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
