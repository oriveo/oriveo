import Foundation
import Testing
@testable import Oriveo

/// **Structural** rules of the model options panel: no grayed-out options, pure functions decide what is drawn, the height follows the content,
/// second-level pages are pushed instead of opening another modal, and opening the panel stores no value for the user.
///
/// These are source assertions rather than render assertions because each of them is a "this must
/// not exist" property. A SwiftUI `body` is an opaque type, so the render side cannot answer
/// If one of these regresses, every logic test stays green. Properties that can be asserted against a function are not here:
/// shapes are in `ModelOptionCapabilityShapeTests`, the page model in `ModelOptionsPanelModelTests`.
@Suite("Model Controls Panel Structure Tests")
struct ModelControlsPanelStructureTests {
    private static let modelControls = [
        "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
    ]

    /// The source of the panel view: from `struct ModelOptionsPanel` up to the route enum.
    private static func panelViewSource() throws -> String {
        let sheet = try source(modelControls + ["ModelControlsSheet.swift"])
        let start = try #require(sheet.range(of: "struct ModelOptionsPanel: View {"))
        let end = try #require(sheet.range(of: "// MARK: - Route", range: start.upperBound..<sheet.endIndex))
        return String(sheet[start.lowerBound..<end.lowerBound])
    }

    @Test("Composer Entry Remains Reachable Without Runtime Identity")
    func composerEntryRemainsReachableWithoutRuntimeIdentity() throws {
        let composer = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ChatComposerBar.swift",
        ])
        #expect(!composer.contains("if let currentModel {"))
        #expect(!composer.contains("if let currentModel, let transportIdentity = modelControlTransportIdentity"))
        #expect(composer.contains("ModelControlsEntrySheet("))
        #expect(composer.contains("model: currentModel"))
        #expect(composer.contains("transportIdentity: modelControlTransportIdentity"))
        #expect(composer.contains("runtimeIsReadOnly: controlsDisabled"))
        let entry = try #require(composer.range(of: "Button { showsModelControls = true }"))
        let sheet = try #require(composer.range(of: ".sheet(isPresented: $showsModelControls,", range: entry.lowerBound..<composer.endIndex))
        let entrySource = String(composer[entry.lowerBound..<sheet.lowerBound])
        #expect(entrySource.contains("disabled: false"))
        #expect(!entrySource.contains(".disabled("), "controlsDisabled while generating locked away the only entry point that explains the state")
    }

    @Test("Editability Consumes Production Projection")
    func editabilityConsumesProductionProjection() {
        #expect(ModelControlsEditability.resolve(providerKind: .openAI, transportIdentity: "runtime", runtimeIsReadOnly: false) == .writable)
        #expect(ModelControlsEditability.resolve(providerKind: .relay, transportIdentity: nil, runtimeIsReadOnly: true) == .runtimeIdentityUnavailable)
        #expect(ModelControlsEditability.resolve(providerKind: .openAI, transportIdentity: "runtime", runtimeIsReadOnly: true) == .runtimeReadOnly)
        #expect(!ModelControlsEditability.runtimeIdentityUnavailable.canPersist)
        #expect(!ModelControlsEditability.runtimeReadOnly.canPersist)
    }

    // MARK: - Pure functions decide what is drawn

    @Test("the capability card is drawn case by case from the shape, and the panel view holds no business criterion")
    func panelViewOnlyDrawsTheModel() throws {
        let panel = try Self.panelViewSource()
        for pattern in [
            "case let .toggle(toggle):", "case let .tiers(tiers):",
            "case let .toggleWithTiming(toggle, timing):", "case let .notice(notice):",
            "case let .disclosure(disclosure):",
            "case let .protocolUndecided(callout):", "case let .callout(callout):",
        ] {
            #expect(panel.contains(pattern), "the panel does not draw this shape: \(pattern)")
        }
        // The view reads no storage, looks up no configuration and does not look at who the connection is: once any of that appears, a business decision is back in the view.
        for forbidden in [
            "MetadataClient", "GenerationParameterSettingsStore", "CapabilityControlResolution",
            "CapabilityControlPresentation", "UnsupportedParamCache", "provider.", "editability",
            "appState",
        ] {
            #expect(!panel.contains(forbidden), "the panel view contains \(forbidden)")
        }
        // No grayed-out options: the only `.disabled` in the panel is the button while a refetch is running.
        #expect(panel.components(separatedBy: ".disabled(").count == 2)
        #expect(panel.contains(".disabled(banner.isBusy)"))
    }

    @Test("the main panel's order is fixed: header, capabilities, parameters")
    func mainPanelOrderIsFrozen() throws {
        let panel = try Self.panelViewSource()
        let body = try #require(panel.range(of: "var body: some View {"))
        let rest = panel[body.upperBound...]
        let header = try #require(rest.range(of: "header"))
        let capability = try #require(rest.range(of: "capabilityCard", range: header.upperBound..<rest.endIndex))
        let advanced = try #require(rest.range(of: "advancedCard", range: capability.upperBound..<rest.endIndex))
        #expect(header.lowerBound < capability.lowerBound && capability.lowerBound < advanced.lowerBound)
        // The header is the model name itself; "Model options" is not written again.
        #expect(panel.contains("Text(model.title)"))
        #expect(!panel.contains("L10n.tr(\"Model Options\")"))
    }

    @Test("Read Only Summary Offers A Recovery Action")
    func readOnlyBannerOffersARecoveryAction() throws {
        let sheet = try Self.source(Self.modelControls + ["ModelControlsSheet.swift"])
        // This only guarantees that the wiring "every action is connected to the thing that changes the state" has not been removed.
        // Which reason gets which action is covered by identityGapSeparatesEachCause / identityGapActionsAreDistinct.
        #expect(sheet.contains("case .banner(.refetch):\n            Task { await refreshRuntime() }"))
        #expect(sheet.contains("await MetadataClient.shared.forceRefresh(providerKinds: [provider.kind])"))
        #expect(sheet.contains("case .banner(.chooseAnotherModel):\n            onChooseConnection()"))
        #expect(sheet.contains("Choose another model"))
        // Still missing after fetching is a real failure and has to be said.
        #expect(sheet.contains("Still no luck. Check your network and try again."))

        // "Choose protocol" does not push `ProviderDetailView` inside the panel: that page's back button calls `appState.pop()`,
        // which pops the root stack **behind** the sheet. The panel sets a flag and dismisses, and the composer routes through appState in onDismiss.
        #expect(
            !sheet.contains("ProviderDetailView(providerID: provider.id)"),
            "the panel pushes the provider detail screen inside the sheet again; its back button pops the stack behind the sheet"
        )
        #expect(sheet.contains("case .openConnectionProtocol:"))
        #expect(sheet.contains("onOpenConnectionSettings()"))
        // An undecided protocol is explained by the capability card itself; the top of the page does not repeat it in a banner.
        #expect(sheet.contains("switch identityGap.recoveryAction {"))
        #expect(sheet.contains("case .openConnectionSettings:\n                // Undecided protocol: the capability card collapses into \"choose the protocol first\", and that is the way out.\n                return nil"))
        #expect(sheet.contains("case .writable:\n            return nil"))

        let composer = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ChatComposerBar.swift",
        ])
        #expect(composer.contains("opensModelPickerAfterControls = true"))
        #expect(composer.contains("onChooseModel()"))
        #expect(composer.contains("opensConnectionSettingsAfterControls = true"))
        #expect(composer.contains("appState.navigation.openProviderDetail(providerID: provider.id)"))
    }

    // MARK: - The height follows the content

    /// When a detent is set from measured content height, a lazy container in the content makes that height unusable,
    /// and the panel is silently clamped to full screen: no error, and every test stays green.
    @Test("the panel is as tall as its content: one detent on the root page, the full-height detent joins only for a pushed page and the push follows one turn later, half the screen when it cannot be measured, no lazy containers in the content")
    func sheetHeightFollowsContent() throws {
        let sheet = try Self.source(Self.modelControls + ["ModelControlsSheet.swift"])
        let scaffold = try #require(sheet.range(of: "struct ModelOptionsSheetScaffold"))
        let scaffoldEnd = try #require(sheet.range(of: "// MARK: - Panel\n", range: scaffold.upperBound..<sheet.endIndex))
        let shell = String(sheet[scaffold.lowerBound..<scaffoldEnd.lowerBound])
        // The root page has only the content-height detent; the full-height one joins when a page is pushed, and the
        // sheet grows by changing the selection (replacing a lone detent gets no transition).
        #expect(shell.contains("stackPath.isEmpty && selectedDetent != .large ? [fittedDetent] : [fittedDetent, .large]"))
        #expect(shell.contains("selection: $selectedDetent"))
        #expect(!shell.contains(".presentationDetents([detent])"))
        // The stack follows its own path one turn behind the caller's: growing and pushing in the same turn leaves
        // the incoming page clipped to the old height for about half a second.
        #expect(shell.contains("NavigationStack(path: $stackPath)"))
        #expect(!shell.contains("NavigationStack(path: $path)"))
        #expect(shell.contains("ModelOptionsSheetHeight.resolve("))
        #expect(shell.contains("case .half: return .medium"))
        // The height is measured in place inside the hierarchy, not by a separate host outside it (which would not see the user's text size).
        #expect(shell.contains(".onGeometryChange(for: CGFloat.self) { $0.size.height }"))
        #expect(!shell.contains("UIHostingController"))

        for name in ["ModelControlsSheet.swift", "ModelControlsComponents.swift"] {
            let source = try Self.source(Self.modelControls + [name])
            for lazy in ["LazyVStack", "LazyHStack", "LazyVGrid", "LazyHGrid", "List {", "List("] {
                #expect(!source.contains(lazy), "\(name) contains the lazy container \(lazy); the panel height could not be measured")
            }
        }
    }

    @Test("a panel without a navigation bar: the close button is in the header and the top spacing is at least 24pt")
    func headerOwnsCloseAndTopInset() throws {
        let panel = try Self.panelViewSource()
        #expect(panel.contains("ModelOptionCloseButton { onAction(.close) }"))
        let inset = try #require(panel.range(of: ".padding(.top, "))
        let value = Int(panel[inset.upperBound...].prefix { $0.isNumber }) ?? 0
        #expect(value >= 24, "the panel's top spacing is only \(value)pt; the title would touch the grabber")
        let sheet = try Self.source(Self.modelControls + ["ModelControlsSheet.swift"])
        #expect(sheet.contains(".toolbar(.hidden, for: .navigationBar)"))
    }

    @Test("only advanced settings and the candidate models are pushed, and no second modal is opened")
    func onlyTwoRoutesAndNoNestedModal() throws {
        let sheet = try Self.source(Self.modelControls + ["ModelControlsSheet.swift"])
        #expect(sheet.contains(
            "case modelBehavior\n    case additionalRequestBody\n    case supportedModels(capability: String)\n}"
        ))
        // "Open additional request body" goes straight to the editor without passing through the advanced settings page.
        #expect(sheet.contains("case .openAdditionalRequestBody:\n            // Goes straight to the editor without passing through the advanced settings page; back returns to the panel.\n            path.append(.additionalRequestBody)"))
        #expect(sheet.contains("AdditionalRequestBodyPage("))
        #expect(sheet.contains("presentation: .embeddedPage"))
        #expect(!sheet.contains(".fullScreenCover("))
        // No `.sheet(` anywhere in the file: sub-pages are always pushed.
        #expect(!sheet.contains(".sheet("), "the panel opens another modal again")
        #expect(!sheet.contains(".alert("), "the explanation for an unavailable item is back in an alert")
    }

    // MARK: - Scope and stored values

    @Test("opening the panel only reads: restore writes nothing to disk")
    func openingThePanelWritesNothing() throws {
        let sheet = try Self.source(Self.modelControls + ["ModelControlsSheet.swift"])
        let start = try #require(sheet.range(of: "private func restore() {"))
        let end = try #require(sheet.range(of: "private func persist() {", range: start.upperBound..<sheet.endIndex))
        let restore = String(sheet[start.lowerBound..<end.lowerBound])
        for write in ["setCapabilityPreferences(", "setAdditionalRequestBody(", "ChatTemplateThinkingSwitch.write("] {
            #expect(!restore.contains(write), "opening the panel calls \(write)")
        }
    }

    @Test("scope is raised after the fact, the confirmation is an inline state rather than a toast, and a draft conversation shows it too")
    func scopeUpgradeIsOfferedAfterAChange() throws {
        let sheet = try Self.source(Self.modelControls + ["ModelControlsSheet.swift"])
        #expect(sheet.contains("if conversationID != nil, !showsScopeUpgrade {"))
        // A new change withdraws the earlier confirmation.
        #expect(sheet.contains("scopeUpgradeConfirmed = false"))
        #expect(!sheet.contains("ToastManager.shared"), "a toast raised from inside a sheet is not seen")
        let panel = try Self.panelViewSource()
        #expect(panel.contains("ModelControlScopeUpgradeRow(isConfirmed: scopeUpgrade == .confirmed)"))
        let components = try Self.source(Self.modelControls + ["ModelControlsComponents.swift"])
        #expect(components.contains("L10n.tr(\"Applied to this conversation\", table: .chat)"))
        #expect(components.contains("L10n.tr(\"Set as default for this model\", table: .chat)"))
    }

    // MARK: - Segments and motion

    @Test("the segmented choice's movement respects accessibilityReduceMotion and does not express disabled through opacity")
    func segmentedControlRespectsReduceMotion() throws {
        let components = try Self.source(Self.modelControls + ["ModelControlsComponents.swift"])
        let start = try #require(components.range(of: "struct ModelOptionSegmentedControl: View {"))
        let end = try #require(components.range(
            of: "struct ModelOptionSettingChip", range: start.upperBound..<components.endIndex
        ))
        let control = String(components[start.lowerBound..<end.lowerBound])
        #expect(control.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
        #expect(control.contains(".animation(reduceMotion ? nil :"))
        // Every segment can be tapped: this control has no disabled state at all.
        #expect(!control.contains(".disabled("))
        #expect(!control.contains("isEnabled"))
    }

    // MARK: - Debug samples

    @Test("the sample entry exists in DEBUG builds only")
    func sampleHostIsDebugOnly() throws {
        let host = try Self.source(Self.modelControls + ["ModelOptionsSampleHost.swift"])
        #expect(host.hasPrefix("#if DEBUG\n"))
        #expect(host.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"))
        // The whole file has a single conditional compilation block: no early `#endif` lets the second half into Release.
        #expect(host.components(separatedBy: "#endif").count == 2)
        #expect(host.components(separatedBy: "#if ").count == 2)

        let app = try Self.source(["ios", "Oriveo", "Oriveo", "OriveoApp.swift"])
        let reference = try #require(app.range(of: "ModelOptionsSample.requestedName"))
        let before = app[..<reference.lowerBound]
        let lastIf = try #require(before.range(of: "#if DEBUG", options: .backwards))
        #expect(
            !before[lastIf.upperBound...].contains("#e"),
            "the app entry references the samples outside an `#if DEBUG` branch"
        )
        // Apart from that one place, the app entry does not mention the samples.
        let branchEnd = try #require(app.range(of: "#else", range: reference.upperBound..<app.endIndex))
        #expect(!app[..<lastIf.lowerBound].contains("ModelOptionsSample"))
        #expect(!app[branchEnd.upperBound...].contains("ModelOptionsSample"))
    }

    // MARK: - Missing identity

    @Test("the three reasons for a missing identity are told apart, in the order of the guards in make()")
    func identityGapSeparatesEachCause() {
        #expect(ModelControlsIdentityGap.resolve(
            providerKind: .relay, relayTransportIsDecided: false, runtimeIsReady: false
        ) == .runtimeSnapshotMissing)
        #expect(ModelControlsIdentityGap.resolve(
            providerKind: .openAI, relayTransportIsDecided: false, runtimeIsReady: false
        ) == .runtimeSnapshotMissing)
        #expect(ModelControlsIdentityGap.resolve(
            providerKind: .relay, relayTransportIsDecided: false, runtimeIsReady: true
        ) == .relayTransportUndecided)
        #expect(ModelControlsIdentityGap.resolve(
            providerKind: .relay, relayTransportIsDecided: true, runtimeIsReady: true
        ) == .modelNotInCatalog)
        #expect(ModelControlsIdentityGap.resolve(
            providerKind: .openAI, relayTransportIsDecided: false, runtimeIsReady: true
        ) == .modelNotInCatalog)
    }

    @Test("Identity Gap Actions Are Distinct")
    func identityGapActionsAreDistinct() {
        #expect(ModelControlsIdentityGap.runtimeSnapshotMissing.recoveryAction == .refetchRuntime)
        #expect(ModelControlsIdentityGap.relayTransportUndecided.recoveryAction == .openConnectionSettings)
        #expect(ModelControlsIdentityGap.modelNotInCatalog.recoveryAction == .chooseAnotherModel)
        let causes: [ModelControlsIdentityGap] = [
            .runtimeSnapshotMissing, .relayTransportUndecided, .modelNotInCatalog,
        ]
        #expect(Set(causes.map(\.recoveryAction)).count == causes.count)
        #expect(ModelControlsIdentityGap.RecoveryAction.allCases.count == causes.count)
    }

    @MainActor
    @Test("Identity Unavailable Stops Telling User To Pick A Model")
    func identityUnavailableStopsTellingUserToPickAModel() {
        #expect(ModelControlsEditability.runtimeIdentityUnavailable.reasonText == nil)
        for gap: ModelControlsIdentityGap in [.runtimeSnapshotMissing, .relayTransportUndecided, .modelNotInCatalog] {
            #expect(!gap.reasonText.isEmpty)
        }
    }

    @Test("Published Bindings Are Guarded By Equality")
    func publishedBindingsAreGuardedByEquality() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        #expect(sheet.contains("if webEnabled != nextWebEnabled { webEnabled = nextWebEnabled }"))
        #expect(sheet.contains("if reasoningMode != nextMode { reasoningMode = nextMode }"))
        #expect(sheet.contains("if reasoningIntentSelection != reasoningIntent {"))
        #expect(!sheet.contains("\n        webEnabled = web != .off\n"))
        #expect(!sheet.contains("\n        reasoningIntentSelection = reasoningIntent\n"))

        let composer = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ChatComposerBar.swift",
        ])
        #expect(composer.contains("if reasoningIntentSelection != stored.reasoningIntent {"))
        #expect(composer.contains("if webPreferenceSelection != nextWeb { webPreferenceSelection = nextWeb }"))
        #expect(!composer.contains("\n        reasoningIntentSelection = stored.reasoningIntent\n"))
    }

    @Test("Read Path Matches The Send Path")
    func readPathMatchesTheSendPath() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        let composer = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ChatComposerBar.swift",
        ])
        let chatView = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ChatView.swift",
        ])
        let manager = try Self.source([
            "ios", "Oriveo", "Oriveo", "Core", "State", "ChatManager.swift",
        ])
        let store = try Self.source([
            "ios", "Oriveo", "Oriveo", "Core", "Providers",
            "GenerationParameterSettingsStore.swift",
        ])

        #expect(composer.contains("displayCapabilityPreferences("))
        #expect(!composer.contains("GenerationParameterSettingsStore.shared.capabilityPreferences("),
                "the composer only inspects the conversation scope again")
        let display = try #require(store.range(of: "func displayCapabilityPreferences("))
        let displayBody = String(store[display.upperBound...].prefix(700))
        #expect(displayBody.contains("capabilityScopeValues("), "the read entry point does not walk the shared scope ladder")
        #expect(store.components(separatedBy: "capabilityScopeValues(").count == 4)

        #expect(sheet.contains("guard let transportIdentity = effectiveTransportIdentity else { return }"))
        #expect(sheet.contains("guard editability.canPersist, let transportIdentity = effectiveTransportIdentity else { return }"))

        #expect(chatView.contains("ReasoningMode.fromIntent(values.reasoningIntent) ?? .automatic"))
        #expect(manager.contains("ReasoningMode.fromIntent(intent) ?? .automatic"))
        #expect(manager.contains("displaySelection("))
        for source in [chatView, manager, sheet] {
            #expect(
                !source.contains("flatMap(ReasoningMode.init(rawValue:))"),
                "a reasoning mode is being constructed from a raw value again, which silently drops the level whose intent and local name differ"
            )
        }

        // The composer's dot counts conversation overrides ∪ model defaults; the chips on the panel's "Advanced settings" row only show items changed in this conversation,
        // and they use the same parameter table and row factory as the advanced settings page instead of computing separately.
        #expect(sheet.contains("AdvancedSettingsCatalog.production("))
        #expect(sheet.contains("catalog.rows("))
        #expect(composer.contains("activeOverrideParameterIDs("))
        #expect(!composer.contains("hasSessionOverrides("), "the dot only counts the session override layer again")
    }

    @Test("Missing Model Fallback Keeps The Panel Shape")
    func missingModelFallbackKeepsThePanelShape() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        #expect(sheet.contains("ModelControlsMissingModelSheet("))
        #expect(sheet.contains("L10n.tr(\"Web Search\", table: .chat)"))
        #expect(sheet.contains("L10n.tr(\"Thinking Mode\", table: .chat)"))
        #expect(sheet.contains("L10n.tr(\"Advanced Settings\")"))
        // The missing-model state keeps its bottom close bar; the main panel's close button is in the header.
        #expect(sheet.contains("ModelControlsCloseBar { dismiss() }"))
    }

    /// `displayTransport` takes the rawValue of the local `RelayTransport` for a relay and the catalog transport for an official provider.
    /// **The two vocabularies are not interchangeable**: the same Chat Completions protocol is
    /// `openai_chat_completions` on one side and `openai_chat` on the other. A label function that only lists the relay set
    /// drops official models into the default case, and the panel's subtitle shows an uninformative "Protocol".
    /// Catalog-side values follow what actually occurs in `.providers[].models[].transport` of the metadata
    /// (openai_chat, openai_responses, gemini_generate,
    /// anthropic_messages), not the `RelayTransport` enum.
    @Test("the transport label recognizes both the catalog and the relay vocabulary")
    func transportLabelCoversCatalogAndRelayVocabularies() {
        #expect(CapabilityTransportLabel.display("openai_chat") == "Chat Completions")
        #expect(CapabilityTransportLabel.display("openai_responses") == "Responses")
        #expect(CapabilityTransportLabel.display("gemini_generate") == "generateContent")
        #expect(CapabilityTransportLabel.display("anthropic_messages") == "Messages")
        #expect(CapabilityTransportLabel.display("openai_chat_completions") == "Chat Completions")
        #expect(CapabilityTransportLabel.display("gemini_generate_content") == "generateContent")
        #expect(CapabilityTransportLabel.display("llamacpp_native") == "llama.cpp")
    }

    private static let catalogTransports = [
        "openai_chat", "openai_responses", "anthropic_messages", "gemini_generate",
        "dashscope_native", "openai_images", "gemini_image", "qwen_image",
        "grok_image", "zhipu_image",
    ]

    @Test("Every Catalog Transport Has A Label")
    func everyCatalogTransportHasALabel() {
        let fallback = L10n.tr("Protocol", table: .providers)
        for transport in Self.catalogTransports {
            let label = CapabilityTransportLabel.display(transport)
            #expect(label != fallback, "catalog transport \(transport) fell through to the default and the panel would show the uninformative generic label")
            #expect(!label.isEmpty)
        }
    }

    @Test("Every Relay Transport Has A Label")
    func everyRelayTransportHasALabel() {
        let fallback = L10n.tr("Protocol", table: .providers)
        for transport in RelayTransport.allCases where transport != .auto {
            let label = CapabilityTransportLabel.display(transport.rawValue)
            #expect(label != fallback, "RelayTransport.\(transport) fell through to the default and the panel would show the generic label")
        }
    }

    // MARK: - No global switch for custom request fields

    @Test("Developer Gate Is Gone From The Whole Repository")
    func developerGateIsGoneFromTheWholeRepository() throws {
        let base = Self.findDirectory(["ios", "Oriveo", "Oriveo"])
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if text.contains("isLocalCustomDeveloperModeEnabled")
                || text.contains("setLocalCustomDeveloperModeEnabled")
                || text.contains("localCustomDeveloperModeDefaultsKey")
                || text.contains("customDeveloperModeEnabled") {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, "the global switch is back: \(offenders)")

        let store = try Self.source([
            "ios", "Oriveo", "Oriveo", "Core", "Providers",
            "GenerationParameterSettingsStore.swift",
        ])
        #expect(store.contains("migrateRetiredLocalCustomDeveloperGate"))
        #expect(!store.contains("guard isLocalCustomDeveloperModeEnabled"))
    }

    @Test("Settings Has No Advanced Group And Outbound Only Checks Mode")
    func settingsHasNoAdvancedGroupAndOutboundOnlyChecksMode() throws {
        let settings = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Settings", "SettingsView.swift",
        ])
        #expect(!settings.contains("advancedSection"), "the Advanced group is back in the settings screen")
        #expect(!settings.contains("L10n.tr(\"Advanced\", table: .settings)"))
        #expect(!settings.contains("Custom request fields"), "the global switch row is back in the settings screen")

        let store = try Self.source([
            "ios", "Oriveo", "Oriveo", "Core", "Providers",
            "GenerationParameterSettingsStore.swift",
        ])
        #expect(store.contains("guard configuration.mode == .custom else { return nil }"))
        let chat = try Self.source([
            "ios", "Oriveo", "Oriveo", "Core", "State", "ChatManager.swift",
        ])
        #expect(!chat.contains("developerModeEnabled"))
    }

    /// All three consumers of the web search criterion have to pass the same gate (the pure criterion is covered in `ModelOptionsPanelModelTests`).
    ///
    /// Missing one is the same as missing all: with only the panel fixed the composer's globe stays lit; with the composer fixed too, ChatView would still put
    /// `web_search` into explicitKeys and the whole evidence projection would go on as if the user had explicitly asked for web search.
    @Test("the outbound criterion for a stored web search preference is wired into the panel, the composer and ChatView")
    func staleWebGateIsWiredEverywhere() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        let composer = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ChatComposerBar.swift",
        ])
        let chatView = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ChatView.swift",
        ])
        #expect(sheet.contains("CapabilityWebPreferenceLiveness.reachesTheWire("))
        #expect(composer.contains("CapabilityWebPreferenceLiveness.reachesTheWire("))
        #expect(chatView.contains("CapabilityWebPreferenceLiveness.reachesTheWire("))
        #expect(chatView.contains("webIsExplicit ? \"web_search\" : nil"))
        #expect(
            !sheet.contains("let nextWebEnabled = web != .off\n"),
            "the panel treats a bare non-off preference as \"this will actually be sent\" again"
        )
    }

    /// Push and pop of second-level pages are dropped as well.
    ///
    /// The push animation of `NavigationStack` is driven by a system transaction: `.animation(nil)` does not turn it off,
    /// `disablesAnimations` has to be set on the transaction. So this asserts that specific form,
    /// not "the file mentions reduceMotion"; the latter would be green with only the segmented control wired.
    @Test("the push transition of second-level pages respects accessibilityReduceMotion")
    func pushTransitionRespectsReduceMotion() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        #expect(
            sheet.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"),
            "the panel never reads Reduce Motion"
        )
        #expect(sheet.contains("guard reduceMotion else { return }"), "the transition has no Reduce Motion branch")
        #expect(
            sheet.contains("transaction.disablesAnimations = true"),
            "setting the animation to nil is not enough to disable the navigation push animation"
        )
    }

    // MARK: - helpers

    private static func source(_ components: [String]) throws -> String {
        try String(contentsOf: findFile(components), encoding: .utf8)
    }

    private static func findFile(_ components: [String]) -> URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while current.path != current.deletingLastPathComponent().path {
            let candidate = components.reduce(current) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            current = current.deletingLastPathComponent()
        }
        fatalError("source not found: \(components.joined(separator: "/"))")
    }

    private static func findDirectory(_ components: [String]) -> URL {
        findFile(components)
    }
}
