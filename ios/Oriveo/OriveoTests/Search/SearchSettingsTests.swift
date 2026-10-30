import Foundation
import Testing
@testable import Oriveo

/// Settings page UI semantics (external search services contract): reads shared/search-contracts/search-settings.v1.json and compares each case against expect;
/// entries reference catalog.services of shared/search-contracts/search_catalog_contract.v1.json by serviceId.
@Suite("External search settings page semantics (add sheet, price, row status, default, consent sentence, test result, form hints)")
struct SearchSettingsTests {
    private static let settingsPath = "shared/search-contracts/search-settings.v1.json"
    private static let catalogContractPath = "shared/search-contracts/search_catalog_contract.v1.json"

    private static func fixture() throws -> SearchJSON {
        try SearchContractSupport.load(settingsPath)
    }

    private static func catalog() throws -> SearchJSON {
        try #require(try SearchContractSupport.load(catalogContractPath)["catalog"])
    }

    private static func cases(_ key: String, in fixture: SearchJSON) throws -> [SearchJSON] {
        let cases = try #require(fixture[key]?.arrayValue, "fixture missing \(key)")
        #expect(!cases.isEmpty, "\(key) is empty")
        return cases
    }

    private static func connections(_ value: SearchJSON?) -> [SearchSettingsConnection] {
        (value?.arrayValue ?? []).map {
            SearchSettingsConnection(
                id: $0["id"]?.stringValue ?? "",
                name: $0["name"]?.stringValue ?? "",
                providerKind: $0["providerKind"]?.stringValue,
                baseUrl: $0["baseUrl"]?.stringValue
            )
        }
    }

    private static func check<T: Encodable>(_ actual: T, _ testCase: SearchJSON) throws {
        let caseID = testCase["caseId"]?.stringValue ?? "?"
        let expect = try #require(testCase["expect"], "\(caseID) missing expect")
        let json = try SearchContractSupport.json(actual)
        #expect(SearchContractSupport.mismatchedKeys(actual: json, expect: expect).isEmpty, "\(caseID): \(json.encodedString())")
    }

    @Test("Add sheet grouping matches addSheetCases")
    func SRCH_SET_01_addSheetCases() throws {
        let catalog = try Self.catalog()
        for testCase in try Self.cases("addSheetCases", in: try Self.fixture()) {
            let input = try #require(testCase["input"])
            let entries = (input["serviceIds"]?.arrayValue ?? []).compactMap {
                SearchContractSupport.service($0.stringValue ?? "", in: catalog)
            }
            #expect(entries.count == input["serviceIds"]?.arrayValue?.count, "\(testCase["caseId"]?.stringValue ?? "?") entries missing")
            let services = (input["services"]?.arrayValue ?? []).map {
                SearchSettingsServiceRef(
                    id: $0["id"]?.stringValue ?? "",
                    kind: SearchSettingsKind(rawValue: $0["kind"]?.stringValue ?? "") ?? .custom,
                    serviceId: $0["serviceId"]?.stringValue
                )
            }
            let sheet = SearchSettings.searchAddSheetSections(
                catalogAvailable: input["catalogAvailable"]?.boolValue == true,
                entries: entries,
                connections: Self.connections(input["connections"]),
                services: services
            )
            try Self.check(sheet, testCase)
        }
    }

    @Test("Price summary matches priceCases")
    func SRCH_SET_02_priceCases() throws {
        let catalog = try Self.catalog()
        for testCase in try Self.cases("priceCases", in: try Self.fixture()) {
            let input = try #require(testCase["input"])
            let entry = SearchContractSupport.service(input["serviceId"]?.stringValue ?? "", in: catalog)
            #expect(entry != nil, "\(testCase["caseId"]?.stringValue ?? "?") entry missing")
            try Self.check(SearchSettings.searchPriceSummary(entry, regionId: input["regionId"]?.stringValue), testCase)
        }
    }

    @Test("List row status matches rowCases")
    func SRCH_SET_03_rowCases() throws {
        let catalog = try Self.catalog()
        for testCase in try Self.cases("rowCases", in: try Self.fixture()) {
            let input = try #require(testCase["input"])
            let service = try #require(input["service"])
            let row = SearchRowServiceInput(
                kind: try #require(SearchSettingsKind(rawValue: service["kind"]?.stringValue ?? "")),
                serviceId: service["serviceId"]?.stringValue,
                regionId: service["regionId"]?.stringValue,
                boundHost: service["boundHost"]?.stringValue,
                keySource: try #require(SearchServiceKeySource(rawValue: service["keySource"]?.stringValue ?? "")),
                connectionRef: service["connectionRef"]?.stringValue,
                hasKey: service["hasKey"]?.boolValue == true
            )
            let entry = service["serviceId"]?.stringValue.flatMap { SearchContractSupport.service($0, in: catalog) }
            let state = SearchSettings.searchServiceRowState(
                service: row,
                catalogAvailable: input["catalogAvailable"]?.boolValue == true,
                entry: entry,
                withdrawn: input["withdrawn"]?.boolValue == true,
                connections: Self.connections(input["connections"])
            )
            try Self.check(state, testCase)
        }
    }

