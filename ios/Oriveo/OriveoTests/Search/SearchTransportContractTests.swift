import Foundation
import Testing
@testable import Oriveo

/// json_http/v1 golden samples and error mapping: reads the originals shared/search-contracts/transport-golden.v1.json,
/// shared/search-contracts/error-mapping.v1.json; entries come from the catalogRef of transport-golden (search_catalog_contract.v1.json#catalog).
@Suite("External search transport golden samples and error mapping")
struct SearchTransportContractTests {
    private static let goldenPath = "shared/search-contracts/transport-golden.v1.json"
    private static let errorPath = "shared/search-contracts/error-mapping.v1.json"

    /// catalogRef looks like `search_catalog_contract.v1.json#catalog`, relative to the fixture directory.
    private static func referencedCatalog(_ golden: SearchJSON) throws -> SearchJSON {
        let ref = try #require(golden["catalogRef"]?.stringValue)
        let parts = ref.split(separator: "#", maxSplits: 1).map(String.init)
        let document = try SearchContractSupport.load("shared/search-contracts/" + parts[0])
        return try #require(parts.count > 1 ? document[parts[1]] : document)
    }

    @Test("Request construction, response mapping and error replay match transport-golden case by case")
    func SRCH_TRN_01_transportGolden() throws {
        let golden = try SearchContractSupport.load(Self.goldenPath)
        let catalog = try Self.referencedCatalog(golden)
        let cases = try #require(golden["cases"]?.arrayValue)
        #expect(!cases.isEmpty)
        for testCase in cases {
            let caseID = testCase["caseId"]?.stringValue ?? "?"
            let entry = try #require(SearchContractSupport.service(testCase["serviceId"]?.stringValue ?? "", in: catalog), "\(caseID)")
            let spec = try #require(entry["transport"])
            let expect = try #require(testCase["expect"])
            switch testCase["kind"]?.stringValue {
            case "request":
                let regionID = testCase["regionId"]?.stringValue
                let region = try #require(SearchCatalog.region(of: entry, id: regionID), "\(caseID)")
                let target = SearchRequestTarget(
                    scheme: "https",
                    host: try #require(region["host"]?.stringValue),
                    port: nil,
                    path: nil,
                    staticParams: region["static"]?.objectValue
                )
                let input = try #require(testCase["input"])
                let request = SearchTransport.buildSearchRequest(
                    spec,
                    target: target,
                    query: input["query"]?.stringValue ?? "",
                    count: input["count"]?.safeIntegerValue,
                    key: input["key"]?.stringValue
                )
                let problems = SearchContractSupport.buildMismatches(request, expect: expect)
                #expect(problems.isEmpty, "\(caseID): \(problems)")
            case "response":
                let outcome = SearchTransport.parseSearchResponse(spec, body: testCase["body"], count: nil)
                let actual = try SearchContractSupport.json(outcome)
                #expect(actual == expect, "\(caseID): \(actual.encodedString())")
            case "error":
                let classification = SearchTransport.classifySearchError(SearchErrorInput(
                    status: testCase["status"]?.safeIntegerValue,
                    body: testCase["body"],
                    rules: spec["errors"]?.arrayValue ?? []
                ))
                #expect(try SearchContractSupport.json(classification) == expect, "\(caseID)")
            default:
                Issue.record("\(caseID): unknown kind")
            }
        }
    }

    @Test("Error mapping matches error-mapping case by case, and the error class table and fixed phrasing match verbatim")
    func SRCH_ERR_01_errorMapping() throws {
        let fixture = try SearchContractSupport.load(Self.errorPath)
        let catalog = try #require(try SearchContractSupport.load("shared/search-contracts/search_catalog_contract.v1.json")["catalog"])

        let classes = try #require(fixture["constants"]?["classes"]?.objectValue)
        #expect(Set(classes.keys) == Set(SearchTransport.errorClasses.keys))
        for (name, definition) in classes.entries {
            let production = try #require(SearchTransport.errorClasses[name])
            #expect(definition["retryOnce"]?.boolValue == production.retryOnce, "\(name)")
            #expect(definition["toolMessage"]?.stringValue == production.toolMessage, "\(name)")
            #expect(definition["card"]?["headline"]?.stringValue == production.headline, "\(name)")
            #expect(definition["card"]?["primaryAction"]?.stringValue == production.primaryAction, "\(name)")
        }
        let messages = try #require(fixture["constants"]?["toolMessages"]?.objectValue)
        #expect(messages.entries.reduce(into: [String: String]()) { $0[$1.key] = $1.value.stringValue } == SearchTransport.toolMessages)
        for status in fixture["constants"]?["retryableStatuses"]?.arrayValue ?? [] {
            let result = SearchTransport.classifySearchError(SearchErrorInput(status: status.safeIntegerValue))
            #expect(result.retryOnce, "retryable \(status.jsString)")
        }

        let cases = try #require(fixture["cases"]?.arrayValue)
        #expect(!cases.isEmpty)
        for testCase in cases {
            let caseID = testCase["caseId"]?.stringValue ?? "?"
            let input = try #require(testCase["input"])
            var rules: [SearchJSON] = []
            if let serviceID = input["serviceId"]?.stringValue {
                rules = try #require(SearchContractSupport.service(serviceID, in: catalog), "\(caseID)")["transport"]?["errors"]?.arrayValue ?? []
            } else if input["protocol"]?.stringValue == "searxng" {
                rules = SearchTransport.searxngSpec["errors"]?.arrayValue ?? []
            }
            let transportFailure = input["transportFailure"]?.stringValue
            let preflight = input["preflight"]?.stringValue
            let classification = SearchTransport.classifySearchError(SearchErrorInput(
                status: input["status"]?.safeIntegerValue,
                transportFailure: transportFailure.flatMap(SearchTransportFailure.init(rawValue:)),
                preflight: preflight.flatMap(PresetHostVerdict.init(rawValue:)),
                parseMismatch: input["parse"]?.stringValue == "mismatch",
                body: input["body"],
                rules: rules,
                custom: input["custom"]?.boolValue == true,
                otherServices: input["otherServices"]?.safeIntegerValue ?? 0
            ))
            #expect(transportFailure == nil || SearchTransportFailure(rawValue: transportFailure!) != nil, "\(caseID)")
            #expect(try SearchContractSupport.json(classification) == testCase["expect"], "\(caseID)")
        }
    }
}
