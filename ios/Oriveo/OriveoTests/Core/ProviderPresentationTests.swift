import Foundation
import Testing
@testable import Oriveo

@Suite("Provider Presentation", .serialized)
struct ProviderPresentationTests {
    private func loadXCStrings(tableName: String) throws -> [String: Any] {
        let testFile = URL(fileURLWithPath: #file)
        let oriveoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let xcstringsURL = oriveoRoot
            .appendingPathComponent("Oriveo")
            .appendingPathComponent("\(tableName).xcstrings")

        let data = try Data(contentsOf: xcstringsURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return json["strings"] as! [String: Any]
    }

    private var allLanguageIDs: [String] {
        ["ar", "de", "en", "es", "fr", "ja", "ko", "pt-BR", "zh-Hans", "zh-Hant", "hi", "id", "vi", "th", "tr", "ru"]
    }

    private func localizedString(_ key: String, tableName: String, language: AppLanguage) throws -> String {
        let path = try #require(Bundle.main.path(forResource: language.rawValue, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        return bundle.localizedString(forKey: key, value: key, table: tableName)
    }

    @Test("Zhipu Display Name Uses ZAIBranding")
    func zhipuDisplayNameUsesZAIBranding() {
        #expect(ProviderKind.zhipu.displayName == "Z.ai")
        #expect(ProviderKind.zhipu.shortName == "Z.ai")
    }

    @Test("Unverified Connection Issue Uses Providers Localization")
    func unverifiedConnectionIssueUsesProvidersLocalization() throws {
        let key = ProviderIssueMessage.unverifiedConnectionKey
        let zhHans = try localizedString(key, tableName: "Providers", language: .chineseSimplified)
        #expect(!zhHans.isEmpty)
        #expect(zhHans != key)
        #expect(ProviderIssueMessage.localized(key) == L10n.tr(key, table: .providers))
        #expect(ProviderIssueMessage.localized("The request did not complete successfully. Please check your network and try again.") == L10n.tr("The request did not complete successfully. Please check your network and try again."))
    }

    @Test("Relay Catalog Presentation Uses Canonical Failure Key")
    func relayCatalogPresentationUsesCanonicalFailureKey() {
        let connectionIssue = TestFactories.makeProvider(
            kind: .relay,
            status: .issue(ProviderIssueMessage.unverifiedConnectionKey),
            models: [TestFactories.makeModel(id: "kept", isDefault: true)],
            lastError: ProviderIssueMessage.unverifiedConnectionKey
        )
        #expect(RelayCatalogPresentationState.resolve(for: connectionIssue, isRefreshing: false) == .content)

        let catalogIssue = TestFactories.makeProvider(
            kind: .relay,
            status: .connected,
            models: [TestFactories.makeModel(id: "kept", isDefault: true)],
            lastError: ProviderIssueMessage.catalogUnavailableKey
        )
        #expect(RelayCatalogPresentationState.resolve(for: catalogIssue, isRefreshing: false) == .failed)

        let connected = TestFactories.makeProvider(kind: .relay, status: .connected)
        #expect(RelayCatalogPresentationState.resolve(for: connected, isRefreshing: true) == .loading)
        #expect(connected.status == .connected)
    }

    @Test("Relay Catalog Membership Is Conservative")
    func relayCatalogMembershipIsConservative() {
        let retained = TestFactories.makeModel(id: "removed-upstream")
        let confirmedCatalog = TestFactories.makeProvider(
            kind: .relay,
            models: [retained],
            catalogModels: [TestFactories.makeModel(id: "still-listed")]
        )
        #expect(RelayCatalogMembership.isMissingEnabledModel(retained, from: confirmedCatalog))

        let manual = TestFactories.makeModel(id: "manual", isManual: true)
        #expect(!RelayCatalogMembership.isMissingEnabledModel(manual, from: confirmedCatalog))

        let noCatalogEvidence = TestFactories.makeProvider(kind: .relay, models: [retained])
        #expect(!RelayCatalogMembership.isMissingEnabledModel(retained, from: noCatalogEvidence))
    }

    @Test("the relay catalog index agrees with the linear scan: case, canonical id, shared name, manual, unavailable catalog")
    @MainActor
    func relayCatalogMembershipIndexMatchesLinearScan() {
        var canonical = TestFactories.makeModel(id: "snapshot-2026-01", name: "Canonical Named")
        canonical.canonicalModelId = "Vendor/Canonical"
        let catalog = [
            TestFactories.makeModel(id: "GPT-Listed", name: "Listed Model"),
            canonical,
            TestFactories.makeModel(id: "other-id", name: "Shared Display Name"),
            TestFactories.makeModel(id: "ÉCOLE-model", name: "École"),
        ]
        var enabledCanonical = TestFactories.makeModel(id: "different-snapshot", name: "whatever")
        enabledCanonical.canonicalModelId = "vendor/canonical"
        let enabled = [
            TestFactories.makeModel(id: "gpt-listed"),
            enabledCanonical,
            TestFactories.makeModel(id: "renamed-id", name: "shared display name"),
            TestFactories.makeModel(id: "école-model"),
            TestFactories.makeModel(id: "gone-upstream", name: "Gone"),
            TestFactories.makeModel(id: "manual-only", isManual: true),
        ]

        let providers = [
            TestFactories.makeProvider(kind: .relay, models: enabled, catalogModels: catalog),
            TestFactories.makeProvider(
                kind: .relay,
                models: enabled,
                catalogModels: catalog,
                lastError: ProviderIssueMessage.catalogUnavailableKey
            ),
            TestFactories.makeProvider(kind: .relay, models: enabled),
            TestFactories.makeProvider(kind: .openRouter, models: enabled, catalogModels: catalog),
        ]
        for provider in providers {
            let index = RelayCatalogMembership.Index(provider: provider)
            for model in enabled {
                #expect(
                    index.isMissingEnabledModel(model)
                        == RelayCatalogMembership.isMissingEnabledModel(model, from: provider),
                    "\(provider.kind.rawValue) / \(model.id)"
                )
            }
        }
        let active = RelayCatalogMembership.Index(provider: providers[0])
        #expect(active.isMissingEnabledModel(enabled[4]))
        #expect(!active.isMissingEnabledModel(enabled[2]))
    }

    @Test("enabled model rows compare by rendering inputs: different closures are equal, model, highlight and catalog state are not")
    @MainActor
    func enabledModelRowEqualityIgnoresClosures() {
        let model = TestFactories.makeModel(id: "row-model", capabilities: [.text, .web])
        let provider = TestFactories.makeProvider(kind: .openAI, models: [model])
        func row(
            model: AIModel = model,
            provider: Provider = provider,
            highlighted: Bool = false,
            missing: Bool = false,
            action: @escaping () -> Void = {}
        ) -> ProviderEnabledModelRow {
            ProviderEnabledModelRow(
                model: model,
                provider: provider,
                capabilityEvidenceRevision: 1,
                isHighlighted: highlighted,
                isMissingFromCatalog: missing,
                isLast: true,
                canSetDefault: true,
                canRemove: false,
                setDefaultAction: action,
                chatAction: action,
                removeAction: action
            )
        }

        #expect(row(action: {}) == row(action: { _ = 1 }))
        #expect(row() != row(highlighted: true))
        #expect(row() != row(missing: true))
        var renamed = model
        renamed.name = "Renamed"
        #expect(row() != row(model: renamed))
        var erroredProvider = provider
        erroredProvider.lastError = "boom"
        #expect(row() != row(provider: erroredProvider))
    }

    @Test("Official Provider Display Name Uses Custom Name")
    func officialProviderDisplayNameUsesCustomName() {
        let provider = Provider(
            id: UUID(),
            kind: .openRouter,
            status: .connected,
            models: [],
            catalogModels: [],
            lastCheckedAt: nil,
            apiKey: "",
            apiKeyPreview: "",
            lastError: nil,
            baseURLText: nil,
            customName: "OpenRouter 2"
        )

        #expect(provider.displayName == "OpenRouter 2")
    }

    @Test("Provider Detail Last Checked Label Is Localized")
    func providerDetailLastCheckedLabelIsLocalized() throws {
        #expect(try localizedString("Last Checked", tableName: "Localizable", language: .chineseSimplified) != "Last Checked")
    }

    @Test("Provider Delete Dialog Message Is In Localization Catalog")
    func providerDeleteDialogMessageIsInLocalizationCatalog() throws {
        let strings = try loadXCStrings(tableName: "Providers")
        let key = "This will remove the provider and its model settings."

        guard let entry = strings[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any] else {
            Issue.record("Key \"\(key)\" not found in Providers.xcstrings")
            return
        }

        for lang in allLanguageIDs {
            guard let langEntry = localizations[lang] as? [String: Any],
                  let stringUnit = langEntry["stringUnit"] as? [String: Any],
                  let value = stringUnit["value"] as? String,
                  !value.isEmpty else {
                Issue.record("Key \"\(key)\" missing translation for \"\(lang)\"")
                continue
            }

            if lang == "zh-Hans" {
                #expect(value != key)
            }
        }
    }

}