    @Test("Default service matches defaultCases")
    func SRCH_SET_04_defaultCases() throws {
        for testCase in try Self.cases("defaultCases", in: try Self.fixture()) {
            let input = try #require(testCase["input"])
            let resolved = SearchSettings.resolveDefaultSearchService(
                serviceIds: (input["serviceIds"]?.arrayValue ?? []).compactMap(\.stringValue),
                storedDefault: input["storedDefault"]?.stringValue
            )
            #expect((resolved.map(SearchJSON.string) ?? .null) == testCase["expect"]?["defaultId"],
                    "\(testCase["caseId"]?.stringValue ?? "?")")
        }
    }

    @Test("Consent sentence matches consentCases")
    func SRCH_SET_05_consentCases() throws {
        for testCase in try Self.cases("consentCases", in: try Self.fixture()) {
            let input = try #require(testCase["input"])
            let lines = SearchSettings.searchConsentLines(
                kind: try #require(SearchSettingsKind(rawValue: input["kind"]?.stringValue ?? "")),
                platform: try #require(SearchClientPlatform(rawValue: input["platform"]?.stringValue ?? "")),
                serviceName: input["serviceName"]?.stringValue,
                host: input["host"]?.stringValue
            )
            #expect(try SearchContractSupport.json(lines) == testCase["expect"], "\(testCase["caseId"]?.stringValue ?? "?")")
        }
    }

    @Test("Test result display matches testCases")
    func SRCH_SET_06_testCases() throws {
        for testCase in try Self.cases("testCases", in: try Self.fixture()) {
            let outcome = try #require(testCase["input"]?["outcome"])
            let input: SearchTestOutcome
            if outcome["ok"]?.boolValue == true {
                input = .passed(
                    count: try #require(outcome["count"]?.safeIntegerValue),
                    latencyMs: try #require(outcome["latencyMs"]?.safeIntegerValue)
                )
            } else {
                let card = try outcome["error"]?["card"].map { try JSONDecoder().decode(SearchErrorCard.self, from: $0.encodedData()) }
                input = .failed(errorClass: outcome["error"]?["errorClass"]?.stringValue, card: card)
            }
            try Self.check(SearchSettings.searchTestPresentation(input), testCase)
        }
    }

    @Test("Form field hints match formCases")
    func SRCH_SET_07_formCases() throws {
        for testCase in try Self.cases("formCases", in: try Self.fixture()) {
            let input = try #require(testCase["input"])
            let result = try SearchSettings.customFormFieldErrors(
                errors: (input["errors"]?.arrayValue ?? []).compactMap(\.stringValue),
                warnings: (input["warnings"]?.arrayValue ?? []).compactMap(\.stringValue)
            )
            try Self.check(result, testCase)
        }
        #expect(throws: SearchSettingsError.unmappedFormError("not_a_code")) {
            try SearchSettings.customFormFieldErrors(errors: ["not_a_code"], warnings: [])
        }
    }

    @Test("Effective per-search count matches countCases")
    func SRCH_SET_08_countCases() throws {
        for testCase in try Self.cases("countCases", in: try Self.fixture()) {
            let stored = testCase["input"]?["stored"]?.safeIntegerValue
            #expect(.int(Int64(SearchSettings.searchResultCount(stored))) == testCase["expect"]?["count"],
                    "\(testCase["caseId"]?.stringValue ?? "?")")
        }
    }

    @Test("Service display name fallback matches nameCases")
    func SRCH_SET_09_nameCases() throws {
        for testCase in try Self.cases("nameCases", in: try Self.fixture()) {
            let input = try #require(testCase["input"])
            let name = SearchSettings.searchServiceDisplayName(
                kind: try #require(SearchSettingsKind(rawValue: input["kind"]?.stringValue ?? "")),
                name: input["name"]?.stringValue,
                serviceId: input["serviceId"]?.stringValue,
                catalogDisplayName: input["catalogDisplayName"]?.stringValue
            )
            #expect(.string(name) == testCase["expect"]?["name"], "\(testCase["caseId"]?.stringValue ?? "?")")
        }
    }

    @Test("Guest migration carrying the default matches migrateDefaultCases")
    func SRCH_SET_10_migrateDefaultCases() throws {
        func ids(_ value: SearchJSON?) -> [String] { (value?.arrayValue ?? []).compactMap(\.stringValue) }
        for testCase in try Self.cases("migrateDefaultCases", in: try Self.fixture()) {
            let input = try #require(testCase["input"])
            let result = SearchSettings.migratedDefaultSearchService(
                accountServiceIds: ids(input["accountServiceIds"]),
                guestServiceIds: ids(input["guestServiceIds"]),
                guestStoredDefault: input["guestStoredDefault"]?.stringValue,
                migratedIds: ids(input["migratedIds"])
            )
            try Self.check(result, testCase)
        }
    }

    @Test("Editing a custom service matches editCases")
    func SRCH_SET_11_editCases() throws {
        func side(_ value: SearchJSON?) -> SearchCustomEditSide {
            SearchCustomEditSide(
                name: value?["name"]?.stringValue,
                address: value?["address"]?.stringValue,
                protocolID: value?["protocol"]?.stringValue,
                mapping: value?["mapping"],
                presetId: value?["presetId"]?.stringValue,
                regionId: value?["regionId"]?.stringValue
            )
        }
        for testCase in try Self.cases("editCases", in: try Self.fixture()) {
            let input = try #require(testCase["input"])
            let plan = SearchSettings.customServiceEditPlan(before: side(input["before"]), after: side(input["after"]))
            try Self.check(plan, testCase)
        }
    }
}
