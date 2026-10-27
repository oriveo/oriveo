import Foundation
import Testing
@testable import Oriveo

/// Web row, web card and per-conversation source (external search services contract): reads shared/search-contracts/web-route-resolution.v1.json
/// and compares each case against expect; oneTapCases entries are taken by serviceIds from this platform's built-in catalog snapshot (Core/Search/search_catalog_view.v1.json).
@Suite("External search web card and routing (row resolution, turn path, selectable, one-tap enable, source, sheet, card, composed entry, call limit, regenerate)")
struct SearchRouteTests {
    private static let fixturePath = "shared/search-contracts/web-route-resolution.v1.json"
    private static let builtinCatalogPath = "ios/Oriveo/Oriveo/Core/Search/search_catalog_view.v1.json"

    private static func cases(_ key: String) throws -> [SearchJSON] {
        let cases = try #require(try SearchContractSupport.load(fixturePath)[key]?.arrayValue, "fixture missing \(key)")
        #expect(!cases.isEmpty, "\(key) is empty")
        return cases
    }

    private static func caseID(_ testCase: SearchJSON) -> String { testCase["caseId"]?.stringValue ?? "?" }

    private static func check<T: Encodable>(_ actual: T, _ testCase: SearchJSON) throws {
        let expect = try #require(testCase["expect"], "\(caseID(testCase)) missing expect")
        let json = try SearchContractSupport.json(actual)
        #expect(SearchContractSupport.mismatchedKeys(actual: json, expect: expect).isEmpty, "\(caseID(testCase)): \(json.encodedString())")
    }

    private static func selectable(_ value: SearchJSON?) throws -> [SearchSelectableService] {
        try (value?.arrayValue ?? []).map {
            SearchSelectableService(
                id: $0["id"]?.stringValue ?? "",
                status: try #require(SearchServiceRowState.Status(rawValue: $0["status"]?.stringValue ?? ""))
            )
        }
    }

