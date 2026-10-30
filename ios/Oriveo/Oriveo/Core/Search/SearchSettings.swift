import Foundation

// MARK: - UI presentation rules for the external search settings pages (external search services contract)
//
// Function-by-function port of scripts/lib/search-settings.mjs (same names on all three platforms): searchAddSheetSections / searchPriceSummary /
// searchServiceRowState / resolveDefaultSearchService / searchConsentLines / searchTestPresentation /
// customFormFieldErrors. Views render strictly from these results and make no judgments of their own. Catalog entries stay raw JSON (same as SearchCatalog).
// Output types encode to the same JSON shape as the reference implementation (nested nulls are written as null), so contract tests compare by JSON semantics.

/// Model connections that have a key on this device (used for the add sheet's reuse check and for showing the connection name on list rows).
nonisolated struct SearchSettingsConnection: Sendable, Equatable {
    var id: String
    var name: String
    var providerKind: String?
    var baseUrl: String?
}

/// The service kind as the settings page sees it: a preset that reuses a model connection is still a preset (the key source is recorded separately).
nonisolated enum SearchSettingsKind: String, Codable, Sendable {
    case preset
    case custom
}

/// Reference to a saved service inside the add sheet (used to decide "already added").
nonisolated struct SearchSettingsServiceRef: Sendable, Equatable {
    var id: String
    var kind: SearchSettingsKind
    var serviceId: String?
}

// MARK: Add sheet

nonisolated struct SearchAddSheetRow: Codable, Sendable, Hashable {
    var serviceId: String
    var regionId: String?
    var connectionRef: String?
    var connectionName: String?
    var addedServiceRef: String?

    private enum CodingKeys: String, CodingKey { case serviceId, regionId, connectionRef, connectionName, addedServiceRef }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serviceId, forKey: .serviceId)
        try container.encode(regionId, forKey: .regionId)
        try container.encode(connectionRef, forKey: .connectionRef)
        try container.encode(connectionName, forKey: .connectionName)
        try container.encode(addedServiceRef, forKey: .addedServiceRef)
    }
}

nonisolated struct SearchAddSheetSection: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case reuse
        case domestic
        case overseas
    }

    var id: Kind
    var rows: [SearchAddSheetRow]
}

nonisolated struct SearchAddSheet: Codable, Sendable, Equatable {
    enum Presets: String, Codable, Sendable {
        case available
        case unavailable
    }

    var presets: Presets
    var sections: [SearchAddSheetSection]
    /// The "Custom" group is always present.
    var custom: Bool
}

// MARK: Price summary

nonisolated struct SearchPriceLabel: Codable, Sendable, Equatable {
    /// per_request / per_1k_requests
    var unit: String?
    /// Amount with a currency prefix, e.g. ¥5, $0.008.
    var label: String
}

nonisolated struct SearchFreeAllowance: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case monthlyCredits = "monthly_credits"
        case monthlyUsd = "monthly_usd"
    }

    var kind: Kind
    /// Integer quota (each platform adds thousands separators for the current language).
    var count: Int?
    /// Currency quota (with prefix).
    var amountLabel: String?
    var cardRequired: Bool

    private enum CodingKeys: String, CodingKey { case kind, count, amountLabel, cardRequired }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(count, forKey: .count)
        try container.encode(amountLabel, forKey: .amountLabel)
        try container.encode(cardRequired, forKey: .cardRequired)
    }
}

nonisolated struct SearchPriceSummary: Codable, Sendable, Equatable {
    var regionId: String?
    /// nil = no unit price shown (non-monetary pricing; only the free quota is shown).
    var price: SearchPriceLabel?
    var billing: String?
    var free: SearchFreeAllowance?
    /// When > 0, the add sheet appends "also available on the international site".
    var otherRegionCount: Int
}

// MARK: List row status

nonisolated enum SearchServiceKeySource: String, Codable, Sendable {
    case connection
    case own
    case none
}

nonisolated struct SearchRowServiceInput: Sendable, Equatable {
    var kind: SearchSettingsKind
    var serviceId: String?
    var regionId: String?
    var boundHost: String?
    var keySource: SearchServiceKeySource
    var connectionRef: String?
    var hasKey: Bool
}

nonisolated struct SearchServiceRowState: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        case ready
        case catalogUnavailable = "catalog_unavailable"
        case withdrawn
        case hostChanged = "host_changed"
        case connectionMissing = "connection_missing"
        case needsKey = "needs_key"
    }

    var status: Status
    var label: SearchSettingsKind
    var keySource: SearchServiceKeySource
    var connectionName: String?
}

