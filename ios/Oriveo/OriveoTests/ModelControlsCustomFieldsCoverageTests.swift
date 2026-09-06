import Foundation
import Testing
@testable import Oriveo

/// Coverage regression for **Custom request fields**.
///
/// Only three provider-and-transport pairs publish a custom schema, so the other forty-two
/// combinations are the case almost every user meets. Asserting the three that work says
/// nothing about the forty-two that must show an empty state instead of an entry that opens a
/// pane which can change nothing.
///
/// This suite therefore asserts the empty state, and keeps the schema-bearing pairs only as a
/// control, so the predicate cannot pass by being hard-coded to always-false.
@Suite("Custom request fields coverage", .serialized)
struct ModelControlsCustomFieldsCoverageTests {
    /// The fifteen-provider BYOK matrix. Relay has its own branch and is tested separately.
    private static let byokKinds: [ProviderKind] = [
        .openAI, .anthropic, .gemini, .openRouter, .deepseek, .grok, .groq, .together,
        .fireworks, .miniMax, .zhipu, .qwen, .moonshot, .mistral, .siliconFlow,
    ]
    private static let owners = ["web", "reasoning", "generation"]

    /// The complete set of custom controls the catalog currently publishes. This table is
    /// deliberately handwritten: it has to go red when a new control appears so someone looks at the
    /// client, rather than silently growing an untested entry.
    private static let declared: [(kind: ProviderKind, transport: String, owner: String, ref: String)] = [
        (.openAI, "openai_responses", "reasoning", "openai.reasoning.effort"),
        (.openAI, "openai_responses", "generation", "openai.generation.max_output_tokens"),
        (.qwen, "openai_chat", "web", "qwen.web.enable_search"),
    ]

    // MARK: - Empty state (the shape of this bug)

    @Test(
        "No declared schema means no custom fields entry, for every BYOK provider and owner",
        arguments: byokKinds
    )
    func emptyScheduleHasNoCustomFields(kind: ProviderKind) async throws {
        let modelID = "\(kind.rawValue)-coverage"
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.metadata(
            providerKind: kind, modelID: modelID, transport: "openai_chat", customControlRefs: [:]
        ))
        // Cleanup is the **entry side's** job (each case above resets then loads on the way in).
        // No defer here: `defer { Task { … } }` has an unpredictable hop and can wipe the
        // process-wide snapshot after a later case has already loaded its fixture, producing
        // "green in isolation, flaky red in the full suite" (TestIsolationGuardTests watches this).

