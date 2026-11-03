import Foundation
import Testing
@testable import Oriveo

/// Provider detail "realtime voice" section: same source as the picker; no rows means the section is hidden; not counted in the header count,
/// chat button selects it as the home realtime connection and switches the home tab.
@Suite("Provider detail realtime section")
struct ProviderDetailRealtimeSectionTests {

    private static func realtimeCatalog() -> VoiceCatalog {
        func entry(_ model: String, isDefault: Bool) -> VoiceRealtimeEntry {
            VoiceRealtimeEntry(
                model: model,
                transport: .openaiRealtime,
                path: "/v1/realtime",
                contextWindow: 128_000,
                voices: [VoiceCatalogVoice(id: "marin", isDefault: true)],
                maxSessionSec: nil,
                inputTranscriptionModel: nil,
                isDefault: isDefault
            )
        }
        let openAI = [entry("gpt-realtime-mini", isDefault: false), entry("gpt-realtime", isDefault: true)]
        // Relay, hosted and free-tier connections also get rows: omission is decided by the auth form, not by a missing catalog entry.
        return VoiceCatalog(schemaVersion: 2, revision: "detail", providers: [
            .openAI: VoiceProviderEntries(realtime: openAI),
            .relay: VoiceProviderEntries(realtime: openAI),
        ])
    }