// MARK: Consent sentences, test results, form hints

nonisolated struct SearchConsentLine: Codable, Sendable, Equatable {
    /// The second half of the copy key `consent.*`.
    var key: String
    var args: [String: String?]
}

/// Result of a single test search (connect page, custom consent page, detail page).
nonisolated enum SearchTestOutcome: Sendable, Equatable {
    case passed(count: Int, latencyMs: Int)
    case failed(errorClass: String?, card: SearchErrorCard?)
}

nonisolated struct SearchTestPresentation: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable {
        case passed
        case failed
    }

    var state: State
    var count: Int?
    /// Elapsed time as an integer rounded to 0.1 s; each platform formats it with one decimal for the current language.
    var latencyTenths: Int?
    var errorClass: String?
    /// Key of the error card's headline (`error.*`).
    var headline: String?
    /// Settings page action (`action.*`); none = no action.
    var action: String?
}

nonisolated struct SearchFormFieldErrors: Codable, Sendable, Equatable {
    /// Field -> hint key (`form.*`); only the first hint is kept per field.
    var fields: [String: String]
    /// address -> cleartextLan (orange text, non-blocking).
    var warnings: [String: String]
    var blocking: Bool
}

// MARK: Migration defaults, edit plan

nonisolated struct SearchMigratedDefault: Codable, Sendable, Equatable {
    var set: Bool
    var id: String?
}

/// One side of editing a custom service (before save / after save). mapping only matters for manual; presetId / regionId only for same_as.
nonisolated struct SearchCustomEditSide: Sendable, Equatable {
    var name: String?
    var address: String?
    var protocolID: String?
    var mapping: SearchJSON?
    var presetId: String?
    var regionId: String?
}

nonisolated struct SearchCustomEditPlan: Codable, Sendable, Equatable {
    enum Mode: String, Codable, Sendable {
        case save
        case testThenSave = "test_then_save"
    }

    var mode: Mode
    var clearsKey: Bool
    var showKeyField: Bool
    /// The same_as reference changed: re-take the snapshot from the new reference.
    var resnapshot: Bool
    /// Validation requires the preset to be available (only when re-taking the snapshot).
    var requirePreset: Bool
}

nonisolated enum SearchSettingsError: Error, Equatable {
    /// The validation error code has no matching form field (the three platforms disagreed on one).
    case unmappedFormError(String)
}

