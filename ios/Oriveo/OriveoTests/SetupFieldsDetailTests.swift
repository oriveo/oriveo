import Foundation
import Testing
@testable import Oriveo

/// The official detail page's region picker lists template items that contain placeholders; selecting one reveals a Workspace ID slot, and saving writes the template value and the region source
/// (`shared/test-fixtures/provider-catalog/setup-fields.v1.json`; form values reuse formCases).
@Suite("Official detail page setupFields", .serialized, .sharedProcessState)
@MainActor
struct SetupFieldsDetailTests {
    private static func fixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/provider-catalog/setup-fields.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                return try #require(object as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func config(patch: [String: Any] = [:]) throws -> [String: Any] {
        var config = try #require(try fixture()["config"] as? [String: Any])
        config["displayName"] = "Qwen"
        for (key, value) in patch {
            if value is NSNull { config.removeValue(forKey: key) } else { config[key] = value }
        }
        return config
    }

    @Test("SETUP-FIELDS-DETAIL-01 the detail page's template item is selectable + Workspace ID validation (an invalid value disables Save)")
    func setupFieldsDetail01TemplateOptionAndValidation() throws {
        let catalog = try EndpointSourceContractTests.catalog([Self.config()])
        let picker = ProviderEndpointEditPolicy.detailPickerOptions(catalog: catalog, kind: .qwen, current: nil)
        #expect(picker.options.map(\.id) == ["sg", "sg-ws"])
        #expect(picker.lockedIDs.isEmpty)
        // A provider without setupFields still lists no template item (it was dropped at decode time).
        let plain = try EndpointSourceContractTests.catalog([Self.config(patch: ["setupFields": NSNull()])])
        #expect(ProviderEndpointEditPolicy.detailPickerOptions(catalog: plain, kind: .qwen, current: nil).options.map(\.id) == ["sg"])

        let cases = try #require(try Self.fixture()["formCases"] as? [[String: Any]])
        for item in cases where item["configPatch"] == nil {
            let caseId = item["caseId"] as? String ?? "<no id>"
            let regionID = try #require(item["regionId"] as? String)
            #expect(catalog.setupFieldIDs(for: .qwen, optionID: regionID) == (item["expectFields"] as? [String] ?? []), "\(caseId)")
            let values = (item["value"] as? String).map { ["workspaceId": $0] } ?? [:]
            let save = ProviderEndpointEditPolicy.detailSave(
                catalog: catalog, kind: .qwen, selectedOptionID: regionID,
                current: nil, storedBaseURLText: "https://dashscope-intl.aliyuncs.com", values: values
            )
            #expect((save != nil) == (item["expectSubmit"] as? Bool), "\(caseId)")
            guard let expect = item["expect"] as? [String: Any], expect["setupValues"] != nil else { continue }
            guard case let .setup(submission) = save else {
                Issue.record("\(caseId): expected the template item to write the template value, got \(String(describing: save))")
                continue
            }
            #expect(submission.endpointSource.rawValue == expect["endpointSource"] as? String, "\(caseId)")
            #expect(submission.setupValues == expect["setupValues"] as? [String: String], "\(caseId)")
        }
    }

    @Test("SETUP-FIELDS-DETAIL-02 saving writes setupValues and the region source (persisted by the production AppState)")
    func setupFieldsDetail02SaveWritesValuesAndSource() async throws {
        try await EndpointSourceContractTests.loadMetadata([Self.config()])
        let catalog = ProviderSetupCatalog.current()
        let formCases = try #require(try Self.fixture()["formCases"] as? [[String: Any]])
        let item = try #require(formCases.first { $0["caseId"] as? String == "valid_value_builds_base" })
        let expect = try #require(item["expect"] as? [String: Any])
        let value = try #require(item["value"] as? String)
        let save = try #require(ProviderEndpointEditPolicy.detailSave(
            catalog: catalog, kind: .qwen, selectedOptionID: "sg-ws", current: nil,
            storedBaseURLText: "https://dashscope-intl.aliyuncs.com",
            values: ["workspaceId": value]
        ))
        guard case let .setup(submission) = save else {
            Issue.record("expected the template item to write the template value, got \(save)")
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SetupFieldsDetailOfflineProtocol.self]
        let state = AppState(
            seedDemoData: false,
            sessionUID: "setup-fields-detail-\(UUID().uuidString)",
            providerSession: URLSession(configuration: configuration)
        )
        var provider = TestFactories.makeProvider(kind: .qwen, baseURLText: "https://dashscope-intl.aliyuncs.com")
        provider.endpointSource = .region("sg")
        state.providers = [provider]
        // The re-sync hits an offline fake service; its failure does not affect the address fields already written.
        try? await state.updateEndpointSetup(providerID: provider.id, submission: submission)

        let stored = try #require(state.provider(for: provider.id))
        #expect(stored.endpointSource?.rawValue == expect["endpointSource"] as? String)
        #expect(stored.setupValues == expect["setupValues"] as? [String: String])
        #expect(ProviderEndpointSourceRules.matchKey(stored.baseURLText) == ProviderEndpointSourceRules.matchKey(expect["baseURLText"] as? String))
    }
}

/// Offline: every request fails, so the tests never hit a real provider.
private final class SetupFieldsDetailOfflineProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
