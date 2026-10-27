import Foundation
import Testing
@testable import Oriveo

/// Catalog search-catalog/v1 contract: reads the original shared/search-contracts/search_catalog_contract.v1.json and compares each case against expect.
@Suite("External search catalog contract (canonicalization, adoption, sites, hosts, links)")
struct SearchCatalogContractTests {
    private static let contractPath = "shared/search-contracts/search_catalog_contract.v1.json"
    private static let viewPath = "shared/search-contracts/search_catalog_view.v1.json"

    private static func contract() throws -> SearchJSON {
        try SearchContractSupport.load(contractPath)
    }

    /// The test key in the fixture is trusted only in tests.
    private static func testKeys(_ contract: SearchJSON) throws -> [String: String] {
        let keyID = try #require(contract["testKeys"]?["keyId"]?.stringValue)
        let publicKey = try #require(contract["testKeys"]?["publicKeyB64"]?.stringValue)
        return [keyID: publicKey]
    }

    private static func cases(_ name: String, in contract: SearchJSON) throws -> [SearchJSON] {
        let cases = try #require(contract[name]?.arrayValue)
        #expect(!cases.isEmpty)
        return cases
    }

    @Test("Canonical JSON matches canonicalCases byte for byte, and the fixture catalog passes signature verification with the test key")
    func SRCH_CAT_01_canonicalCases() throws {
        let contract = try Self.contract()
        for testCase in try Self.cases("canonicalCases", in: contract) {
            let caseID = testCase["caseId"]?.stringValue ?? "?"
            let input = try #require(testCase["input"])
            if let output = testCase["expect"]?["output"]?.stringValue {
                #expect(try SearchCatalog.canonicalCatalogJson(input) == output, "\(caseID)")
            } else {
                #expect(testCase["expect"]?["error"]?.stringValue == "non_integer_number", "\(caseID)")
                #expect(throws: SearchCatalogError.nonIntegerNumber, "\(caseID)") {
                    try SearchCatalog.canonicalCatalogJson(input)
                }
            }
        }
        let verdict = SearchCatalog.verifyCatalogSignature(contract["catalog"], trustedKeys: try Self.testKeys(contract))
        #expect(verdict == SearchCatalogSignatureVerdict(ok: true, reason: nil))
    }

    @Test("Adoption rules match acceptCases: signature check, rollback protection, unchanged, per-entry skip, revocation, hard limit")
    func SRCH_CAT_02_acceptCases() throws {
        let contract = try Self.contract()
        let keys = try Self.testKeys(contract)
        for testCase in try Self.cases("acceptCases", in: contract) {
            let caseID = testCase["caseId"]?.stringValue ?? "?"
            let rawState = try #require(testCase["state"])
            var current: SearchCatalogCurrent?
            if let currentJSON = rawState["current"], !currentJSON.isNull {
                current = try JSONDecoder().decode(SearchCatalogCurrent.self, from: currentJSON.encodedData())
            }
            let state = SearchCatalogState(
                maxSeenRevision: try #require(rawState["maxSeenRevision"]?.safeIntegerValue),
                current: current
            )
            let source = try #require(SearchCatalogSource(rawValue: testCase["source"]?.stringValue ?? ""))
            let result = SearchCatalog.acceptSearchCatalog(
                state: state, incoming: testCase["incoming"], source: source, trustedKeys: keys
            )
            let mismatched = SearchContractSupport.mismatchedKeys(
                actual: try SearchContractSupport.json(result), expect: try #require(testCase["expect"])
            )
            #expect(mismatched.isEmpty, "\(caseID): \(mismatched)")
        }
    }

    @Test("Site selection for a reused connection matches regionCases")
    func SRCH_CAT_03_regionCases() throws {
        let contract = try Self.contract()
        let catalog = try #require(contract["catalog"])
        for testCase in try Self.cases("regionCases", in: contract) {
            let caseID = testCase["caseId"]?.stringValue ?? "?"
            let entry = SearchContractSupport.service(testCase["serviceId"]?.stringValue ?? "", in: catalog)
            #expect(entry != nil, "\(caseID)")
            let region = SearchCatalog.regionForConnection(entry, connectionBaseUrl: testCase["connectionBaseUrl"]?.stringValue)
            #expect((region.map(SearchJSON.string) ?? .null) == testCase["expect"]?["region"], "\(caseID)")
        }
    }

    @Test("Host verification before sending a key matches hostCases")
    func SRCH_CAT_04_hostCases() throws {
        let contract = try Self.contract()
        let catalog = try #require(contract["catalog"])
        for testCase in try Self.cases("hostCases", in: contract) {
            let caseID = testCase["caseId"]?.stringValue ?? "?"
            let regionID = try #require(testCase["regionId"]?.stringValue)
            var entry = try #require(SearchContractSupport.service(testCase["serviceId"]?.stringValue ?? "", in: catalog))
            if let override = testCase["catalogHostOverride"] {
                entry = SearchContractSupport.modifyingRegion(entry, id: regionID) { $0["host"] = override }
            }
            let verdict = SearchCatalog.presetHostCheck(
                boundHost: testCase["boundHost"]?.stringValue,
                entry: entry,
                regionId: regionID,
                withdrawn: testCase["withdrawn"]?.boolValue == true
            )
            #expect(verdict.rawValue == testCase["expect"]?["verdict"]?.stringValue, "\(caseID)")
        }
    }

    @Test("Site official links match linkCases (site overrides fall back to the entry level key by key)")
    func SRCH_CAT_05_linkCases() throws {
        let contract = try Self.contract()
        let catalog = try #require(contract["catalog"])
        for testCase in try Self.cases("linkCases", in: contract) {
            let caseID = testCase["caseId"]?.stringValue ?? "?"
            let regionID = try #require(testCase["regionId"]?.stringValue)
            var entry = try #require(SearchContractSupport.service(testCase["serviceId"]?.stringValue ?? "", in: catalog))
            if let override = testCase["regionUrlsOverride"] {
                // null = remove the site-level urls; object = replace wholesale
                entry = SearchContractSupport.modifyingRegion(entry, id: regionID) { $0["urls"] = override.isNull ? nil : override }
            }
            let links = try SearchContractSupport.json(SearchCatalog.regionLinks(entry, regionId: regionID))
            #expect(links == testCase["expect"]?["links"], "\(caseID): \(links.encodedString())")
        }
    }

    @Test("Handling of catalog fetch results matches fetchCases: 200 adopts, 404 revokes presets, anything else keeps the current state")
    func SRCH_CAT_06_fetchCases() throws {
        let contract = try Self.contract()
        for testCase in try Self.cases("fetchCases", in: contract) {
            let caseID = testCase["caseId"]?.stringValue ?? "?"
            let input = try #require(testCase["input"])
            let failure = input["transportFailure"]?.stringValue
            #expect(failure == nil || SearchTransportFailure(rawValue: failure!) != nil, "\(caseID)")
            let action = SearchCatalog.catalogFetchAction(
                status: input["status"]?.safeIntegerValue,
                transportFailure: failure.flatMap(SearchTransportFailure.init(rawValue:))
            )
            #expect(action.rawValue == testCase["expect"]?["action"]?.stringValue, "\(caseID)")
        }
    }

    @Test("Production public key matches the fixture productionKeys, and verifying the data of search_catalog_view.v1.json → 7 active")
    func productionKeysAcceptServerView() throws {
        let contract = try Self.contract()
        let fixtureKeys = (contract["productionKeys"]?.objectValue?.entries ?? []).reduce(into: [String: String]()) {
            $0[$1.key] = $1.value.stringValue
        }
        #expect(SearchCatalogKeys.production == fixtureKeys)

        let view = try SearchContractSupport.load(Self.viewPath)
        let result = SearchCatalog.acceptSearchCatalog(
            state: .empty, incoming: view["data"], source: .builtin, trustedKeys: SearchCatalogKeys.production
        )
        #expect(result.accepted)
        #expect(result.skipped == [])
        let services = try #require(result.current?.services)
        #expect(services.count == 7)
        #expect(services.allSatisfy { $0.status == .active })
        // A catalog signed with the test key is not trusted by the production public key
        let rejected = SearchCatalog.acceptSearchCatalog(
            state: .empty, incoming: contract["catalog"], source: .network, trustedKeys: SearchCatalogKeys.production
        )
        #expect(rejected.reason == "signature_unknown_key")
    }
}