    @Test("Official apiKey connection: section rows are the realtime models from the same source as the picker (isDefault first)")
    func realtimeSectionListsCatalogRowsForOfficialAPIKey() {
        let provider = TestFactories.makeProvider(kind: .openAI, models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)])
        let catalog = Self.realtimeCatalog()

        let rows = ProviderRealtimeModelsSection.rows(for: provider, catalog: catalog)
        let picker = modelPickerRealtimeModels(context: .home, providers: [provider], catalog: catalog)

        #expect(rows == ["gpt-realtime", "gpt-realtime-mini"])
        #expect(rows == picker.byProvider[provider.id])
        #expect(ProviderRealtimeModelsSection.rows(for: provider, catalog: nil).isEmpty)
    }

    @Test("Relay, hosted or free-tier connection: no rows, section hidden")
    func realtimeSectionAbsentForRelayManagedFree() {
        let catalog = Self.realtimeCatalog()
        for kind in [ProviderKind.relay] {
            let provider = TestFactories.makeProvider(kind: kind, models: [TestFactories.makeModel(id: "m", isDefault: true)])
            #expect(ProviderRealtimeModelsSection.rows(for: provider, catalog: catalog).isEmpty, "\(kind)")
        }
    }

    @Test("Header model count excludes realtime rows: still enabledModelCount; the detail header source does not read the realtime section")
    func heroCountExcludesRealtimeRows() throws {
        let provider = TestFactories.makeProvider(kind: .openAI, models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)])
        let rows = ProviderRealtimeModelsSection.rows(for: provider, catalog: Self.realtimeCatalog())
        #expect(rows.count == 2)
        #expect(provider.enabledModelCount == 1)

        let summaryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Oriveo/Features/Providers/ProviderSummaryCard.swift")
        let summarySource = try String(contentsOf: summaryURL, encoding: .utf8)
        #expect(!summarySource.contains("ProviderRealtimeModelsSection"))
        #expect(!summarySource.contains("modelPickerRealtimeModels"))
    }

    @Test("Row-end chat button: consented → selects home realtime and switches the home tab, does not write lastUsed; not consented → inform first, select after consent", .sharedProcessState)
    @MainActor
    func realtimeRowChatSelectsHomeRealtime() {
        let suiteName = "ProviderDetailRealtimeSectionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let disclosures = VoiceDisclosureStore(defaults: defaults)

        let state = AppState(seedDemoData: true)
        let provider = TestFactories.makeProvider(kind: .openAI, models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)])
        state.providers = [provider]
        let catalog = Self.realtimeCatalog()
        state.realtimeVoiceCatalog = { catalog }
        state.selectedTab = .providers
        let lastUsedBefore = state.lastUsedModelRef
        let expected = RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime")

        // Not consented: only the notice is required; selection and tab stay unchanged.
        let first = ProviderRealtimeModelsSection.startRealtimeChat(
            providerID: provider.id, model: "gpt-realtime", appState: state, disclosures: disclosures
        )
        #expect(first == .needsDisclosure(expected))
        #expect(state.realtimeModelSelection(for: nil) == nil)
        #expect(state.selectedTab == .providers)

        // Declined: unchanged.
        let request = RealtimeModelDisclosureRequest(selection: expected, conversationID: nil)
        #expect(!ProviderRealtimeModelsSection.resolveDisclosure(request, accepted: false, appState: state, disclosures: disclosures))
        #expect(state.realtimeModelSelection(for: nil) == nil)
        #expect(state.selectedTab == .providers)

        // Consented: takes effect and switches the home tab.
        #expect(ProviderRealtimeModelsSection.resolveDisclosure(request, accepted: true, appState: state, disclosures: disclosures))
        #expect(state.realtimeModelSelection(for: nil) == expected)
        #expect(state.selectedTab == .home)

        // Tapped again after consent: takes effect directly.
        state.selectedTab = .providers
        let second = ProviderRealtimeModelsSection.startRealtimeChat(
            providerID: provider.id, model: "gpt-realtime-mini", appState: state, disclosures: disclosures
        )
        let mini = RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime-mini")
        #expect(second == .applied(mini))
        #expect(state.realtimeModelSelection(for: nil) == mini)
        #expect(state.selectedTab == .home)
        #expect(state.lastUsedModelRef == lastUsedBefore)
    }

    @Test("regular width: chat button (takes effect directly, or notice and consent) switches the home tab and pops the stack to the home root view, same as presentChat", .sharedProcessState)
    @MainActor
    func realtimeRowChatPopsToRootInRegularWidth() {
        let suiteName = "ProviderDetailRealtimeSectionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let disclosures = VoiceDisclosureStore(defaults: defaults)

        let state = AppState(seedDemoData: true)
        let provider = TestFactories.makeProvider(kind: .openAI, models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)])
        state.providers = [provider]
        let catalog = Self.realtimeCatalog()
        state.realtimeVoiceCatalog = { catalog }
        state.navigation.updateLayoutWidth(isRegular: true)
        state.selectedTab = .providers
        state.navigation.path = [.providerDetail(providerID: provider.id)]

        // The notice-and-consent branch.
        let selection = RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime")
        #expect(ProviderRealtimeModelsSection.startRealtimeChat(
            providerID: provider.id, model: "gpt-realtime", appState: state, disclosures: disclosures
        ) == .needsDisclosure(selection))
        #expect(state.navigation.path == [.providerDetail(providerID: provider.id)])
        let request = RealtimeModelDisclosureRequest(selection: selection, conversationID: nil)
        #expect(ProviderRealtimeModelsSection.resolveDisclosure(request, accepted: true, appState: state, disclosures: disclosures))
        #expect(state.selectedTab == .home)
        #expect(state.navigation.path.isEmpty)

        // The already-consented branch, which takes effect directly.
        state.selectedTab = .providers
        state.navigation.path = [.providerDetail(providerID: provider.id)]
        let outcome = ProviderRealtimeModelsSection.startRealtimeChat(
            providerID: provider.id, model: "gpt-realtime-mini", appState: state, disclosures: disclosures
        )
        #expect(outcome == .applied(RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime-mini")))
        #expect(state.selectedTab == .home)
        #expect(state.navigation.path.isEmpty)
    }

    @Test("Detail realtime row checkmark = home realtime selection (connection and model): other connections and other models have no checkmark; the row-end checkmark sits left of the chat button", .sharedProcessState)
    @MainActor
    func row_checked_equals_home_selection() throws {
        let suiteName = "ProviderDetailRealtimeSectionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let disclosures = VoiceDisclosureStore(defaults: defaults)

        let state = AppState(seedDemoData: true)
        let first = TestFactories.makeProvider(kind: .openAI, models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)])
        let second = TestFactories.makeProvider(kind: .openAI, models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)])
        state.providers = [first, second]
        let catalog = Self.realtimeCatalog()
        state.realtimeVoiceCatalog = { catalog }
        #expect(ProviderRealtimeModelsSection.checkedModel(for: first, appState: state) == nil)

        let selection = RealtimeModelSelection(providerID: first.id, providerKind: .openAI, model: "gpt-realtime-mini")
        let request = RealtimeModelDisclosureRequest(selection: selection, conversationID: nil)
        #expect(ProviderRealtimeModelsSection.resolveDisclosure(request, accepted: true, appState: state, disclosures: disclosures))
        #expect(state.realtimeModelSelection(for: nil) == selection)

        #expect(ProviderRealtimeModelsSection.checkedModel(for: first, appState: state) == "gpt-realtime-mini")
        #expect(ProviderRealtimeModelsSection.checkedModel(for: second, appState: state) == nil)

        // Home switched to another connection: the original connection's checkmark disappears.
        #expect(ProviderRealtimeModelsSection.startRealtimeChat(
            providerID: second.id, model: "gpt-realtime", appState: state, disclosures: disclosures
        ) == .applied(RealtimeModelSelection(providerID: second.id, providerKind: .openAI, model: "gpt-realtime")))
        #expect(ProviderRealtimeModelsSection.checkedModel(for: first, appState: state) == nil)
        #expect(ProviderRealtimeModelsSection.checkedModel(for: second, appState: state) == "gpt-realtime")

        // Row end: the same checkmark sits left of the chat button.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Oriveo/Features/Providers/ProviderRealtimeModelsSection.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let rowStart = try #require(source.range(of: "struct ProviderRealtimeModelRow"))
        let rowSource = source[rowStart.lowerBound...]
        let check = try #require(rowSource.range(of: "Image(systemName: \"checkmark.circle.fill\")"))
        let chat = try #require(rowSource.range(of: "provider_detail_realtime_model_chat_button"))
        #expect(check.lowerBound < chat.lowerBound)
        #expect(rowSource.contains(".foregroundStyle(OriveoTheme.V2.Colors.primary)"))
    }

    @Test("Cold start has no checkmark: the home realtime selection lives in memory only, so the new process's detail realtime rows are all unchecked", .sharedProcessState)
    @MainActor
    func row_unchecked_after_cold_start() {
        let provider = TestFactories.makeProvider(kind: .openAI, models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)])
        let catalog = Self.realtimeCatalog()
        let state = AppState(seedDemoData: true)
        state.providers = [provider]
        state.realtimeVoiceCatalog = { catalog }

        #expect(ProviderRealtimeModelsSection.rows(for: provider, catalog: catalog) == ["gpt-realtime", "gpt-realtime-mini"])
        #expect(state.realtimeModelSelection(for: nil) == nil)
        #expect(ProviderRealtimeModelsSection.checkedModel(for: provider, appState: state) == nil)
    }

    @Test("Settings > voice realtime row and provider detail realtime row: titles at most two lines, same as the picker realtime row")
    func realtime_titles_limit_two_lines() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(
            contentsOf: root.appendingPathComponent("Oriveo/Features/Settings/VoiceSettingsView.swift"), encoding: .utf8
        )
        let settingsStart = try #require(settings.range(of: "private func realtimeRow("))
        let settingsRow = settings[settingsStart.lowerBound...]
        let settingsTitle = try #require(settingsRow.range(of: "Text(ModelIdentifierBreaks.displayTitle(row.model))"))
        let settingsSubtitle = try #require(settingsRow.range(of: "Text(row.subtitle)"))
        #expect(settingsRow[settingsTitle.upperBound..<settingsSubtitle.lowerBound].contains(".lineLimit(2)"))

        let detail = try String(
            contentsOf: root.appendingPathComponent("Oriveo/Features/Providers/ProviderRealtimeModelsSection.swift"), encoding: .utf8
        )
        let detailStart = try #require(detail.range(of: "struct ProviderRealtimeModelRow"))
        let detailRow = detail[detailStart.lowerBound...]
        let detailTitle = try #require(detailRow.range(of: "Text(ModelIdentifierBreaks.displayTitle(model))"))
        let detailSubtitle = try #require(detailRow.range(of: "Text(L10n.tr(\"Realtime voice · Interrupt anytime\""))
        #expect(detailRow[detailTitle.upperBound..<detailSubtitle.lowerBound].contains(".lineLimit(2)"))
    }
}