    private struct Wrapped<T: Encodable>: Encodable {
        let key: String
        let value: T?
        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(value, forKey: Key(stringValue: key))
        }
    }

    @Test("Web row resolution matches cases")
    func SRCH_ROUTE_01_cases() throws {
        for testCase in try Self.cases("cases") {
            let input = try #require(testCase["input"])
            let route = SearchRoute.resolveWebSearchRoute(.init(
                form: try #require(WebSearchRouteInput.Form(rawValue: input["form"]?.stringValue ?? ""), "\(Self.caseID(testCase)) form"),
                nativeWeb: input["nativeWeb"]?.stringValue.flatMap(WebSearchRouteInput.NativeWeb.init(rawValue:)),
                relayWebRecord: input["relayWebRecord"]?.stringValue.flatMap(WebSearchRouteInput.RelayRecord.init(rawValue:)),
                externalServices: input["externalServices"]?.safeIntegerValue ?? 0,
                reusableConnection: input["reusableConnection"]?.boolValue == true,
                toolCall: input["toolCall"]?.stringValue.flatMap(WebSearchRouteInput.ToolCall.init(rawValue:)) ?? .unknown,
                webOn: input["webOn"]?.boolValue == true,
                method: input["method"]?.stringValue.flatMap(SearchSourceMethod.init(rawValue:)) ?? .default
            ))
            try Self.check(route, testCase)
        }
    }

    @Test("Turn path and downgrade match turnCases")
    func SRCH_ROUTE_02_turnCases() throws {
        for testCase in try Self.cases("turnCases") {
            let input = try #require(testCase["input"])
            let turn = SearchRoute.resolveSearchTurnPath(.init(
                path: try #require(WebSearchRoute.Path(rawValue: input["path"]?.stringValue ?? "")),
                thinkingOn: input["thinkingOn"]?.boolValue == true,
                continuationStateAvailable: input["continuationStateAvailable"]?.boolValue,
                upstreamRejectedTools: input["upstreamRejectedTools"]?.boolValue == true,
                thinkingWithTools: input["thinkingWithTools"]?.stringValue,
                hostMaxSteps: input["hostMaxSteps"]?.safeIntegerValue
            ))
            try Self.check(turn, testCase)
        }
    }

    @Test("Whether a service can go on the card matches selectableCases")
    func SRCH_ROUTE_03_selectableCases() throws {
        for testCase in try Self.cases("selectableCases") {
            let status = try #require(SearchServiceRowState.Status(rawValue: testCase["input"]?["status"]?.stringValue ?? ""))
            #expect(SearchRoute.searchServiceSelectable(status) == testCase["expect"]?["selectable"]?.boolValue, "\(Self.caseID(testCase))")
        }
    }

    @Test("Which service one-tap enable picks matches oneTapCases (entries taken from the built-in catalog snapshot)")
    func SRCH_ROUTE_04_oneTapCases() throws {
        let snapshot = try SearchContractSupport.load(Self.builtinCatalogPath)
        let catalog = try #require(snapshot["data"])
        for testCase in try Self.cases("oneTapCases") {
            let input = try #require(testCase["input"])
            let entries = (input["serviceIds"]?.arrayValue ?? []).compactMap {
                SearchContractSupport.service($0.stringValue ?? "", in: catalog)
            }
            #expect(entries.count == input["serviceIds"]?.arrayValue?.count, "\(Self.caseID(testCase)) entries missing")
            let connections = (input["connections"]?.arrayValue ?? []).map {
                SearchSettingsConnection(
                    id: $0["id"]?.stringValue ?? "", name: $0["name"]?.stringValue ?? "",
                    providerKind: $0["providerKind"]?.stringValue, baseUrl: $0["baseUrl"]?.stringValue
                )
            }
            let target = SearchRoute.oneTapReuseTarget(
                catalogAvailable: input["catalogAvailable"]?.boolValue == true,
                entries: entries, connections: connections,
                currentProviderKind: input["currentProviderKind"]?.stringValue
            )
            try Self.check(Wrapped(key: "target", value: target), testCase)
        }
    }

    @Test("Reading by conversation source and fallback match sourceCases")
    func SRCH_ROUTE_05_sourceCases() throws {
        for testCase in try Self.cases("sourceCases") {
            let input = try #require(testCase["input"])
            let stored = input["stored"].flatMap { $0.isNull ? nil : $0 }
            let resolution = SearchRoute.resolveSearchSource(
                stored: stored, modelKey: input["modelKey"]?.stringValue ?? "",
                selectable: try Self.selectable(input["selectable"]),
                defaultServiceId: input["defaultServiceId"]?.stringValue
            )
            try Self.check(resolution, testCase)
        }
        #expect(SearchRoute.searchSourceStorageKey("c1") == "conversationSource:c1")
    }

    @Test("Source writes match sourceUpdateCases")
    func SRCH_ROUTE_06_sourceUpdateCases() throws {
        for testCase in try Self.cases("sourceUpdateCases") {
            let input = try #require(testCase["input"])
            let event: SearchSourceEvent
            switch input["event"]?["type"]?.stringValue {
            case "pick_native": event = .pickNative
            case "pick_service":
                event = .pickService(
                    serviceId: input["event"]?["serviceId"]?.stringValue ?? "",
                    serviceName: input["event"]?["serviceName"]?.stringValue
                )
            case "acknowledge_notice": event = .acknowledgeNotice
            case "disarm": event = .disarm
            default:
                Issue.record("\(Self.caseID(testCase)) unknown event")
                continue
            }
            let next = SearchRoute.updateSearchSource(
                stored: input["stored"].flatMap { $0.isNull ? nil : $0 },
                modelKey: input["modelKey"]?.stringValue ?? "", event: event
            )
            try Self.check(Wrapped(key: "nextStored", value: next), testCase)
        }
    }

    @Test("The \"Search method\" sheet rows match pickerCases")
    func SRCH_ROUTE_07_pickerCases() throws {
        for testCase in try Self.cases("pickerCases") {
            let input = try #require(testCase["input"])
            let items = SearchRoute.searchSourcePickerItems(
                nativeCapable: input["nativeCapable"]?.boolValue == true,
                selectable: try Self.selectable(input["selectable"]),
                defaultServiceId: input["defaultServiceId"]?.stringValue,
                method: input["method"]?.stringValue.flatMap(SearchSourceMethod.init(rawValue:)) ?? .default,
                serviceId: input["serviceId"]?.stringValue
            )
            try Self.check(Wrapped(key: "items", value: items), testCase)
        }
    }

    @Test("Web card presentation matches cardCases")
    func SRCH_ROUTE_08_cardCases() throws {
        for testCase in try Self.cases("cardCases") {
            let input = try #require(testCase["input"])
            let routeJSON = try #require(input["route"])
            let route = WebSearchRoute(
                row: try #require(WebSearchRoute.Row(rawValue: routeJSON["row"]?.stringValue ?? "")),
                path: try #require(WebSearchRoute.Path(rawValue: routeJSON["path"]?.stringValue ?? "")),
                primaryAction: routeJSON["primaryAction"]?.stringValue.flatMap(WebSearchRoute.Action.init(rawValue:)),
                secondaryAction: routeJSON["secondaryAction"]?.stringValue.flatMap(WebSearchRoute.Action.init(rawValue:)),
                sourceAction: routeJSON["sourceAction"]?.stringValue.flatMap(WebSearchRoute.Action.init(rawValue:))
            )
            var source: WebSearchCardSource?
            switch input["source"]?["kind"]?.stringValue {
            case "native": source = .native
            case "service":
                source = .service(
                    name: input["source"]?["name"]?.stringValue ?? "",
                    status: input["source"]?["status"]?.stringValue.flatMap(SearchServiceRowState.Status.init(rawValue:))
                )
            default: source = nil
            }
            let notice = input["notice"]?["fromName"]?.stringValue.map { WebSearchCardNotice(fromName: $0) }
            let card = SearchRoute.webSearchCardPresentation(
                route: route,
                nativeWeb: input["nativeWeb"]?.stringValue.flatMap(WebSearchRouteInput.NativeWeb.init(rawValue:)) ?? .unavailable,
                webOn: input["webOn"]?.boolValue == true,
                source: source,
                oneTapServiceName: input["oneTapServiceName"]?.stringValue,
                notice: notice,
                armHint: input["armHint"]?.boolValue == true
            )
            try Self.check(card, testCase)
        }
    }

    @Test("Composed entry matches stateCases")
    func SRCH_ROUTE_09_stateCases() throws {
        for testCase in try Self.cases("stateCases") {
            let input = try #require(testCase["input"])
            let facts = try #require(input["facts"])
            let id = Self.caseID(testCase)
            let target = input["oneTapTarget"].flatMap { value -> SearchOneTapTarget? in
                guard let serviceId = value["serviceId"]?.stringValue else { return nil }
                return SearchOneTapTarget(
                    serviceId: serviceId, regionId: value["regionId"]?.stringValue ?? "",
                    connectionRef: value["connectionRef"]?.stringValue ?? "", connectionName: value["connectionName"]?.stringValue
                )
            }
            let state = SearchRoute.resolveWebSearchState(.init(
                facts: .init(
                    form: try #require(WebSearchRouteInput.Form(rawValue: facts["form"]?.stringValue ?? ""), "\(id) form"),
                    recipeWeb: facts["recipeWeb"]?.stringValue.flatMap(WebSearchFacts.RecipeWeb.init(rawValue:)) ?? .none,
                    nativeRejected: facts["nativeRejected"]?.boolValue == true,
                    relayStatus: try facts["relayStatus"]?.stringValue.map {
                        try #require(WebSearchFacts.RelayStatus(rawValue: $0), "\(id) relayStatus")
                    },
                    managedWebAvailable: facts["managedWebAvailable"]?.boolValue == true,
                    toolCall: facts["toolCall"]?.stringValue.flatMap(WebSearchRouteInput.ToolCall.init(rawValue:)) ?? .unknown
                ),
                panelWritable: input["panelWritable"]?.boolValue ?? true,
                webOn: input["webOn"]?.boolValue == true,
                modelKey: input["modelKey"]?.stringValue ?? "",
                services: try (input["services"]?.arrayValue ?? []).map {
                    WebSearchStateService(
                        id: $0["id"]?.stringValue ?? "", name: $0["name"]?.stringValue ?? "",
                        status: try #require(SearchServiceRowState.Status(rawValue: $0["status"]?.stringValue ?? ""))
                    )
                },
                defaultServiceId: input["defaultServiceId"]?.stringValue,
                stored: input["stored"].flatMap { $0.isNull ? nil : $0 },
                oneTapTarget: target,
                oneTapServiceName: input["oneTapServiceName"]?.stringValue
            ))
            try Self.check(state, testCase)
        }
    }

    @Test("Per-reply request limit and retries match callCases")
    func SRCH_CALL_01_callCases() throws {
        for testCase in try Self.cases("callCases") {
            let legs = try (testCase["input"]?["legs"]?.arrayValue ?? []).map { leg in
                try (leg.arrayValue ?? []).map { call in
                    try (call["attempts"]?.arrayValue ?? []).map { attempt -> SearchCallAttempt in
                        if let status = attempt.safeIntegerValue { return .status(status) }
                        return .failure(try #require(attempt.stringValue, "\(Self.caseID(testCase)) attempt"))
                    }
                }
            }
            try Self.check(SearchRoute.planSearchCalls(legs: legs), testCase)
        }
    }

    @Test("Regenerate reuse and re-search match regenerateCases")
    func SRCH_CALL_02_regenerateCases() throws {
        for testCase in try Self.cases("regenerateCases") {
            let input = try #require(testCase["input"])
            let policy = SearchRoute.regenerateSearchPolicy(
                action: try #require(SearchRegenerateAction(rawValue: input["action"]?.stringValue ?? ""), "\(Self.caseID(testCase)) action"),
                previousResultsPersisted: input["previousResultsPersisted"]?.boolValue == true
            )
            try Self.check(policy, testCase)
        }
    }
}