        for owner in Self.owners {
            #expect(
                CapabilityRecipeExecution.hasSafeCustomSchema(
                    owner: owner, providerKind: kind, modelID: modelID, transport: "openai_chat"
                ) == false,
                "\(kind.rawValue)/\(owner) has no customControlRefs but reported an editable schema"
            )
            // Risk copy shares the same source: no control means no cost/privacy tier, otherwise we scare the user for free.
            #expect(
                CapabilityRecipeExecution.customControlRiskTiers(
                    owner: owner, providerKind: kind, modelID: modelID, transport: "openai_chat"
                ).isEmpty,
                "\(kind.rawValue)/\(owner) has no control but produced a riskTier"
            )
        }
    }

    /// Of 45 (provider × owner) pairs, only 3 are non-empty. This assert pins that ratio:
    /// if it changes, the catalog changed its control table and the client UI must be re-reviewed.
    @Test("Exactly three of the 45 BYOK provider-owner pairs declare a custom schema")
    func declaredCoverageStaysThree() async throws {
        var found: [String] = []
        for kind in Self.byokKinds {
            let modelID = "\(kind.rawValue)-coverage"
            for owner in Self.owners {
                let match = Self.declared.first { $0.kind == kind && $0.owner == owner }
                await MetadataClient.shared.resetForTesting()
                try await MetadataClient.shared.loadForTesting(json: Self.metadata(
                    providerKind: kind, modelID: modelID,
                    transport: match?.transport ?? "openai_chat",
                    customControlRefs: match.map { [$0.owner: [$0.ref]] } ?? [:]
                ))
                if CapabilityRecipeExecution.hasSafeCustomSchema(
                    owner: owner, providerKind: kind, modelID: modelID,
                    transport: match?.transport ?? "openai_chat"
                ) {
                    found.append("\(kind.rawValue)/\(owner)")
                }
            }
        }
        await MetadataClient.shared.resetForTesting()
        #expect(found.sorted() == [
            "openAI/generation", "openAI/reasoning", "qwen/web",
        ], "custom-fields coverage changed: \(found.sorted())")
    }

    /// Mounted refs still do not mean allow: **transport drift between the catalog and
    /// the final route must fail-closed**.
    ///
    /// The client does not check "does this control belong to this transport" at this layer,
    /// because the published control table is itself indexed by transport. The client owns the
    /// other half: local metadata is cached for up to 24 hours, during which the catalog transport may
    /// have changed while refs were still issued for the old route. Allowing the edit
    /// then lets the user write JSON on a route that does not accept the field, and
    /// every message is rejected by the final compiler.
    @Test("Transport drift between the catalog and the final route fails closed")
    func transportDriftHasNoCustomFields() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.metadata(
            providerKind: .openAI, modelID: "openai-transport-drift", transport: "openai_responses",
            customControlRefs: ["reasoning": ["openai.reasoning.effort"]]
        ))
        // Catalog says Responses, but this request finally lands on Chat Completions.
        #expect(CapabilityRecipeExecution.hasSafeCustomSchema(
            owner: "reasoning", providerKind: .openAI, modelID: "openai-transport-drift",
            transport: "openai_chat"
        ) == false)
        // Empty transport (final route could not be resolved) is equally not a guess.
        #expect(CapabilityRecipeExecution.hasSafeCustomSchema(
            owner: "reasoning", providerKind: .openAI, modelID: "openai-transport-drift",
            transport: ""
        ) == false)
        await MetadataClient.shared.resetForTesting()
    }

    /// Control group: the 3 non-empty pairs must be true. Without this, hard-coding the predicate to `false` would still make everything above green.
    @Test("The three declared pairs really do resolve to an editable schema")
    func declaredPairsResolve() async throws {
        for entry in Self.declared {
            let modelID = "\(entry.kind.rawValue)-declared"
            await MetadataClient.shared.resetForTesting()
            try await MetadataClient.shared.loadForTesting(json: Self.metadata(
                providerKind: entry.kind, modelID: modelID, transport: entry.transport,
                customControlRefs: [entry.owner: [entry.ref]]
            ))
            #expect(
                CapabilityRecipeExecution.hasSafeCustomSchema(
                    owner: entry.owner, providerKind: entry.kind, modelID: modelID,
                    transport: entry.transport
                ),
                "\(entry.kind.rawValue)/\(entry.owner) should have an editable schema"
            )
            // The other two owners on the same model stay empty — mounting is per-owner, not per-provider.
            for other in Self.owners where other != entry.owner {
                let alsoDeclared = Self.declared.contains {
                    $0.kind == entry.kind && $0.owner == other && $0.transport == entry.transport
                }
                guard !alsoDeclared else { continue }
                #expect(
                    CapabilityRecipeExecution.hasSafeCustomSchema(
                        owner: other, providerKind: entry.kind, modelID: modelID,
                        transport: entry.transport
                    ) == false,
                    "\(entry.kind.rawValue)/\(other) must not be allowed just because a sibling was"
                )
            }
        }
        await MetadataClient.shared.resetForTesting()
    }

    // MARK: - UI "in use" must equal outbound truth

    /// There is no developer master gate: whether custom fields go out depends only on
    /// `mode == .custom`, and the entry lives in one place, Advanced Settings → Developer →
    /// Custom request fields.
    ///
    /// This pins the UI predicate to the outbound condition itself rather than to the wording
    /// of any one line: "In use / Not in use" can only come from `mode == .custom`, the same
    /// predicate the wire uses.
    @Test("The stored custom mode alone decides both the outbound fragment and the entry state")
    func customModeAloneDrivesTheOutbound() throws {
        let suiteName = "custom-fields-entry-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let providerID = UUID()

        store.setLocalCustomConfiguration(
            .init(mode: .custom, rawJSON: "{\"reasoning\":{\"effort\":\"low\"}}"),
            providerID: providerID, modelID: "gate-model", conversationID: nil,
            transportIdentity: "openai_responses", namespace: "reasoningPatch"
        )
        #expect(store.activeLocalCustomFragments(
            providerID: providerID, modelID: "gate-model", conversationID: nil,
            transportIdentity: "openai_responses"
        ).contains { $0.owner == "reasoning" }, "custom must go outbound unconditionally")

        // Clearing content = disable (the new editor's only write semantics); outbound stops, the draft stays.
        store.setLocalCustomConfiguration(
            .init(mode: .automatic, rawJSON: "{\"reasoning\":{\"effort\":\"low\"}}"),
            providerID: providerID, modelID: "gate-model", conversationID: nil,
            transportIdentity: "openai_responses", namespace: "reasoningPatch"
        )
        #expect(store.activeLocalCustomFragments(
            providerID: providerID, modelID: "gate-model", conversationID: nil,
            transportIdentity: "openai_responses"
        ).isEmpty)
        #expect(store.localCustomConfiguration(
            providerID: providerID, modelID: "gate-model", conversationID: nil,
            transportIdentity: "openai_responses", namespace: "reasoningPatch"
        ).rawJSON.isEmpty == false, "disable must not also delete the draft")

        // Entry side is the same source: state comes from `mode == .custom`, and the repo no longer has a master gate to read.
        let page = try Self.advancedSettingsSource()
        #expect(page.contains("if configuration.mode == .custom { inUse = true; reachable = true }"))
        #expect(!page.contains("isLocalCustomDeveloperModeEnabled"))
    }

    /// The entry row is **always present**: when unsupported it degrades to
    /// status text + tap-for-reason, rather than vanishing. A feature row that
    /// disappears with the model reads as "broken", not "this model does not support it".
    @Test("The custom fields row never disappears and always answers a tap")
    func customFieldsRowIsAlwaysPresentAndTappable() throws {
        let page = try Self.advancedSettingsSource()
        #expect(page.contains("L10n.tr(\"Developer\", table: .providers)"))
        // All three states must exist; missing one means the row cannot name its own state in some case.
        #expect(page.contains("L10n.tr(\"Not supported by this model\", table: .chat)"))
        #expect(page.contains("L10n.tr(\"Not in use\", table: .providers)"))
        #expect(page.contains("L10n.tr(\"In use\", table: .providers)"))
        // The unsupported state must answer a tap (alert with the reason) and must not draw a chevron that promises navigation.
        #expect(page.contains("showsCustomFieldsUnsupportedAlert = true"))
        #expect(page.contains(
            "Custom request fields are only available on models whose provider officially declares a field schema."
        ))
        // Each of the two presentations has an entry: sheet (provider detail) uses a Section, embedded (chat page) uses a card.
        #expect(page.contains("Section(L10n.tr(\"Developer\", table: .providers))"))
        #expect(page.contains("private var embeddedDeveloperCard"))
        #expect(page.contains("CustomRequestFieldsPage("))
    }

    /// The developer group **does not vanish in read-only**.
    ///
    /// Read-only means "cannot change it now", not "this feature does not exist".
    /// Wrapping the whole group in `if !isReadOnly` makes a managed-connection or
    /// in-flight user see "custom request fields disappeared" — while its status
    /// (Not in use / In use) is exactly the fact that should remain visible in
    /// read-only. Read-only degrades to a status line that cannot push.
    @Test("The developer group survives read-only and degrades to a status line")
    func developerGroupSurvivesReadOnly() throws {
        let page = try Self.advancedSettingsSource()
        for gone in [
            "if !isReadOnly {\n                    Section(L10n.tr(\"Developer\", table: .providers))",
            "if !isReadOnly {\n                    embeddedDeveloperCard",
        ] {
            #expect(!page.contains(gone), "the developer group vanished wholesale again under read-only")
        }
        // Each of the two presentations has a read-only branch, and read-only does not attach navigation or draw a chevron.
        #expect(page.contains("if isReadOnly {\n                        customFieldsRowLabel"))
        #expect(page.contains("if isReadOnly {\n                customFieldsRowLabel"))
    }

    /// F10: the "Not supported by this model" alert must offer a way out, or say there is none.
    /// Stating the reason without an action leaves the user stuck — the other half of rule 1.
    @Test("The unsupported alert offers a way out, or says there is none")
    func unsupportedAlertOffersAWayOut() throws {
        let page = try Self.advancedSettingsSource()
        #expect(page.contains("private var customFieldsSupportedModelCandidates: [AIModel]"))
        #expect(page.contains("if !customFieldsSupportedModelCandidates.isEmpty {"))
        #expect(page.contains("L10n.tr(\"View supported models\", table: .chat)"))
        #expect(page.contains("CapabilitySupportedModelsPage("))
        // When there are no candidates, "switching models will not help" goes in the body; do not send the user into an empty list.
        #expect(page.contains("L10n.tr(\n            \"No models in this connection support this capability yet.\", table: .chat\n        )"))
        // This page's title follows the row the user tapped, not "Advanced settings".
        #expect(page.contains("title: L10n.tr(\"Custom request fields\", table: .chat)"))
    }

    /// Scope copy and the delete confirmation split into two sentences by `conversationID`.
    /// Editing from provider detail is the **model default**; there is no conversation there, so saying "this conversation" would be a lie.
    @Test("Scope copy and the delete confirmation follow the entry point")
    func scopeCopyFollowsTheEntryPoint() throws {
        let editor = try String(
            contentsOf: Self.findFile([
                "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
                "CustomRequestFieldsPage.swift",
            ]),
            encoding: .utf8
        )
        #expect(editor.contains("Scope: this conversation, connection, model, and transport."))
        #expect(editor.contains("Scope: this model on this connection, used as the default for its conversations."))
        #expect(editor.contains("This removes the custom fields for %@ on this conversation, connection, model and transport. This cannot be undone."))
        #expect(editor.contains("This removes the custom fields for %@ on this connection, model and transport. This cannot be undone."))
        #expect(editor.components(separatedBy: "conversationID != nil").count >= 3, "both copy sites must branch on the entry point")
    }

    // MARK: - Custom-fields forward-port across recipe versions

    /// Typed preferences are a closed vocabulary and can be copied as-is; custom
    /// JSON is **user-written fields** that may already be illegal under the new
    /// recipe, so forward-port must re-validate against the new recipe.
    ///
    /// On failure the landing is "pause + keep the draft" (`mode = .automatic`,
    /// `rawJSON` unchanged): staying custom would fail-closed so the next message
    /// suddenly cannot send even though the user changed nothing; dropping the
    /// draft is deciding for them — that may be thirty lines of JSON they spent
    /// a long time tuning.
    @Test("a custom fragment forward-ports only if the new recipe still accepts it")
    func customFragmentForwardPortRevalidatesAgainstTheNewRecipe() async throws {
        let modelID = "openai-forward-port"
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.metadata(
            providerKind: .openAI, modelID: modelID, transport: "openai_responses",
            customControlRefs: ["reasoning": ["openai.reasoning.effort"]]
        ))

        let suiteName = "custom-forward-port-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let context = CapabilityLocalCustomForwardPortContext(
            providerKind: .openAI, schemaModelID: modelID
        )
        let old = Self.identity(transport: "openai_responses", revision: "runtime-r7")
        let new = Self.identity(transport: "openai_responses", revision: "runtime-r8")

        // ① The new recipe still accepts this JSON → forward-port as-is and keep sending.
        let legal = UUID()
        store.setLocalCustomConfiguration(
            .init(mode: .custom, rawJSON: "{\"reasoning\":{\"effort\":\"low\"}}"),
            providerID: legal, modelID: "canonical", conversationID: nil,
            transportIdentity: old, namespace: "reasoningPatch"
        )
        let migrated = store.effectiveLocalCustomConfiguration(
            providerID: legal, modelID: "canonical", conversationID: nil,
            transportIdentity: new, namespace: "reasoningPatch", forwardPort: context
        )
        #expect(migrated.mode == .custom, "a field the new recipe still accepts was disabled by mistake")
        #expect(migrated.rawJSON.contains("effort"))
        #expect(store.activeLocalCustomFragments(
            providerID: legal, modelID: "canonical", conversationID: nil,
            transportIdentity: new, forwardPort: context
        ).contains { $0.owner == "reasoning" }, "legal forward-port did not go outbound")

        // ② The new recipe no longer accepts it → pause but keep the draft. fail-closed would make the next message fail to send for no obvious reason.
        let illegal = UUID()
        store.setLocalCustomConfiguration(
            .init(mode: .custom, rawJSON: "{\"bogus\":1}"),
            providerID: illegal, modelID: "canonical", conversationID: nil,
            transportIdentity: old, namespace: "reasoningPatch"
        )
        let paused = store.effectiveLocalCustomConfiguration(
            providerID: illegal, modelID: "canonical", conversationID: nil,
            transportIdentity: new, namespace: "reasoningPatch", forwardPort: context
        )
        #expect(paused.mode == .automatic, "a field the new recipe no longer accepts is still going outbound — messages will fail to send")
        #expect(paused.rawJSON == "{\"bogus\":1}", "the draft was discarded, leaving the user nothing to edit")
        #expect(store.activeLocalCustomFragments(
            providerID: illegal, modelID: "canonical", conversationID: nil,
            transportIdentity: new, forwardPort: context
        ).isEmpty)

        // ③ Idempotent: a second read does not change the conclusion, and does not re-enable the paused entry.
        #expect(store.effectiveLocalCustomConfiguration(
            providerID: illegal, modelID: "canonical", conversationID: nil,
            transportIdentity: new, namespace: "reasoningPatch", forwardPort: context
        ).mode == .automatic)

        // ④ Omitting `forwardPort` is a pure read: no forward-port, no rewrite (pure-storage unit tests stay stable on this).
        let untouched = UUID()
        store.setLocalCustomConfiguration(
            .init(mode: .custom, rawJSON: "{\"reasoning\":{\"effort\":\"low\"}}"),
            providerID: untouched, modelID: "canonical", conversationID: nil,
            transportIdentity: old, namespace: "reasoningPatch"
        )
        #expect(store.effectiveLocalCustomConfiguration(
            providerID: untouched, modelID: "canonical", conversationID: nil,
            transportIdentity: new, namespace: "reasoningPatch"
        ).mode == .automatic)
        #expect(store.effectiveLocalCustomConfiguration(
            providerID: untouched, modelID: "canonical", conversationID: nil,
            transportIdentity: new, namespace: "reasoningPatch"
        ).rawJSON.isEmpty)

        // ⑤ Changing protocol does not migrate: that is a different request contract, and moving the JSON would be guessing for the user.
        let otherProtocol = Self.identity(transport: "openai_chat", revision: "runtime-r8")
        #expect(store.effectiveLocalCustomConfiguration(
            providerID: legal, modelID: "canonical", conversationID: nil,
            transportIdentity: otherProtocol, namespace: "reasoningPatch", forwardPort: context
        ).mode == .automatic)

        await MetadataClient.shared.resetForTesting()
    }

    /// Every production read point must pass `forwardPort`, otherwise forward-port
    /// only happens at some entries: the panel says "In use" while the request has
    /// no such field — the "each site reads its own" shape back in a different coat.
    @Test("every production read point opts into the forward port")
    func everyProductionReadPointForwardPorts() throws {
        for components in [
            ["ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
             "ModelControlsSheet.swift"],
            ["ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
             "CustomRequestFieldsPage.swift"],
            ["ios", "Oriveo", "Oriveo", "Features", "Providers",
             "GenerationParameterDefaultsSheet.swift"],
            ["ios", "Oriveo", "Oriveo", "Core", "Providers",
             "CapabilityControlResolution.swift"],
            ["ios", "Oriveo", "Oriveo", "Core", "State", "ChatManager.swift"],
        ] {
            let source = try String(contentsOf: Self.findFile(components), encoding: .utf8)
            #expect(
                source.contains("forwardPort:"),
                "\(components.last!) custom-fields read is not wired to the forward port"
            )
        }
        // Forward-port is triggered by discrete events and **must not hang off `body`**:
        // ChatView would decode UserDefaults on every recompute, which is the same class
        // of problem as "thinking page at 99% CPU". Forward-port is idempotent; once on
        // the composer path and once on the send path is enough.
        let composer = try String(
            contentsOf: Self.findFile([
                "ios", "Oriveo", "Oriveo", "Features", "Chat", "ChatComposerBar.swift",
            ]),
            encoding: .utf8
        )
        let chatView = try String(
            contentsOf: Self.findFile([
                "ios", "Oriveo", "Oriveo", "Features", "Chat", "ChatView.swift",
            ]),
            encoding: .utf8
        )
        #expect(composer.contains("forwardPortsStaleCustom: true"))
        #expect(
            !chatView.contains("forwardPortsStaleCustom"),
            "ChatView body is running forward-port — an extra UserDefaults decode per frame"
        )
    }

    private static func identity(transport: String, revision: String) -> String {
        CapabilityPreferenceRuntimeIdentity(
            canonicalModelID: "", finalTransport: transport, runtimeRevision: revision
        ).wireValue
    }

    private static func advancedSettingsSource() throws -> String {
        try String(
            contentsOf: findFile([
                "ios", "Oriveo", "Oriveo", "Features", "Providers",
                "GenerationParameterDefaultsSheet.swift",
            ]),
            encoding: .utf8
        )
    }

    // MARK: - transport source must not fall back to v1 profiles

    /// `finalTransport` is the only transport predicate for custom fields and risk
    /// copy; authority must be the v2 catalog. It previously came from v1
    /// `profiles.*` — the day G05 closed the compat window, iOS risk copy and
    /// official-doc links would silently vanish, while Web was unharmed (it only
    /// reads v2 controlDefinitions). This pins the source to v2.
    @Test("Final transport comes from the v2 catalog, not the legacy profile projection")
    func finalTransportUsesV2Catalog() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.metadata(
            providerKind: .openAI, modelID: "openai-transport", transport: "openai_responses",
            customControlRefs: ["reasoning": ["openai.reasoning.effort"]], includeLegacyProfiles: false
        ))
        let provider = Self.provider(kind: .openAI, modelID: "openai-transport")
        let model = try #require(provider.models.first)
        #expect(CapabilityRecipeExecution.finalTransport(
            owner: "reasoning", provider: provider, model: model
        ) == "openai_responses")
        #expect(CapabilityRecipeExecution.displayTransport(
            provider: provider, model: model
        ) == "openai_responses")
        await MetadataClient.shared.resetForTesting()
    }

    // MARK: - Fixtures

    private static func provider(kind: ProviderKind, modelID: String) -> Provider {
        TestFactories.makeProvider(
            kind: kind, models: [TestFactories.makeModel(id: modelID)]
        )
    }

    /// Build only the **wire the client actually consumes**: the model's
    /// `capabilityControls` and `capabilityRuntime`. `controlDefinitions` /
    /// `sourceIndex` come from Server's authoritative JSON, not a rewrite in the
    /// test — synthesizing a definition and then proving we parse it only tests the test.
    private static func metadata(
        providerKind: ProviderKind, modelID: String, transport: String,
        customControlRefs: [String: [String]], includeLegacyProfiles: Bool = true
    ) throws -> String {
        let definitions = try JSONSerialization.jsonObject(
            with: Data(contentsOf: findFile([
                "shared", "capabilityrecipe",
                "capability_custom_controls.v2.json",
            ]))
        ) as? [String: Any] ?? [:]
        let registry = try JSONSerialization.jsonObject(
            with: Data(contentsOf: findFile([
                "shared", "capabilityrecipe",
                "capability_runtime.v1.json",
            ]))
        ) as? [String: Any] ?? [:]

        var controls: [String: Any] = [:]
        for owner in owners {
            var control: [String: Any] = ["state": "auto_available"]
            if let refs = customControlRefs[owner], !refs.isEmpty { control["customControlRefs"] = refs }
            if owner == "reasoning" { control["availableIntents"] = ["low", "balanced", "deep"] }
            controls[owner] = control
        }

        var modelEntry: [String: Any] = [
            "canonicalModelId": modelID, "transport": transport, "capabilityControls": controls,
        ]
        // v1 profiles projection: included by default (close to production), but
        // transport is deliberately a different line — if the predicate falls back
        // to the legacy profile, `finalTransportUsesV2Catalog` goes red immediately.
        if includeLegacyProfiles {
            modelEntry["profiles"] = ["generation": [
                "template": "legacy_only", "revision": "coverage",
                "parameters": [["id": "max_output_tokens", "support": "supported",
                                "source": "authoritative_metadata"]],
            ]]
        }

        let document: [String: Any] = [
            "version": 1,
            "profiles": ["generation": [
                "version": 1,
                "parameters": ["max_output_tokens": [
                    "id": "max_output_tokens", "type": "number", "min": 1, "max": 128000,
                    "support": "supported", "source": "authoritative_metadata",
                ]],
                "templates": ["legacy_only": [
                    "transport": "legacy_only", "wire": ["max_output_tokens": "max_output_tokens"],
                ]],
            ]],
            "providers": [providerKind.rawValue: [
                "resolveMap": [modelID: modelID],
                "models": [modelID: modelEntry],
            ]],
            "capabilityRuntime": [
                "schemaVersion": 2, "revision": "custom-fields-coverage",
                "generatedAt": "2026-08-13T00:00:00Z",
                "recipes": registry["recipes"] ?? [:],
                "controlDefinitions": definitions,
                "sourceIndex": registry["sourceIndex"] ?? [:],
                "responseEvidenceDefinitions": registry["responseEvidenceDefinitions"] ?? [:],
                "errorRecoveryDefinitions": registry["errorRecoveryDefinitions"] ?? [:],
            ],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
    }

    private static func findFile(_ components: [String]) -> URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while current.path != current.deletingLastPathComponent().path {
            let candidate = components.reduce(current) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            current = current.deletingLastPathComponent()
        }
        fatalError("fixture not found: \(components.joined(separator: "/"))")
    }
}
