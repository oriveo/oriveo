import Foundation
import Testing
@testable import Oriveo

/// Custom services: reads the original shared/search-contracts/custom-service.v1.json and compares each case against expect;
/// entries that are "same as X" take search_catalog_contract.v1.json#catalog.
@Suite("External search custom service contract")
struct SearchCustomServiceContractTests {
    private static let fixturePath = "shared/search-contracts/custom-service.v1.json"

    private static func fixture() throws -> SearchJSON {
        try SearchContractSupport.load(fixturePath)
    }

    private static func catalog() throws -> SearchJSON {
        try #require(try SearchContractSupport.load("shared/search-contracts/search_catalog_contract.v1.json")["catalog"])
    }

    private static func cases(_ name: String, in fixture: SearchJSON) throws -> [SearchJSON] {
        let cases = try #require(fixture[name]?.arrayValue)
        #expect(!cases.isEmpty)
        return cases
    }

    /// Take the mapping by protocol: searxng = built into the client; manual = user mapping; same_as = the preset mapping snapshotted at save time.
    private static func spec(for input: SearchJSON) throws -> SearchJSON {
        switch input["protocol"]?.stringValue {
        case "searxng":
            return SearchTransport.searxngSpec
        case "manual":
            return try #require(input["manual"])
        case "same_as":
            let entry = try #require(SearchContractSupport.service(input["presetId"]?.stringValue ?? "", in: try catalog()))
            return SearchTransport.snapshotPresetMapping(entry, regionId: input["regionId"]?.stringValue)
        default:
            throw ContractError.unknownProtocol
        }
    }

    private enum ContractError: Error { case unknownProtocol }

    @Test("Built-in constants match the fixture: protocol table, SearXNG mapping, custom service timeout")
    func constantsMatchFixture() throws {
        let constants = try #require(try Self.fixture()["constants"])
        #expect(constants["protocols"] == .array(SearchTransport.customProtocols.map(SearchJSON.string)))
        #expect(constants["searxng"] == SearchTransport.searxngSpec)
        #expect(constants["timeoutSec"]?.safeIntegerValue == SearchTransport.customTimeoutSec)
        #expect(SearchTransport.customTimeoutSec <= SearchHardLimits.maxTimeoutSec)
        #expect(constants["webAllowedPorts"] == .array(SearchTransport.webAllowedPorts.map { .int(Int64($0)) }))
    }

    @Test("Form validation matches validateCases")
    func SRCH_CUS_01_validateCases() throws {
        for testCase in try Self.cases("validateCases", in: try Self.fixture()) {
            let caseID = testCase["caseId"]?.stringValue ?? "?"
            let input = try #require(testCase["input"])
            let platform = try #require(SearchClientPlatform(rawValue: input["platform"]?.stringValue ?? ""))
            let result = SearchTransport.validateCustomSearchService(CustomSearchServiceInput(
                name: input["name"]?.stringValue,
                address: input["address"]?.stringValue,
                protocolID: input["protocol"]?.stringValue,
                platform: platform,
                addressClass: input["addressClass"]?.stringValue.flatMap(SearchAddressClass.init(rawValue:)),
                presetID: input["presetId"]?.stringValue,
                catalogAvailable: input["catalogAvailable"]?.boolValue,
                presetActive: input["presetActive"]?.boolValue,
                manual: input["manual"]
            ))
            let mismatched = SearchContractSupport.mismatchedKeys(
                actual: try SearchContractSupport.json(result), expect: try #require(testCase["expect"])
            )
            #expect(mismatched.isEmpty, "\(caseID): \(mismatched) \(result)")
        }
    }

    @Test("Key binding source matches bindingCases: a path change does not clear it, a source change always clears it")
    func SRCH_CUS_02_bindingCases() throws {
        for testCase in try Self.cases("bindingCases", in: try Self.fixture()) {
            let caseID = testCase["caseId"]?.stringValue ?? "?"
            let old = testCase["input"]?["old"]?.stringValue
            let next = testCase["input"]?["next"]?.stringValue
            #expect(SearchTransport.keyBindingOrigin(old) == testCase["expect"]?["oldOrigin"]?.stringValue, "\(caseID)")
            #expect(SearchTransport.keyBindingOrigin(next) == testCase["expect"]?["nextOrigin"]?.stringValue, "\(caseID)")
            #expect(SearchTransport.addressChangeClearsKey(old, next) == testCase["expect"]?["clearsKey"]?.boolValue, "\(caseID)")
        }
    }

