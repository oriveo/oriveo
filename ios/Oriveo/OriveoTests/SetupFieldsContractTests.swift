import Foundation
import Testing
@testable import Oriveo

/// Cross-platform contract for `setupFields` (`shared/test-fixtures/provider-catalog/setup-fields.v1.json`; its $comment is the rule).
/// Decoding goes through production `ProviderSetupCatalog.fromProviderConfigs`; forms go through `setupFieldIDs` / `setupSubmission`, which the setup page uses;
/// resolve assertions check the address production `EndpointResolver.resolve(provider:)` actually produces.
@Suite("setupFields contract", .serialized, .sharedProcessState)
@MainActor
struct SetupFieldsContractTests {

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

    private static func cases(_ group: String) throws -> [[String: Any]] {
        try #require(try fixture()[group] as? [[String: Any]])
    }

    private static func testCase(_ group: String, _ caseId: String) throws -> [String: Any] {
        try #require(try cases(group).first { $0["caseId"] as? String == caseId }, "fixture is missing \(caseId)")
    }

    /// `configPatch` replaces the whole key; null removes the key.
    private static func config(patch: [String: Any]? = nil) throws -> [String: Any] {
        var config = try #require(try fixture()["config"] as? [String: Any])
        config["displayName"] = "Qwen"
        for (key, value) in patch ?? [:] {
            if value is NSNull { config.removeValue(forKey: key) } else { config[key] = value }
        }
        return config
    }

    private static func sameURL(_ actual: String?, _ expected: String?) -> Bool {
        ProviderEndpointSourceRules.matchKey(actual) == ProviderEndpointSourceRules.matchKey(expected)
    }

    // MARK: - Executors

    private func runDecode(_ caseId: String) throws {
        let item = try Self.testCase("decodeCases", caseId)
        let catalog = try EndpointSourceContractTests.catalog([Self.config(patch: item["configPatch"] as? [String: Any])])
        let ids = catalog.setupEndpointOptions(for: .qwen).map(\.id)
        if let expected = item["expectRegionIds"] as? [String] {
            #expect(ids == expected, "\(caseId): \(ids)")
        }
        if let dropped = item["dropped"] as? String {
            #expect(!ids.contains(dropped), "\(caseId): \(ids)")
        }
    }

    private func runForm(_ caseId: String) throws {
        let item = try Self.testCase("formCases", caseId)
        let catalog = try EndpointSourceContractTests.catalog([Self.config(patch: item["configPatch"] as? [String: Any])])
        let regionID = item["regionId"] as? String
        #expect(catalog.setupFieldIDs(for: .qwen, optionID: regionID) == (item["expectFields"] as? [String] ?? []))
        let values = (item["value"] as? String).map { ["workspaceId": $0] } ?? [:]
        let submission = catalog.setupSubmission(for: .qwen, optionID: regionID, values: values)
        #expect((submission != nil) == (item["expectSubmit"] as? Bool), "\(caseId)")
        guard let expect = item["expect"] as? [String: Any] else { return }
        let built = try #require(submission)
        #expect(built.endpointSource.rawValue == expect["endpointSource"] as? String)
        #expect(Self.sameURL(built.baseURLText, expect["baseURLText"] as? String), "\(caseId): \(built.baseURLText ?? "nil")")
        #expect(built.setupValues == expect["setupValues"] as? [String: String])
    }

    private func runResolve(_ caseId: String) async throws {
        let item = try Self.testCase("resolveCases", caseId)
        let stored = try #require(item["stored"] as? [String: Any])
        var provider = TestFactories.makeProvider(kind: .qwen, models: [])
        provider.baseURLText = stored["baseURLText"] as? String
        provider.endpointSource = (stored["endpointSource"] as? String).flatMap(ProviderEndpointSource.init(rawValue:))
        provider.setupValues = stored["setupValues"] as? [String: String]

        let patch = try #require(item["metadataPatch"] as? [String: Any])
        try await EndpointSourceContractTests.loadMetadata([EndpointSourceContractTests.patched(try Self.config(), patch)])

        let resolved = try EndpointResolver.resolve(provider: provider, kind: .chat, metadataTransport: nil)
        let expected = try #require(item["expectBaseURL"] as? String)
        #expect(Self.sameURL(resolved.baseURL, expected), "\(caseId): \(resolved.baseURL) ≠ \(expected)")
        #expect(resolved.url.host == URL(string: expected)?.host)
    }