nonisolated enum SearchSettings {
    /// Allowed values and default for Detail page > Advanced > results per search.
    static let resultCountChoices = [3, 5, 8, 10]
    static let resultCountDefault = 5

    /// Official docs opened by "View setup instructions" when SearXNG has JSON format disabled (not a search endpoint).
    static let searxngSetupGuideUrl = "https://docs.searxng.org/admin/settings/settings_search.html"

    private static let currencyPrefix = ["CNY": "¥", "USD": "$"]

    /// Adds a currency prefix to a price amount (a string in the catalog); an unknown currency returns nil (no price shown).
    private static func priceLabel(_ currency: String?, _ amount: SearchJSON?) -> String? {
        guard let currency, let prefix = currencyPrefix[currency], let amount = amount?.stringValue else { return nil }
        return prefix + amount
    }

    /// Price summary for a site (add sheet subtitle, connect page subtitle row, detail page price area). Falls back to the first site if the site is not found.
    static func searchPriceSummary(_ entry: SearchJSON?, regionId: String?) -> SearchPriceSummary {
        let regions = entry?["regions"]?.arrayValue ?? []
        guard let region = regions.first(where: { $0["id"]?.stringValue == regionId && regionId != nil }) ?? regions.first else {
            return SearchPriceSummary(regionId: nil, price: nil, billing: nil, free: nil, otherRegionCount: 0)
        }
        let pricing = region["pricing"]
        let price = priceLabel(pricing?["currency"]?.stringValue, pricing?["amount"]).map {
            SearchPriceLabel(unit: pricing?["unit"]?.stringValue, label: $0)
        }
        var free: SearchFreeAllowance?
        let freeSpec = pricing?["free"]
        let cardRequired = freeSpec?["cardRequired"]?.boolValue == true
        switch freeSpec?["kind"]?.stringValue {
        case "monthly_credits":
            if let count = freeSpec?["amount"]?.integerValue {
                free = SearchFreeAllowance(kind: .monthlyCredits, count: Int(count), amountLabel: nil, cardRequired: cardRequired)
            }
        case "monthly_usd":
            if let label = priceLabel("USD", freeSpec?["amount"]) {
                free = SearchFreeAllowance(kind: .monthlyUsd, count: nil, amountLabel: label, cardRequired: cardRequired)
            }
        default:
            break
        }
        return SearchPriceSummary(
            regionId: region["id"]?.stringValue,
            price: price,
            billing: pricing?["billing"]?.stringValue,
            free: free,
            otherRegionCount: regions.count - 1
        )
    }

    /// Groups for the add sheet. entries = adopted-catalog entries that passed validation and are not revoked (catalog order);
    /// connections = model connections with a key on this device (connection list order); services = saved search services (storage order).
    /// An entry with reuse, and a connection with the same providerKind whose address resolves to a site, goes into the "Reuse" group (the first such connection is used);
    /// the rest go into domestic / overseas by group, taking the first site. Already-added presets are still listed, with addedServiceRef pointing at the saved service.
    static func searchAddSheetSections(
        catalogAvailable: Bool,
        entries: [SearchJSON],
        connections: [SearchSettingsConnection],
        services: [SearchSettingsServiceRef]
    ) -> SearchAddSheet {
        guard catalogAvailable else { return SearchAddSheet(presets: .unavailable, sections: [], custom: true) }
        var buckets: [SearchAddSheetSection.Kind: [SearchAddSheetRow]] = [:]
        for entry in entries {
            let entryID = entry["id"]?.stringValue ?? ""
            let added = services.first { $0.kind == .preset && $0.serviceId == entryID }?.id
            var connection: SearchSettingsConnection?
            var region: String?
            if let reuse = entry["reuse"], reuse.isTruthy {
                for candidate in connections where candidate.providerKind == reuse["providerKind"]?.stringValue {
                    if let matched = SearchCatalog.regionForConnection(entry, connectionBaseUrl: candidate.baseUrl) {
                        connection = candidate
                        region = matched
                        break
                    }
                }
            }
            let row = SearchAddSheetRow(
                serviceId: entryID,
                regionId: region ?? entry["regions"]?.arrayValue?.first?["id"]?.stringValue,
                connectionRef: connection?.id,
                connectionName: connection?.name,
                addedServiceRef: added
            )
            if connection != nil {
                buckets[.reuse, default: []].append(row)
            } else if let group = entry["group"]?.stringValue.flatMap(SearchAddSheetSection.Kind.init(rawValue:)), group != .reuse {
                buckets[group, default: []].append(row)
            }
        }
        let sections = [SearchAddSheetSection.Kind.reuse, .domestic, .overseas].compactMap { kind in
            buckets[kind].flatMap { $0.isEmpty ? nil : SearchAddSheetSection(id: kind, rows: $0) }
        }
        return SearchAddSheet(presets: .available, sections: sections, custom: true)
    }

    /// Status shown on "My search services" list rows and at the top of the detail page. entry = this preset's entry in the adopted catalog (nil if absent).
    /// Preset decision order: catalog unavailable -> revoked / not in catalog -> host changed -> reused connection gone -> own key gone -> ready.
    /// A custom service is always ready (the key is optional).
    static func searchServiceRowState(
        service: SearchRowServiceInput,
        catalogAvailable: Bool,
        entry: SearchJSON?,
        withdrawn: Bool,
        connections: [SearchSettingsConnection]
    ) -> SearchServiceRowState {
        let connection = service.keySource == .connection ? connections.first { $0.id == service.connectionRef } : nil
        func state(_ status: SearchServiceRowState.Status, keySource: SearchServiceKeySource? = nil) -> SearchServiceRowState {
            SearchServiceRowState(
                status: status,
                label: service.kind,
                keySource: keySource ?? service.keySource,
                connectionName: connection?.name
            )
        }
        if service.kind == .custom { return state(.ready, keySource: service.hasKey ? .own : SearchServiceKeySource.none) }
        if !catalogAvailable { return state(.catalogUnavailable) }
        guard !withdrawn, let entry else { return state(.withdrawn) }
        let verdict = SearchCatalog.presetHostCheck(boundHost: service.boundHost, entry: entry, regionId: service.regionId, withdrawn: withdrawn)
        if verdict == .hostChanged { return state(.hostChanged) }
        if service.keySource == .connection && connection == nil { return state(.connectionMissing) }
        if service.keySource == .own && !service.hasKey { return state(.needsKey) }
        return state(.ready)
    }

    /// Default service: the saved default id if it is still in the list; otherwise the earliest in storage order; nil if the list is empty.
    /// So the first service added becomes the default automatically, later additions leave the default alone, and deleting the default falls back to the earliest remaining service.
    static func resolveDefaultSearchService(serviceIds: [String], storedDefault: String?) -> String? {
        if let storedDefault, serviceIds.contains(storedDefault) { return storedDefault }
        return serviceIds.first
    }

    /// Sentences on the consent page "Confirm before enabling". A custom service's first sentence is "cannot be verified"; Web adds one more ("forwarded via the web service");
    /// a preset's last sentence is "tested with this key", a custom service's last is "saved only after the test passes".
    static func searchConsentLines(
        kind: SearchSettingsKind,
        platform: SearchClientPlatform,
        serviceName: String?,
        host: String?
    ) -> [SearchConsentLine] {
        let custom = kind == .custom
        var lines: [SearchConsentLine] = []
        if custom { lines.append(SearchConsentLine(key: "customUnverified", args: ["host": host])) }
        lines.append(custom
            ? SearchConsentLine(key: "sendsQueryCustom", args: [:])
            : SearchConsentLine(key: "sendsQuery", args: ["name": serviceName]))
        lines.append(custom
            ? SearchConsentLine(key: "billingCustom", args: [:])
            : SearchConsentLine(key: "billing", args: ["name": serviceName]))
        if platform == .web { lines.append(SearchConsentLine(key: "webForwarded", args: [:])) }
        lines.append(SearchConsentLine(key: custom ? "testOnceSave" : "testOnce", args: [:]))
        return lines
    }

    /// Actions after a failed test on the settings page: of the error card's primary actions only these make sense here; switching service class has no place on the settings page, so it falls back to "Retry".
    private static let testActions: [String: String] = [
        "update_key": "update_key",
        "top_up": "top_up",
        "check_settings": "check_settings",
        "view_setup_guide": "view_setup_guide",
        "reconfirm": "reconfirm",
        "retry": "retry",
        "retry_later": "retry",
        "switch_service": "retry",
    ]

    /// How a test search result is displayed. 0 results still counts as a pass; elapsed time is rounded to 0.1 s. On failure: headline uses the error card's headline key,
    /// action is the settings page action; a revoked service has no action (none).
    static func searchTestPresentation(_ outcome: SearchTestOutcome) -> SearchTestPresentation {
        switch outcome {
        case .passed(let count, let latencyMs):
            let tenths = (Double(max(0, latencyMs)) / 100).rounded(.toNearestOrAwayFromZero)
            return SearchTestPresentation(state: .passed, count: count, latencyTenths: Int(tenths))
        case .failed(let errorClass, let card):
            let action = errorClass == "service_withdrawn" ? "none" : card.flatMap { testActions[$0.primaryAction] } ?? "retry"
            return SearchTestPresentation(
                state: .failed,
                errorClass: errorClass,
                headline: card?.headline ?? "service_error",
                action: action
            )
        }
    }

    // Validation error code -> form field and hint key (`form.*`).
    private static let fieldOf: [String: (field: String, hint: String)] = [
        "name_empty": ("name", "nameEmpty"),
        "name_too_long": ("name", "nameTooLong"),
        "address_invalid": ("address", "addressInvalid"),
        "scheme_not_allowed": ("address", "addressInvalid"),
        "address_has_query": ("address", "addressInvalid"),
        "http_public_not_allowed": ("address", "httpPublic"),
        "http_not_allowed_on_web": ("address", "httpOnWeb"),
        "private_address_on_web": ("address", "privateOnWeb"),
        "port_not_allowed_on_web": ("address", "portOnWeb"),
        "address_unresolved": ("address", "addressUnresolved"),
        "protocol_invalid": ("protocol", "protocolInvalid"),
        "preset_unavailable": ("protocol", "presetUnavailable"),
        "mapping_missing": ("mapping", "mappingIncomplete"),
        "method_invalid": ("method", "mappingIncomplete"),
        "auth_invalid": ("auth", "mappingIncomplete"),
        "header_name_invalid": ("auth", "headerName"),
        "query_field_invalid": ("query", "pathInvalid"),
        "count_field_invalid": ("count", "pathInvalid"),
        "get_has_body": ("method", "getBody"),
        "too_many_static_params": ("params", "tooManyParams"),
        "static_key_invalid": ("params", "pathInvalid"),
        "static_value_invalid": ("params", "paramValue"),
        "template_rejected": ("params", "template"),
        "results_path_invalid": ("results", "pathInvalid"),
        "title_path_invalid": ("title", "pathInvalid"),
        "url_path_invalid": ("url", "pathInvalid"),
        "snippet_path_invalid": ("snippet", "pathInvalid"),
        "site_path_invalid": ("site", "pathInvalid"),
        "date_path_invalid": ("date", "pathInvalid"),
        "path_conflict": ("query", "pathConflict"),
        "key_empty": ("key", "keyEmpty"),
        "key_invalid": ("key", "keyInvalid"),
    ]

    /// Field hints when the custom form's "Continue" / "Save" is pressed. errors = errors from validateCustomSearchService,
    /// plus the normalizeSearchKey error when a key is filled in. Only the first hint is shown per field; cleartext_lan hangs under the address and does not block.
    static func customFormFieldErrors(errors: [String], warnings: [String]) throws -> SearchFormFieldErrors {
        var fields: [String: String] = [:]
        for code in errors {
            guard let hit = fieldOf[code] else { throw SearchSettingsError.unmappedFormError(code) }
            if fields[hit.field] == nil { fields[hit.field] = hit.hint }
        }
        var warningFields: [String: String] = [:]
        if warnings.contains("cleartext_lan") { warningFields["address"] = "cleartextLan" }
        return SearchFormFieldErrors(fields: fields, warnings: warningFields, blocking: !errors.isEmpty)
    }

    /// Saved results per search: anything not among the allowed values (missing, legacy data, hand-edited) falls back to the default 5.
    static func searchResultCount(_ stored: Int?) -> Int {
        stored.flatMap { resultCountChoices.contains($0) ? $0 : nil } ?? resultCountDefault
    }

    /// Service display name: a custom service uses its own name; a preset falls back in order adopted-catalog displayName -> name stored at save time -> serviceId (an empty string counts as absent).
    static func searchServiceDisplayName(kind: SearchSettingsKind, name: String?, serviceId: String?, catalogDisplayName: String?) -> String {
        if kind == .custom { return name ?? "" }
        return [catalogDisplayName, name, serviceId].compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }

    /// Default id the account partition should store after a guest -> account migration: when the account had no services, take the guest's effective default (provided it was actually migrated);
    /// when the account already had services, leave the account's default alone.
    static func migratedDefaultSearchService(
        accountServiceIds: [String],
        guestServiceIds: [String],
        guestStoredDefault: String?,
        migratedIds: [String]
    ) -> SearchMigratedDefault {
        guard accountServiceIds.isEmpty else { return SearchMigratedDefault(set: false) }
        if let guestDefault = resolveDefaultSearchService(serviceIds: guestServiceIds, storedDefault: guestStoredDefault),
           migratedIds.contains(guestDefault) {
            return SearchMigratedDefault(set: true, id: guestDefault)
        }
        return SearchMigratedDefault(set: false)
    }

    /// What happens when "Save" is pressed while editing a saved custom service: a name-only change saves directly; a changed address / protocol / mapping / reference is tested first;
    /// a changed address source clears the key and shows the key field; an unchanged same_as reference reuses the saved snapshot without requiring the preset to be available, while a changed reference re-takes the snapshot and requires the preset to be available.
    static func customServiceEditPlan(before: SearchCustomEditSide, after: SearchCustomEditSide) -> SearchCustomEditPlan {
        let originChanged = SearchTransport.keyBindingOrigin(before.address) != SearchTransport.keyBindingOrigin(after.address)
        let addressChanged = SearchJSText.trim(before.address ?? "") != SearchJSText.trim(after.address ?? "")
        let protocolChanged = before.protocolID != after.protocolID
        let referenceChanged = after.protocolID == "same_as"
            && (protocolChanged || before.presetId != after.presetId || before.regionId != after.regionId)
        let mappingChanged = after.protocolID == "manual"
            && (before.mapping ?? .null).encodedString() != (after.mapping ?? .null).encodedString()
        let needsTest = addressChanged || protocolChanged || referenceChanged || mappingChanged
        return SearchCustomEditPlan(
            mode: needsTest ? .testThenSave : .save,
            clearsKey: originChanged,
            showKeyField: originChanged,
            resnapshot: referenceChanged,
            requirePreset: referenceChanged
        )
    }
}