    @Test("The \"same as X\" snapshot matches snapshotCases")
    func SRCH_CUS_03_snapshotCases() throws {
        let catalog = try Self.catalog()
        for testCase in try Self.cases("snapshotCases", in: try Self.fixture()) {
            let caseID = testCase["caseId"]?.stringValue ?? "?"
            let entry = try #require(SearchContractSupport.service(testCase["input"]?["serviceId"]?.stringValue ?? "", in: catalog))
            let snapshot = SearchTransport.snapshotPresetMapping(entry, regionId: testCase["input"]?["regionId"]?.stringValue)
            #expect(snapshot == testCase["expect"], "\(caseID): \(snapshot.encodedString())")
        }
    }

    @Test("Custom service requests match requestCases")
    func SRCH_CUS_04_requestCases() throws {
        for testCase in try Self.cases("requestCases", in: try Self.fixture()) {
            let caseID = testCase["caseId"]?.stringValue ?? "?"
            let input = try #require(testCase["input"])
            let address = try #require(SearchTransport.parseServiceAddress(input["address"]?.stringValue), "\(caseID)")
            let isSearxng = input["protocol"]?.stringValue == "searxng"
            let target = SearchRequestTarget(
                scheme: address.scheme,
                host: address.host,
                port: address.port,
                path: isSearxng ? SearchTransport.searxngPath(address.path) : (address.path.isEmpty ? "/" : address.path),
                staticParams: nil
            )
            let request = SearchTransport.buildSearchRequest(
                try Self.spec(for: input),
                target: target,
                query: input["query"]?.stringValue ?? "",
                count: input["count"]?.safeIntegerValue,
                key: input["key"]?.stringValue
            )
            let problems = SearchContractSupport.buildMismatches(request, expect: try #require(testCase["expect"]))
            #expect(problems.isEmpty, "\(caseID): \(problems)")
        }
    }

    @Test("Custom service response mapping matches responseCases")
    func SRCH_CUS_05_responseCases() throws {
        for testCase in try Self.cases("responseCases", in: try Self.fixture()) {
            let caseID = testCase["caseId"]?.stringValue ?? "?"
            let input = try #require(testCase["input"])
            let outcome = SearchTransport.parseSearchResponse(
                try Self.spec(for: input), body: input["body"], count: input["count"]?.safeIntegerValue
            )
            let actual = try SearchContractSupport.json(outcome)
            #expect(actual == testCase["expect"], "\(caseID): \(actual.encodedString())")
        }
    }

    @Test("Normalization of a user-pasted key matches keyCases")
    func SRCH_CUS_07_keyCases() throws {
        for testCase in try Self.cases("keyCases", in: try Self.fixture()) {
            let caseID = testCase["caseId"]?.stringValue ?? "?"
            let result = SearchTransport.normalizeSearchKey(testCase["input"]?["raw"]?.stringValue)
            let mismatched = SearchContractSupport.mismatchedKeys(
                actual: try SearchContractSupport.json(result), expect: try #require(testCase["expect"])
            )
            #expect(mismatched.isEmpty, "\(caseID): \(mismatched)")
        }
    }

    @Test("Which kinds of services stay or go when the catalog is unavailable matches catalogUnavailableCases")
    func SRCH_CUS_06_catalogUnavailableCases() throws {
        for testCase in try Self.cases("catalogUnavailableCases", in: try Self.fixture()) {
            let caseID = testCase["caseId"]?.stringValue ?? "?"
            let input = try #require(testCase["input"])
            let behavior = SearchTransport.catalogOutageBehavior(
                protocolID: input["protocol"]?.stringValue ?? "",
                saved: input["saved"]?.boolValue == true,
                catalogAvailable: input["catalogAvailable"]?.boolValue == true
            )
            let mismatched = SearchContractSupport.mismatchedKeys(
                actual: try SearchContractSupport.json(behavior), expect: try #require(testCase["expect"])
            )
            #expect(mismatched.isEmpty, "\(caseID): \(mismatched)")
        }
    }
}