    // A default-address template follows the same rule as region items: an unusable one counts as missing and falls back to the built-in default (an iOS-local case, not in the shared fixture).
    @Test("SETUP-FIELDS-default_template_untrusted_dropped")
    func decodeDropsUnusableDefaultTemplate() throws {
        let builtIn = ProviderKind.qwen.defaultBaseURLText
        let unusable: [(String, [String: Any])] = [
            ("untrusted", ["defaultBaseURL": "https://{workspaceId}.example.com"]),
            ("unknown", ["defaultBaseURL": "https://{projectId}.maas.aliyuncs.com"]),
            ("undeclared", ["defaultBaseURL": "https://{workspaceId}.maas.aliyuncs.com", "setupFields": NSNull()]),
        ]
        for (label, patch) in unusable {
            let catalog = try EndpointSourceContractTests.catalog([Self.config(patch: patch)])
            #expect(catalog.defaultBaseURLText(for: .qwen) == builtIn, "\(label): \(catalog.defaultBaseURLText(for: .qwen) ?? "nil")")
        }
        let kept = try EndpointSourceContractTests.catalog([
            Self.config(patch: ["defaultBaseURL": "https://{workspaceId}.maas.aliyuncs.com"])
        ])
        #expect(kept.defaultBaseURLText(for: .qwen) == "{workspaceId}.maas.aliyuncs.com")
    }

    // MARK: - Coverage guard

    @Test("SETUP-FIELDS every fixture caseId has a same-named case")
    func everyCaseCovered() throws {
        let covered: [String: Set<String>] = [
            "decodeCases": ["keeps_trusted_template_option", "drops_unknown_placeholder", "drops_untrusted_template", "drops_undeclared_placeholder"],
            "formCases": ["plain_region_shows_no_field", "template_region_shows_field", "invalid_underscore_blocks", "invalid_leading_hyphen_blocks", "invalid_dot_blocks", "invalid_too_long_blocks", "valid_value_builds_base", "no_setup_fields_in_metadata"],
            "resolveCases": ["template_change_follows_with_stored_value", "missing_value_uses_literal"],
        ]
        for (group, ids) in covered {
            let fixtureIDs = Set(try Self.cases(group).compactMap { $0["caseId"] as? String })
            #expect(fixtureIDs == ids, "\(group) fixture and cases do not match")
        }
    }

    @Test("SETUP-FIELDS-iOS the official detail page and the setup page both list template items that contain placeholders")
    func detailPickerListsTemplateOptions() throws {
        let catalog = try EndpointSourceContractTests.catalog([Self.config()])
        let detail = ProviderEndpointEditPolicy.detailPickerOptions(catalog: catalog, kind: .qwen, current: nil)
        #expect(detail.options.map(\.id) == ["sg", "sg-ws"])
        let setup = ProviderEndpointEditPolicy.pickerOptions(
            catalog: catalog, kind: .qwen, current: nil, includesTemplates: true
        )
        #expect(setup.options.map(\.id) == ["sg", "sg-ws"])
    }

    // MARK: - decodeCases

    @Test("SETUP-FIELDS-keeps_trusted_template_option") func decodeKeepsTrustedTemplateOption() throws { try runDecode("keeps_trusted_template_option") }
    @Test("SETUP-FIELDS-drops_unknown_placeholder") func decodeDropsUnknownPlaceholder() throws { try runDecode("drops_unknown_placeholder") }
    @Test("SETUP-FIELDS-drops_untrusted_template") func decodeDropsUntrustedTemplate() throws { try runDecode("drops_untrusted_template") }
    @Test("SETUP-FIELDS-drops_undeclared_placeholder") func decodeDropsUndeclaredPlaceholder() throws { try runDecode("drops_undeclared_placeholder") }

    // MARK: - formCases

    @Test("SETUP-FIELDS-plain_region_shows_no_field") func formPlainRegionShowsNoField() throws { try runForm("plain_region_shows_no_field") }
    @Test("SETUP-FIELDS-template_region_shows_field") func formTemplateRegionShowsField() throws { try runForm("template_region_shows_field") }
    @Test("SETUP-FIELDS-invalid_underscore_blocks") func formInvalidUnderscoreBlocks() throws { try runForm("invalid_underscore_blocks") }
    @Test("SETUP-FIELDS-invalid_leading_hyphen_blocks") func formInvalidLeadingHyphenBlocks() throws { try runForm("invalid_leading_hyphen_blocks") }
    @Test("SETUP-FIELDS-invalid_dot_blocks") func formInvalidDotBlocks() throws { try runForm("invalid_dot_blocks") }
    @Test("SETUP-FIELDS-invalid_too_long_blocks") func formInvalidTooLongBlocks() throws { try runForm("invalid_too_long_blocks") }
    @Test("SETUP-FIELDS-valid_value_builds_base") func formValidValueBuildsBase() throws { try runForm("valid_value_builds_base") }
    @Test("SETUP-FIELDS-no_setup_fields_in_metadata") func formNoSetupFieldsInMetadata() throws { try runForm("no_setup_fields_in_metadata") }

    // MARK: - resolveCases

    @Test("SETUP-FIELDS-template_change_follows_with_stored_value") func resolveTemplateChangeFollowsWithStoredValue() async throws { try await runResolve("template_change_follows_with_stored_value") }
    @Test("SETUP-FIELDS-missing_value_uses_literal") func resolveMissingValueUsesLiteral() async throws { try await runResolve("missing_value_uses_literal") }

}
