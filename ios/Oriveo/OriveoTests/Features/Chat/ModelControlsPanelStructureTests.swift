import Foundation
import Testing
@testable import Oriveo

/// Structural discipline for the model controls panel: no greyed-out controls, no second modal
/// pushed on top of the sheet, and no custom request fields inside a capability card.
///
/// These are source assertions rather than render assertions because each of them is a "this must
/// not exist" property. A SwiftUI `body` is an opaque type, so the render side cannot answer
/// questions like "is there a second modal"; and when one of them regresses the user sees a broken
/// panel while every behavioural test stays green.
@Suite("Model Controls Panel Structure Tests")
struct ModelControlsPanelStructureTests {
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

    @Test("Main Panel Order Is Frozen")
    func mainPanelOrderIsFrozen() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        let listStart = try #require(sheet.range(of: "private var capabilityList: some View {"))
        let listBody = String(sheet[listStart.upperBound...].prefix(300))
        let web = try #require(listBody.range(of: "webCard"))
        let reasoning = try #require(listBody.range(of: "reasoningCard", range: web.upperBound..<listBody.endIndex))
        let behavior = try #require(listBody.range(of: "modelBehaviorCard", range: reasoning.upperBound..<listBody.endIndex))
        #expect(web.lowerBound < reasoning.lowerBound && reasoning.lowerBound < behavior.lowerBound)
    }

    @Test("Read Only Summary Offers A Recovery Action")
    func readOnlySummaryOffersARecoveryAction() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        #expect(sheet.contains("if let reason = readOnlyReasonText"))
        #expect(sheet.contains("readOnlySummary(reason: reason)"))
        #expect(sheet.contains("Choose another model"))
        #expect(sheet.contains("Button(action: onChooseConnection)"))
        #expect(sheet.contains("Set the protocol"))
        #expect(sheet.contains("await MetadataClient.shared.forceRefresh()"))

        #expect(
            !sheet.contains("ProviderDetailView(providerID: provider.id)"),
            "the panel pushes the provider detail screen inside the sheet again; its back button pops the stack behind the sheet"
        )
        #expect(sheet.contains("Button(action: onOpenConnectionSettings)"))

        let composer = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ChatComposerBar.swift",
        ])
        #expect(composer.contains("opensModelPickerAfterControls = true"))
        #expect(composer.contains("onChooseModel()"))
        #expect(composer.contains("opensConnectionSettingsAfterControls = true"))
        #expect(composer.contains("appState.navigation.openProviderDetail(providerID: provider.id)"))
    }

    @Test("Identity Gap Separates Each Cause")
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

        #expect(sheet.contains("activeOverrideParameterIDs("))
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
        #expect(sheet.contains("ModelControlsCloseBar { dismiss() }"))
    }

    @Test("Unknown Badge Is Not Ready Rather Than Unavailable")
    func unknownBadgeIsNotReadyRatherThanUnavailable() {
        #expect(ModelControlBadgeClassification.resolve(.unknown) == .notReady)
        #expect(ModelControlBadgeClassification.resolve(.pending) == .notReady)
        #expect(ModelControlBadgeClassification.resolve(.unsupported) == .unavailable)
    }

    @Test("Capability Cards Drop The Unavailable Badge")
    func capabilityCardsDropTheUnavailableBadge() {
        #expect(ModelControlBadgeClassification.capabilityCard(.unsupported) == ModelControlBadgeClassification.none)
        #expect(
            ModelControlBadgeClassification.capabilityCard(.externalConnectorOnly)
                == ModelControlBadgeClassification.none
        )
        for status: CapabilityControlPresentation in [
            .automaticAvailable, .forceUnsupported,
            .customOnly, .pending, .unknown,
        ] {
            #expect(
                ModelControlBadgeClassification.capabilityCard(status)
                    == ModelControlBadgeClassification.resolve(status),
                "the badge for \(status) was suppressed as well; only the unavailable state should lose its badge"
            )
        }
        #expect(ModelControlBadgeClassification.resolve(.unsupported) == .unavailable)
        #expect(ModelControlBadgeClassification.resolve(.externalConnectorOnly) == .unavailable)
    }

    @Test("Advanced Settings Card Drops The Not Ready Badge")
    func advancedSettingsCardDropsTheNotReadyBadge() {
        #expect(
            ModelControlBadgeClassification.advancedSettingsCard(.unknown)
                == ModelControlBadgeClassification.none
        )
        #expect(
            ModelControlBadgeClassification.advancedSettingsCard(.pending)
                == ModelControlBadgeClassification.none
        )
        #expect(ModelControlBadgeClassification.advancedSettingsCard(.unsupported) == .unavailable)
        #expect(
            ModelControlBadgeClassification.advancedSettingsCard(.externalConnectorOnly) == .unavailable
        )
        for status: CapabilityControlPresentation in [
            .automaticAvailable, .forceUnsupported,
            .customOnly, .unsupported, .externalConnectorOnly,
        ] {
            #expect(
                ModelControlBadgeClassification.advancedSettingsCard(status)
                    == ModelControlBadgeClassification.resolve(status),
                "the badge for \(status) was suppressed as well; only the not-ready badge should be dropped here"
            )
        }
        #expect(ModelControlBadgeClassification.capabilityCard(.unknown) == .notReady)
        #expect(ModelControlBadgeClassification.capabilityCard(.pending) == .notReady)
    }

    @Test("Each Card Consumes Its Own Badge Projection")
    func eachCardConsumesItsOwnBadgeProjection() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        for card in ["private var webCard: some View {", "private var reasoningCard: some View {"] {
            let start = try #require(sheet.range(of: card))
            let rest = sheet[start.upperBound...]
            let body = String(rest[..<(rest.range(of: "// MARK:")?.lowerBound ?? rest.endIndex)])
            #expect(
                body.contains("badge: capabilityCardBadge(for: status, overridden: overridden)"),
                "\(card) is back on the original badge that says unavailable"
            )
        }
        let behavior = try #require(sheet.range(of: "private var modelBehaviorCard: some View {"))
        let behaviorRest = sheet[behavior.upperBound...]
        let behaviorBody = String(
            behaviorRest[..<(behaviorRest.range(of: "// MARK:")?.lowerBound ?? behaviorRest.endIndex)]
        )
        #expect(behaviorBody.contains("ModelControlNavigationRow("), "the scope was not narrowed to the advanced settings card, so this assertion has no subject")
        #expect(
            behaviorBody.contains("badge: advancedSettingsBadge("),
            "the advanced settings card is wired back to the unsuppressed projection, so relay connections and models without a recipe show a false not-ready badge again"
        )
        #expect(
            !behaviorBody.contains("badge: capabilityCardBadge("),
            "the advanced settings card was wired to the capability card suppression, which suppresses unavailable rather than not-ready"
        )
        let row = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsComponents.swift",
        ])
        let rowStart = try #require(row.range(of: "struct ModelControlNavigationRow: View {"))
        let rowBody = String(row[rowStart.upperBound...].prefix(1600))
        #expect(
            rowBody.contains("if let badge {") && rowBody.contains("} else if let trailingText {"),
            "the relationship between the trailing text and the badge changed, so the badge projection for the advanced settings card has to be reconsidered"
        )
    }

    @Test("Transport Label Covers Catalog And Relay Vocabularies")
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

    @Test("Close Action Is Pinned To Bottom")
    func closeActionIsPinnedToBottom() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        #expect(sheet.contains(".safeAreaInset(edge: .bottom"))
        #expect(sheet.contains("ModelControlsCloseBar { dismiss() }"))
        #expect(sheet.contains("Button(L10n.tr(\"Close\"), action: action)"))
        #expect(sheet.contains(".frame(maxWidth: .infinity, minHeight: 50)"))
        #expect(sheet.contains(".foregroundStyle(OriveoTheme.Palette.textPrimary)"))
        #expect(!sheet.contains(".background(.bar)"), "the close bar is back on the system material, which matches the panel background in neither theme")
    }

    @Test("Sheet Uses A Single Large Detent")
    func sheetUsesASingleLargeDetent() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        #expect(sheet.contains(".presentationDetents([.large])"))
        #expect(sheet.contains(".presentationCornerRadius(24)"))
        #expect(
            sheet.components(separatedBy: ".presentationDetents([.large])").count == 3,
            "the two modals no longer share a single detent"
        )
        #expect(!sheet.contains(".fraction("), "multiple detents are back, so dragging up is eaten by the resize gesture")
        #expect(!sheet.contains("PresentationDetent"), "the detent state is back")
        #expect(!sheet.contains(".onChange(of: path)"), "the detent-raising logic is back")
    }

    @Test("Dynamic Type Narrow Width And RTL Stay Usable")
    func dynamicTypeNarrowWidthAndRTLStayUsable() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        let components = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsComponents.swift",
        ])
        #expect(!sheet.contains(".font(.system(size:"))
        #expect(components.contains(".frame(minHeight: 44)"))
        #expect(components.contains("@Environment(\\.layoutDirection) private var layoutDirection"))
        #expect(components.contains("layoutDirection == .rightToLeft"))
    }


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


    @Test("Main Panel Is Single Page")
    func mainPanelIsSinglePage() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        #expect(sheet.contains("private var capabilityList: some View"))
        for card in ["private var webCard", "private var reasoningCard", "private var modelBehaviorCard"] {
            #expect(sheet.contains(card))
        }
        for gone in ["private var webPage", "private var reasoningPage", "private func capabilityPage"] {
            #expect(!sheet.contains(gone), "\(gone) is still there: web and reasoning were pushed back onto a second page")
        }
    }

    @Test("Only Model Behavior Is Pushed")
    func onlyModelBehaviorIsPushed() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        #expect(sheet.contains("NavigationLink(value: ModelControlsRoute.modelBehavior)"))
        #expect(!sheet.contains("ModelControlsRoute.web"), "web was pushed back onto a second page")
        #expect(!sheet.contains("ModelControlsRoute.reasoning"), "reasoning was pushed back onto a second page")
        #expect(!sheet.contains(".sheet("), "a second-level page opened another modal on top of the sheet")
    }

    @Test("Reasoning Is A Pill Row")
    func reasoningIsAPillRow() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        let components = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsComponents.swift",
        ])
        #expect(sheet.contains("case .pillRow:"))
        #expect(sheet.contains("ModelControlIntentPicker("))
        #expect(sheet.contains("ModelControlNote(text: layout.selectedAnnotation)"), "the annotation for the selected level is not rendered")
        #expect(!sheet.contains("ModelControlRadioRow("), "the vertical single-selection list is back")
        #expect(!components.contains("struct ModelControlRadioRow"), "the radio row component was not fully removed")
        #expect(
            !sheet.contains("Deep thinking"),
            "the deep-thinking switch is back, so one meaning has two controls again"
        )
        #expect(!sheet.contains("secondaryTierRow"), "the highest level was demoted back into a secondary small-print entry")
        #expect(
            !sheet.contains("ModelControlSegmentedPicker"),
            "the levels went back to a fixed-width segmented control, which cannot hold many levels or long translations"
        )
    }

    @Test("Panel Never Renders Disabled Options")
    func panelNeverRendersDisabledOptions() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        #expect(sheet.contains("ModelControlStatusRow("), "the unavailable state does not degrade to a status row")
        for disabled in [
            "isEnabled: configurable", "isEnabled: !layout.tiersDimmed",
            "isEnabled: false", "isEnabled: layout.isToggleEnabled",
        ] {
            #expect(!sheet.contains(disabled), "the panel renders a greyed-out control again: \(disabled)")
        }
    }

    @Test("Status Rows Always Explain Themselves")
    func statusRowsAlwaysExplainThemselves() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        #expect(sheet.contains("private func presentExplanation("))
        #expect(sheet.contains("action: detail.map { message in"), "the status row is not wired to be tappable only when it has an explanation")
        #expect(sheet.contains("supportedModelCandidates(for: capability).isEmpty"))
        #expect(sheet.contains("resolved = .none"))
        #expect(sheet.contains("L10n.tr(\"View supported models\", table: .chat)"))
        #expect(sheet.contains("L10n.tr(\"Go to Advanced Settings\", table: .chat)"))
    }

    @Test("Scope Upgrade Is Inline And After The Fact")
    func scopeUpgradeIsInlineAndAfterTheFact() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        #expect(sheet.contains("ModelControlScopeUpgradeRow("))
        #expect(sheet.contains("private func promoteSelectionToModelDefault()"))
        #expect(sheet.contains(
            "modelID: capabilityModelID, conversationID: nil, transportIdentity: transportIdentity"
        ))
        #expect(!sheet.contains("ToastManager.shared"), "a toast raised from inside the sheet is invisible, because the toast overlay sits below the modal")
        #expect(!sheet.contains("These settings apply to this conversation only."))
        #expect(!sheet.contains("These settings apply to your next conversation with this model."))
    }

    @Test("Scope Upgrade Is Pinned Above The Close Bar")
    func scopeUpgradeIsPinnedAboveTheCloseBar() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        #expect(sheet.contains(".safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }"))
        let barStart = try #require(sheet.range(of: "private var bottomBar: some View {"))
        let bar = String(sheet[barStart.upperBound...].prefix(600))
        let row = try #require(bar.range(of: "ModelControlScopeUpgradeRow("))
        let close = try #require(bar.range(of: "ModelControlsCloseBar {", range: row.upperBound..<bar.endIndex))
        #expect(row.lowerBound < close.lowerBound, "the upgrade row moved below the close bar")

        let listStart = try #require(sheet.range(of: "private var capabilityList: some View {"))
        let list = String(sheet[listStart.upperBound..<barStart.lowerBound])
        #expect(
            !list.contains("ModelControlScopeUpgradeRow("),
            "the upgrade row is back inside the scrolling content, where the close bar covers it when it appears"
        )

        let components = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsComponents.swift",
        ])
        let rowStart = try #require(components.range(of: "struct ModelControlScopeUpgradeRow: View {"))
        let rest = components[rowStart.lowerBound...]
        let scope = String(rest[..<(rest.range(of: "// MARK:")?.lowerBound ?? rest.endIndex)])
        #expect(scope.contains(".background(OriveoTheme.Palette.surfaceChrome)"))
        #expect(!scope.contains(".modelControlSurface()"), "the pinned bottom area gained a second floating card layer")
    }

    @Test("Header Names The Model")
    func headerNamesTheModel() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        #expect(sheet.contains(".navigationTitle(model.name)"), "the title should be the model, not a category name")
        #expect(!sheet.contains("New conversations will use these settings."))
        #expect(!sheet.contains("Model Controls"))
        #expect(!sheet.contains("Model Behavior"))
    }

    @Test("Scope Upgrade Visibility Follows The Conversation Scope")
    func scopeUpgradeVisibilityFollowsTheConversationScope() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        #expect(sheet.contains("if conversationID != nil, !showsScopeUpgrade {"))
        #expect(
            !sheet.contains("if isExistingConversation, conversationID != nil, !showsScopeUpgrade {"),
            "draft conversations are excluded from the scope upgrade again"
        )
        let persist = try #require(sheet.range(of: "private func persist() {"))
        let confirmed = try #require(sheet.range(of: "scopeUpgradeConfirmed = false", range: persist.upperBound..<sheet.endIndex))
        let write = try #require(sheet.range(of: "setCapabilityPreferences(", range: persist.upperBound..<sheet.endIndex))
        #expect(confirmed.lowerBound < write.lowerBound, "the confirmation sentence is not withdrawn before the write")
        #expect(sheet.contains("if showsScopeUpgrade, path.isEmpty {"), "the upgrade row follows the user onto second-level pages again")
    }


    @MainActor
    @Test("Footer Is Empty In The Ordinary Case")
    func footerIsEmptyInTheOrdinaryCase() {
        let entries = ModelControlCapabilityFooter.entries(.init())
        #expect(entries.isEmpty)
        #expect(ModelControlCapabilityFooter.entries(.init(context: .behaviorPageHeader)).isEmpty)
    }

    @Test("Empty Footer Yields Nil Header")
    func emptyFooterYieldsNilHeader() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        #expect(sheet.contains("private var generationCapabilityHeader: AnyView?"))
        #expect(sheet.contains("guard !entries.isEmpty else { return nil }"))
        #expect(
            !sheet.contains("capabilityHeader: AnyView(generationCapabilityHeader)"),
            "the header is unconditionally wrapped into a non-empty view again, so every second-level page carries an empty card at the top"
        )
    }

    @MainActor
    @Test("Read Only Reason Is Not Repeated Inside Cards")
    func readOnlyReasonIsNotRepeatedInsideCards() {
        let reason = "read-only because reasons"
        let card = ModelControlCapabilityFooter.entries(
            .init(context: .panelCard, readOnlyReason: reason, isConfigurable: false, statusText: "status")
        )
        #expect(card.isEmpty, "the card repeats the read-only reason already stated at the top of the page")

        let page = ModelControlCapabilityFooter.entries(
            .init(context: .behaviorPageHeader, readOnlyReason: reason, isConfigurable: false, statusText: "status")
        )
        #expect(page == [.note(text: reason, systemImage: "lock.fill", tone: .tertiary)])
    }

    @MainActor
    @Test("Status Note Yields To The No Candidates Note")
    func statusNoteYieldsToTheNoCandidatesNote() {
        let both = ModelControlCapabilityFooter.entries(.init(
            context: .behaviorPageHeader,
            isConfigurable: false,
            statusText: "This capability is unavailable",
            showsSupportedModelsAction: true,
            hasSupportedModelCandidates: false
        ))
        #expect(both.count == 1)
        #expect(!both.contains(.note(text: "This capability is unavailable", systemImage: nil, tone: .tertiary)))

        let withCandidates = ModelControlCapabilityFooter.entries(.init(
            context: .behaviorPageHeader,
            isConfigurable: false,
            statusText: "This capability is unavailable",
            showsSupportedModelsAction: true,
            hasSupportedModelCandidates: true
        ))
        #expect(withCandidates == [
            .note(text: "This capability is unavailable", systemImage: nil, tone: .tertiary),
            .supportedModelsLink,
        ])
    }

    @MainActor
    @Test("Only Lock And Warning Notes Keep Icons")
    func onlyLockAndWarningNotesKeepIcons() {
        let status = ModelControlCapabilityFooter.entries(
            .init(context: .behaviorPageHeader, isConfigurable: false, statusText: "No automatic configuration yet")
        )
        #expect(status == [.note(text: "No automatic configuration yet", systemImage: nil, tone: .tertiary)])

        let risky = ModelControlCapabilityFooter.entries(
            .init(context: .behaviorPageHeader, riskTiers: ["privacy_impacting", "cost_impacting"])
        )
        #expect(risky.count == 2)
        for entry in risky {
            guard case let .note(_, systemImage, tone) = entry else {
                #expect(Bool(false), "the risk warning is not a note entry")
                continue
            }
            #expect(systemImage != nil, "the warning note lost its icon")
            #expect(tone == .warning)
        }
    }

    @MainActor
    @Test("Risk Notes Stay With Custom Fields")
    func riskNotesStayWithCustomFields() {
        let tiers = ["privacy_impacting", "cost_impacting"]

        #expect(ModelControlCapabilityFooter.entries(
            .init(context: .panelCard, overridden: false, riskTiers: tiers)
        ).isEmpty)

        let overridden = ModelControlCapabilityFooter.entries(
            .init(context: .panelCard, overridden: true, riskTiers: tiers)
        )
        #expect(overridden.count == 3, "when custom fields are in effect: the takeover note plus two risk warnings")

        #expect(ModelControlCapabilityFooter.entries(
            .init(context: .behaviorPageHeader, overridden: false, riskTiers: tiers)
        ).count == 2)
    }

    @MainActor
    @Test("Overridden State Keeps Its Only Way Back")
    func overriddenStateKeepsItsOnlyWayBack() {
        let entries = ModelControlCapabilityFooter.entries(.init(
            overridden: true,
            isConfigurable: false,
            statusText: "This capability is unavailable",
            showsSupportedModelsAction: true,
            hasSupportedModelCandidates: true,
            showsAdvancedSettingsAction: true
        ))
        #expect(entries.count == 2)
        #expect(entries.last == .advancedSettingsLink)
        #expect(!entries.contains(.supportedModelsLink), "while custom fields are in effect the user should not be told to switch model")
    }

    @Test("Stale Web Gate Is Wired Everywhere")
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

    @MainActor
    @Test("Footer Yields To The Status Row Escape")
    func footerYieldsToTheStatusRowEscape() {
        let base = ModelControlCapabilityFooter.Input(
            context: .panelCard,
            isConfigurable: false,
            statusText: "This capability is unavailable",
            showsSupportedModelsAction: true,
            hasSupportedModelCandidates: true
        )
        var covered = base
        covered.statusRowEscape = .supportedModels
        #expect(
            !ModelControlCapabilityFooter.entries(covered).contains(.supportedModelsLink),
            "the same way out appears twice on one card"
        )

        var elsewhere = base
        elsewhere.statusRowEscape = .advancedSettings
        #expect(ModelControlCapabilityFooter.entries(elsewhere).contains(.supportedModelsLink))
        var pageHeader = base
        pageHeader.context = .behaviorPageHeader
        #expect(ModelControlCapabilityFooter.entries(pageHeader).contains(.supportedModelsLink))
    }

    @Test("Panel Card Keeps Its Supported Models Link And Says One Thing")
    func panelCardKeepsItsSupportedModelsLinkAndSaysOneThing() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        #expect(sheet.contains("let showsSupportedModels = showsSupportedModelsAction(for: status, capability: capability)"))
        #expect(
            !sheet.contains("let showsSupportedModels = context == .behaviorPageHeader"),
            "the supported-models link is confined to the advanced settings page header again"
        )
        #expect(
            !sheet.contains("if let readOnlyStatus = editability.statusText { return readOnlyStatus }"),
            "the advanced settings row prints not-ready in its trailing slot again, contradicting the banner at the top of the page"
        )
    }

    @Test("Detail Pages Consume The Layout Functions")
    func detailPagesConsumeTheLayoutFunctions() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        #expect(sheet.contains("ModelControlWebLayout.layout("))
        #expect(sheet.contains("ModelControlReasoningLayout.layout("))
        #expect(sheet.contains("switch layout.form {"))
        for inlined in ["$0.kind == .fixedTier", "layout.unavailableReasons", "layout.dimmedNote"] {
            #expect(!sheet.contains(inlined), "the panel inlined its own copy of the level explanation again: \(inlined)")
        }
        #expect(
            !sheet.contains("“Every time” needs an official recipe"),
            "explaining a greyed-out level that no longer exists is pure noise"
        )
    }

    @Test("Toggle Lives Inside The Title Row")
    func toggleLivesInsideTheTitleRow() throws {
        let components = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsComponents.swift",
        ])
        let cardStart = try #require(components.range(of: "struct ModelControlCard<Content: View>: View {"))
        let rest = components[cardStart.lowerBound...]
        let card = String(rest[..<(rest.range(of: "// MARK:")?.lowerBound ?? rest.endIndex)])

        let header = try #require(card.range(of: "HStack(spacing: 10) {"))
        let spacer = try #require(card.range(of: "Spacer(minLength: 8)", range: header.upperBound..<card.endIndex))
        let toggle = try #require(card.range(of: "Toggle(\"\", isOn: toggle)", range: spacer.upperBound..<card.endIndex))
        let subtitle = try #require(card.range(of: "if !subtitle.isEmpty {", range: header.upperBound..<card.endIndex))
        let content = try #require(card.range(of: "content()", range: header.upperBound..<card.endIndex))
        #expect(toggle.lowerBound < subtitle.lowerBound, "the switch moved out of the title row, below the subtitle")
        #expect(toggle.lowerBound < content.lowerBound, "the switch moved into the body of the card")

        #expect(
            !card.contains("HStack(alignment: .firstTextBaseline, spacing: 10)"),
            "the title row aligns on the text baseline again, which pushes the toggle off the title line"
        )
        #expect(card.contains(".frame(minHeight: 44)"))
        #expect(card.contains(".accessibilityLabel(Text(title))"))
        #expect(card.contains("} else if let badge {"), "a switch and a badge can coexist again")
    }

    @Test("Disabled State Changes Color Instead Of Opacity")
    func disabledStateChangesColorInsteadOfOpacity() throws {
        let components = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsComponents.swift",
        ])
        let start = try #require(components.range(of: "struct ModelControlSegmentedPicker"))
        let rest = components[start.lowerBound...]
        let segment = String(rest[..<(rest.range(of: "// MARK:")?.lowerBound ?? rest.endIndex)])
        #expect(segment.contains("private func foreground("), "the scope was not narrowed to the colour function, so this assertion has no subject")
        #expect(segment.contains("OriveoTheme.Palette.textDisabledOnControl"), "the disabled state does not switch colour")
        #expect(
            !segment.contains(".opacity(0.5)") && !segment.contains(".opacity(0.6)"),
            "disabled is expressed with a whole-layer opacity again, which makes the text unreadable along with it"
        )
    }

    @Test("Segmented Respects Reduce Motion")
    func segmentedRespectsReduceMotion() throws {
        let components = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsComponents.swift",
        ])
        let animated = components
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//")
                    && trimmed.contains(".animation(")
                    && trimmed.contains("value: selection")
            }
        #expect(animated.count >= 2, "the selection animation of the level picker is gone, so this assertion has no subject")
        for line in animated {
            #expect(
                line.contains("reduceMotion ?"),
                "the level animation does not honour Reduce Motion: \(line.trimmingCharacters(in: .whitespaces))"
            )
        }
    }

    @Test("Push Transition Respects Reduce Motion")
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
