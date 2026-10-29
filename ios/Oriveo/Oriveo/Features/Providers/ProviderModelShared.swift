import SwiftUI

enum RelayCatalogMembership {
    static func isMissingEnabledModel(_ model: AIModel, from provider: Provider) -> Bool {
        provider.kind == .relay
            && !model.isManual
            && !provider.catalogModels.isEmpty
            && provider.lastError != ProviderIssueMessage.catalogUnavailableKey
            && !provider.catalogModels.contains {
                ModelResolver.modelsShareSameRemoteModel($0, model, providerKind: provider.kind)
            }
    }

    /// For checking every enabled row: scanning the whole catalog per row costs enabled × catalog
    /// comparisons. Fold the catalog's literal id keys into a set once, then answer each row in
    /// O(1) with the same rule as the linear comparison above.
    struct Index {
        private let isActive: Bool
        private let identifiers: Set<String>

        init(provider: Provider) {
            isActive = provider.kind == .relay
                && !provider.catalogModels.isEmpty
                && provider.lastError != ProviderIssueMessage.catalogUnavailableKey
            guard isActive else {
                identifiers = []
                return
            }
            // Relay only: uses the same literal key as the relay branch of `modelsShareSameRemoteModel`.
            identifiers = IdentifierCache.shared.identifiers(providerID: provider.id, catalog: provider.catalogModels)
        }

        /// The added-models section builds an Index on every body pass, and normalizing the whole
        /// catalog entry by entry is O(catalog size) (relay catalogs can run to tens of thousands).
        /// Enabling or removing a model changes `models`, not the catalog, so the key set of the last
        /// catalog is cached per connection; when the catalog array shares storage, equality takes the
        /// identity fast path. Without the cache, every removal on the model library page re-normalizes
        /// the whole catalog several times on the main thread.
        nonisolated final class IdentifierCache: @unchecked Sendable {
            static let shared = IdentifierCache()

            private let lock = NSLock()
            private var entries: [UUID: (catalog: [AIModel], identifiers: Set<String>)] = [:]
            #if DEBUG
            /// DEBUG only: how many times the whole catalog was normalized again.
            private(set) var debugBuildCount = 0
            #endif

            func identifiers(providerID: UUID, catalog: [AIModel]) -> Set<String> {
                if let hit = lock.withLock({ entries[providerID] }), hit.catalog == catalog {
                    return hit.identifiers
                }
                let identifiers = Set(catalog.map { ModelResolver.relayIdentityKey($0.id) })
                lock.withLock {
                    entries[providerID] = (catalog, identifiers)
                    #if DEBUG
                    debugBuildCount += 1
                    #endif
                }
                return identifiers
            }
        }

        func isMissingEnabledModel(_ model: AIModel) -> Bool {
            guard isActive, !model.isManual else { return false }
            return !identifiers.contains(ModelResolver.relayIdentityKey(model.id))
        }
    }
}

// MARK: - Shared Types

nonisolated struct ProviderCatalogGroup: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let models: [AIModel]
}

nonisolated struct ProviderCatalogSnapshotIdentity: Hashable, Sendable {
    let providerID: UUID
    let providersVersion: UInt
    let metadataContentRevision: UInt64
    let metadataETag: String?
    let recencyBucket: Int

    init(
        providerID: UUID,
        providersVersion: UInt,
        metadataContentRevision: UInt64,
        metadataETag: String?,
        recencyBucket: Int = ProviderCatalogRecency.bucket(at: Date())
    ) {
        self.providerID = providerID
        self.providersVersion = providersVersion
        self.metadataContentRevision = metadataContentRevision
        self.metadataETag = metadataETag
        self.recencyBucket = recencyBucket
    }
}

nonisolated enum ProviderCatalogRecency {
    static let bucketDuration: TimeInterval = 24 * 60 * 60

    static func bucket(at date: Date) -> Int {
        Int(floor(date.timeIntervalSince1970 / bucketDuration))
    }
}

nonisolated struct ProviderCatalogProjectionRequestIdentity: Hashable, Sendable {
    let snapshot: ProviderCatalogSnapshotIdentity
    let normalizedQuery: String

    init(snapshot: ProviderCatalogSnapshotIdentity, searchText: String) {
        self.snapshot = snapshot
        normalizedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only the providers or metadata generation moved (enabling a model with "+", balance refreshes
    /// and sync writes all bump providersVersion) while the provider and search text stayed the same:
    /// this projection can keep showing while the new one is computed in the background. Otherwise
    /// every write swaps the whole catalog for a spinner and rebuilds it, making the page flash and
    /// re-lay out.
    func canStandIn(for current: ProviderCatalogProjectionRequestIdentity) -> Bool {
        snapshot.providerID == current.snapshot.providerID
            && normalizedQuery == current.normalizedQuery
    }
}

nonisolated struct ProviderCatalogProjectionInput: Sendable {
    let providerID: UUID
    let providerKind: ProviderKind
    let providerDisplayName: String
    let enabledModels: [AIModel]
    let catalogModels: [AIModel]
    let priorityScores: [String: Int]
    /// Family per model id (model id -> family id) for relay grouping, resolved once when the input is built, because the projection runs on a background thread and must not touch caches or regexes.
    var relayFamilies: [String: String] = [:]
    /// Localized title of the "Other" group.
    var relayOtherTitle = RelayCatalogGrouping.otherTitleKey
}

/// Relay model-library grouping, shared with the other clients through the `catalog-groups.v1.json` fixture.
/// A model's family comes from the cached server by-model family, falling back to `RelayFamilyHeuristics`. Groups follow the order in which they first appear in the catalog, "Other" comes last, and models inside a group keep catalog order.
/// The model library and step 2 of the add flow share it (both go through `projectProviderCatalogGroups`); official provider groups do not use it.
nonisolated enum RelayCatalogGrouping {
    static let otherID = "other"
    /// Key in the Providers string table.
    static let otherTitleKey = "Other"
    /// Family id -> group title (proper nouns, not translated); a family missing here falls back to its id.
    static let labels: [String: String] = [
        "openai": "OpenAI",
        "anthropic": "Anthropic",
        "google": "Google",
        "deepseek": "DeepSeek",
        "xai": "xAI",
        "qwen": "Qwen",
        "mistral": "Mistral",
        "minimax": "MiniMax",
        "zhipu": "Zhipu",
        "moonshot": "Moonshot",
        "meta": "Meta",
    ]

    struct Group: Equatable, Sendable {
        let id: String
        /// nil means "Other", which is localized at display time.
        let label: String?
        let models: [String]
    }

    /// Relays often prefix model ids with a vendor (`anthropic/claude-x`). When the whole id has no known family, retry with the part after the last `/`. This only affects grouping; the family used for key binding is unchanged.
    static func familyAllowingVendorPrefix(_ id: String, family: (String) -> String?) -> String? {
        if let hit = family(id)?.trimmingCharacters(in: .whitespacesAndNewlines), !hit.isEmpty { return hit }
        guard let slash = id.lastIndex(of: "/") else { return nil }
        let tail = String(id[id.index(after: slash)...])
        return tail.isEmpty ? nil : family(tail)
    }

    static func groups(models: [String], family: (String) -> String?) -> [Group] {
        var order: [String] = []
        var members: [String: [String]] = [:]
        for id in models {
            let familyID = familyAllowingVendorPrefix(id, family: family)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let groupID = familyID?.isEmpty == false ? familyID! : otherID
            if members[groupID] == nil { order.append(groupID) }
            members[groupID, default: []].append(id)
        }
        let ordered = order.filter { $0 != otherID } + (members[otherID] == nil ? [] : [otherID])
        return ordered.map { id in
            Group(id: id, label: id == otherID ? nil : (labels[id] ?? id), models: members[id] ?? [])
        }
    }
}

nonisolated struct ProviderCatalogExpansionSignature: Hashable, Sendable {
    let projection: ProviderCatalogProjectionRequestIdentity
    let groupIDs: [String]
}

nonisolated struct ProviderCatalogExpansionUpdate: Equatable, Sendable {
    let expandedGroupIDs: Set<String>
    let signature: ProviderCatalogExpansionSignature?
    let shouldPersist: Bool
}

nonisolated enum ProviderCatalogExpansionPolicy {
    static func reconcile(
        expandedGroupIDs: Set<String>,
        previousSignature: ProviderCatalogExpansionSignature?,
        projection: ProviderCatalogProjectionRequestIdentity,
        groups: [ProviderCatalogGroup]
    ) -> ProviderCatalogExpansionUpdate {
        guard projection.normalizedQuery.isEmpty else {
            return .init(
                expandedGroupIDs: expandedGroupIDs,
                signature: previousSignature,
                shouldPersist: false
            )
        }

        let signature = ProviderCatalogExpansionSignature(
            projection: projection,
            groupIDs: groups.map(\.id)
        )
        guard signature != previousSignature else {
            return .init(
                expandedGroupIDs: expandedGroupIDs,
                signature: previousSignature,
                shouldPersist: false
            )
        }

        let availableIDs = Set(signature.groupIDs)
        let reconciled = expandedGroupIDs.intersection(availableIDs)
        return .init(
            expandedGroupIDs: reconciled,
            signature: signature,
            shouldPersist: reconciled != expandedGroupIDs
        )
    }
}

actor ProviderCatalogProjectionMemo {
    typealias Projector = @Sendable (ProviderCatalogProjectionInput, String) -> [ProviderCatalogGroup]
    typealias InputBuilder = @Sendable (Provider) -> ProviderCatalogProjectionInput

    static let shared = ProviderCatalogProjectionMemo()

    private let projector: Projector
    private let inputBuilder: InputBuilder
    private let capacity: Int
    private var cache: [ProviderCatalogProjectionRequestIdentity: [ProviderCatalogGroup]] = [:]
    private var insertionOrder: [ProviderCatalogProjectionRequestIdentity] = []
    private var inFlight: [ProviderCatalogProjectionRequestIdentity: Task<[ProviderCatalogGroup], Never>] = [:]
    #if DEBUG
    private var computationCount = 0
    #endif

    init(
        capacity: Int = 12,
        projector: @escaping Projector = { input, searchText in
            projectProviderCatalogGroups(input: input, searchText: searchText)
        },
        inputBuilder: @escaping InputBuilder = { provider in
            makeProviderCatalogProjectionInput(for: provider)
        }
    ) {
        self.capacity = max(1, capacity)
        self.projector = projector
        self.inputBuilder = inputBuilder
    }

    func groups(
        for provider: Provider,
        searchText: String,
        snapshot: ProviderCatalogSnapshotIdentity
    ) async -> [ProviderCatalogGroup] {
        let key = ProviderCatalogProjectionRequestIdentity(snapshot: snapshot, searchText: searchText)
        if let cached = cache[key] { return cached }
        if let task = inFlight[key] { return await task.value }

        let projector = projector
        let inputBuilder = inputBuilder
        let task = Task.detached(priority: .userInitiated) {
            projector(inputBuilder(provider), key.normalizedQuery)
        }
        inFlight[key] = task
        #if DEBUG
        computationCount += 1
        #endif

        let projected = await task.value
        inFlight[key] = nil
        guard !Task.isCancelled else { return projected }

        cache[key] = projected
        insertionOrder.append(key)
        while insertionOrder.count > capacity {
            let expired = insertionOrder.removeFirst()
            cache[expired] = nil
        }
        return projected
    }

    #if DEBUG
    func resetForTesting() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        cache.removeAll()
        insertionOrder.removeAll()
        computationCount = 0
    }

    func computationCountForTesting() -> Int { computationCount }
    #endif
}

struct VendorGroup: Identifiable {
    let id: String
    let groupKey: String?
    let groupName: String?
    let models: [AIModel]
}

struct ProviderModelSpecification: Identifiable, Equatable {
    let id: String
    let label: String?
    let value: String
    let systemImage: String?
    var isSecondary: Bool = false
}

// MARK: - Shared Functions

func groupModelsByVendor(provider: Provider, models: [AIModel]) -> [VendorGroup] {
    let explicitGroups = Dictionary(grouping: models.compactMap { model -> ((id: String, title: String), AIModel)? in
        guard let identity = explicitVendorGroupIdentity(for: model) else {
            return nil
        }
        return (identity, model)
    }) { item in
        item.0.id
    }

    guard !explicitGroups.isEmpty else {
        return [
            VendorGroup(
                id: provider.id.uuidString,
                groupKey: nil,
                groupName: nil,
                models: models
            ),
        ]
    }

    let mappedGroups = explicitGroups.map { key, items in
        let groupModels = items.map(\.1)
        let identity = items.first!.0
        return VendorGroup(
            id: key,
            groupKey: identity.id,
            groupName: identity.title,
            models: groupModels
        )
    }

    var groups: [VendorGroup]
    if provider.kind.usesServerOrderedModels {
        let firstIndexByGroup = firstAppearanceIndexByVendorGroup(models)
        groups = mappedGroups.sorted { lhs, rhs in
            (firstIndexByGroup[lhs.id] ?? .max) < (firstIndexByGroup[rhs.id] ?? .max)
        }
    } else {
        let priorityScores = catalogPriorityScores(for: models, provider: provider)
        var groupScores: [String: Int] = [:]
        groupScores.reserveCapacity(mappedGroups.count)
        for group in mappedGroups {
            groupScores[group.id] = catalogGroupScore(for: group.models, priorityScores: priorityScores)
        }
        groups = mappedGroups.sorted { lhs, rhs in
            let lhsScore = groupScores[lhs.id] ?? 0
            let rhsScore = groupScores[rhs.id] ?? 0
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }
            return (lhs.groupName ?? "").localizedStandardCompare(rhs.groupName ?? "") == .orderedAscending
        }
    }

    let ungroupedModels = models.filter { explicitVendorGroupIdentity(for: $0) == nil }
    if !ungroupedModels.isEmpty {
        groups.append(
            VendorGroup(
                id: "\(provider.id.uuidString)-ungrouped",
                groupKey: nil,
                groupName: nil,
                models: ungroupedModels
            )
        )
    }

    return groups
}

/// Provider detail must preserve the order delivered by catalog. Managed catalogs already arrive
/// ordered by group.sort_order and model.sort_order, so re-scoring here would make an Admin change
/// require a client release to take effect.
func detailEnabledModelGroups(for provider: Provider) -> [VendorGroup] {
    var groups: [VendorGroup] = []
    var groupIndexes: [String: Int] = [:]

    for model in provider.models {
        guard let identity = explicitVendorGroupIdentity(for: model) else {
            let fallbackID = "\(provider.id.uuidString)-ungrouped"
            if let index = groupIndexes[fallbackID] {
                groups[index] = VendorGroup(
                    id: groups[index].id,
                    groupKey: nil,
                    groupName: nil,
                    models: groups[index].models + [model]
                )
            } else {
                groupIndexes[fallbackID] = groups.count
                groups.append(VendorGroup(id: fallbackID, groupKey: nil, groupName: nil, models: [model]))
            }
            continue
        }

        if let index = groupIndexes[identity.id] {
            groups[index] = VendorGroup(
                id: groups[index].id,
                groupKey: identity.id,
                groupName: identity.title,
                models: groups[index].models + [model]
            )
        } else {
            groupIndexes[identity.id] = groups.count
            groups.append(
                VendorGroup(
                    id: identity.id,
                    groupKey: identity.id,
                    groupName: identity.title,
                    models: [model]
                )
            )
        }
    }

    return groups
}

func providerModelSpecifications(for model: AIModel) -> [ProviderModelSpecification] {
    var specifications: [ProviderModelSpecification] = []

    if let context = CatalogModelBuilder.compactContextText(model.contextLength) {
        specifications.append(
            ProviderModelSpecification(
                id: "context",
                label: nil,
                value: context,
                systemImage: "memorychip"
            )
        )
    }

    if let value = perMillionPriceText(fromPerToken: model.promptPrice, currencyCode: model.priceCurrencyCode) {
        specifications.append(.init(id: "input", label: L10n.tr("Input", table: .chat), value: value, systemImage: nil))
    }
    if let value = perMillionPriceText(fromPerToken: model.completionPrice, currencyCode: model.priceCurrencyCode) {
        specifications.append(.init(id: "output", label: L10n.tr("Output", table: .chat), value: value, systemImage: nil))
    }
    if let value = perMillionPriceText(fromPerMillion: model.cacheReadInputPerMToken, currencyCode: model.priceCurrencyCode) {
        specifications.append(.init(id: "cache-read", label: L10n.tr("Cache read", table: .chat), value: value, systemImage: nil, isSecondary: true))
    }

    let cacheWrite = model.cacheWrite5mPerMToken ?? model.cacheCreationInputPerMToken
    if let value = perMillionPriceText(fromPerMillion: cacheWrite, currencyCode: model.priceCurrencyCode) {
        let suffix = model.cacheWrite5mPerMToken == nil ? "" : " 5m"
        specifications.append(
            .init(
                id: "cache-write",
                label: L10n.tr("Cache write", table: .chat) + suffix,
                value: value,
                systemImage: nil,
                isSecondary: true
            )
        )
    }
    if let value = perMillionPriceText(fromPerMillion: model.cacheWrite1hPerMToken, currencyCode: model.priceCurrencyCode) {
        specifications.append(
            .init(
                id: "cache-write-1h",
                label: L10n.tr("Cache write", table: .chat) + " 1h",
                value: value,
                systemImage: nil,
                isSecondary: true
            )
        )
    }

    return specifications
}

struct ProviderModelSpecInline: View {
    let specifications: [ProviderModelSpecification]

    init(model: AIModel) {
        specifications = providerModelSpecifications(for: model)
    }

    init(specifications: [ProviderModelSpecification]) {
        self.specifications = specifications
    }

    var body: some View {
        let primary = specifications.filter { !$0.isSecondary }
        let secondary = specifications.filter { $0.isSecondary }

        if !primary.isEmpty || !secondary.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if !primary.isEmpty {
                    specLine(for: primary)
                }
                if !secondary.isEmpty {
                    specLine(for: secondary)
                }
            }
        }
    }

    private func specLine(for items: [ProviderModelSpecification]) -> some View {
        buildText(for: items)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func buildText(for items: [ProviderModelSpecification]) -> Text {
        let separator = Text("  ·  ")
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(OriveoTheme.Palette.textTertiary.opacity(0.7))

        var result = Text("")
        for (index, spec) in items.enumerated() {
            if index > 0 {
                result = result + separator
            }
            if let systemImage = spec.systemImage {
                result = result
                    + Text(Image(systemName: systemImage))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    + Text(" ")
            }
            if let label = spec.label {
                result = result
                    + Text(label + " ")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
            }
            result = result
                + Text(spec.value)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .monospacedDigit()
        }
        return result
    }
}

private func perMillionPriceText(fromPerToken price: Double?, currencyCode: String?) -> String? {
    guard let price, price.isFinite, price > 0 else { return nil }
    let formatted = CostFormatter.formatPerMillion(price, currencyCode: currencyCode, locale: AppLocalization.currentLocale)
    return formatted.isEmpty ? nil : formatted
}

private func perMillionPriceText(fromPerMillion price: Double?, currencyCode: String?) -> String? {
    guard let price, price.isFinite, price > 0 else { return nil }
    let formatted = CostFormatter.formatPerMillion(
        price / 1_000_000, currencyCode: currencyCode, locale: AppLocalization.currentLocale
    )
    return formatted.isEmpty ? nil : formatted
}

func pickerModelSort(_ lhs: AIModel, _ rhs: AIModel) -> Bool {
    if lhs.isDefault != rhs.isDefault {
        return lhs.isDefault && !rhs.isDefault
    }
    if lhs.isAvailable != rhs.isAvailable {
        return lhs.isAvailable && !rhs.isAvailable
    }

    let lhsGroup = lhs.groupName ?? ""
    let rhsGroup = rhs.groupName ?? ""
    if lhsGroup != rhsGroup {
        return lhsGroup.localizedStandardCompare(rhsGroup) == .orderedAscending
    }

    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
}

func catalogPriorityScore(for model: AIModel, provider: Provider) -> Int {
    if let rank = model.sortRank { return rank }

    var score = 0

    if model.isAvailable {
        score += 180
    }
    let evidence = ModelCapabilityEvidencePresentation(provider: provider, model: model)
    if evidence.permitsDisplay(.reasoning) {
        score += 28
    }
    if evidence.permitsDisplay(.image) {
        score += 18
    }
    if evidence.permitsDisplay(.file) {
        score += 12
    }
    if evidence.permitsDisplay(.web) {
        score += 8
    }
    if model.promptPrice == 0 || model.completionPrice == 0 {
        score += 4
    }

    return score + recencyScore(for: model.createdAt)
}

func catalogModelSort(
    lhs: AIModel,
    rhs: AIModel,
    provider: Provider,
    priorityScores: [String: Int]? = nil
) -> Bool {
    if lhs.isAvailable != rhs.isAvailable {
        return lhs.isAvailable && !rhs.isAvailable
    }

    let lhsRank = lhs.sortRank ?? 0
    let rhsRank = rhs.sortRank ?? 0
    if lhsRank != rhsRank {
        return lhsRank > rhsRank
    }

    let lhsPriority = priorityScores?[lhs.id] ?? catalogPriorityScore(for: lhs, provider: provider)
    let rhsPriority = priorityScores?[rhs.id] ?? catalogPriorityScore(for: rhs, provider: provider)
    if lhsPriority != rhsPriority {
        return lhsPriority > rhsPriority
    }

    if let comparison = createdAtComparison(lhs.createdAt, rhs.createdAt),
       comparison != .orderedSame {
        return comparison == .orderedDescending
    }

    let lhsIdentifier = lhs.canonicalModelId ?? lhs.id
    let rhsIdentifier = rhs.canonicalModelId ?? rhs.id
    return lhsIdentifier.localizedStandardCompare(rhsIdentifier) == .orderedAscending
}

nonisolated private func projectedCatalogModelSort(
    lhs: AIModel,
    rhs: AIModel,
    priorityScores: [String: Int]
) -> Bool {
    if lhs.isAvailable != rhs.isAvailable {
        return lhs.isAvailable && !rhs.isAvailable
    }
    let lhsRank = lhs.sortRank ?? 0
    let rhsRank = rhs.sortRank ?? 0
    if lhsRank != rhsRank { return lhsRank > rhsRank }

    let lhsPriority = priorityScores[lhs.id] ?? 0
    let rhsPriority = priorityScores[rhs.id] ?? 0
    if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }

    if let comparison = createdAtComparison(lhs.createdAt, rhs.createdAt),
       comparison != .orderedSame {
        return comparison == .orderedDescending
    }
    return (lhs.canonicalModelId ?? lhs.id).localizedStandardCompare(
        rhs.canonicalModelId ?? rhs.id
    ) == .orderedAscending
}

func sortedEnabledModels(for provider: Provider) -> [AIModel] {
    guard !provider.kind.usesServerOrderedModels else { return provider.models }
    // A relay has no default model, so keep the enabled order instead of reordering.
    guard provider.kind != .relay else { return provider.models }

    let priorityScores = catalogPriorityScores(for: provider.models, provider: provider)
    return provider.models.sorted { lhs, rhs in
        if lhs.isDefault != rhs.isDefault {
            return lhs.isDefault && !rhs.isDefault
        }
        if lhs.isAvailable != rhs.isAvailable {
            return lhs.isAvailable && !rhs.isAvailable
        }

        let lhsScore = priorityScores[lhs.id] ?? 0
        let rhsScore = priorityScores[rhs.id] ?? 0
        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }

        if let comparison = createdAtComparison(lhs.createdAt, rhs.createdAt),
           comparison != .orderedSame {
            return comparison == .orderedDescending
        }

        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

func makeProviderCatalogProjectionInput(for provider: Provider) -> ProviderCatalogProjectionInput {
    let resolved = ProviderCatalogResolver.resolve(provider: provider)
    let catalogSource = resolved.catalog.isEmpty && !provider.catalogModels.isEmpty
        ? provider.catalogModels
        : resolved.catalog.map(\.model)
    let dedupedCatalog = CatalogModelBuilder.deduplicate(catalogSource, providerKind: provider.kind)
    var input = ProviderCatalogProjectionInput(
        providerID: provider.id,
        providerKind: provider.kind,
        providerDisplayName: provider.displayName,
        enabledModels: provider.models,
        catalogModels: dedupedCatalog,
        // Relay grouping follows catalog order and never reads scores; scoring capability evidence per model on a catalog of thousands blocks the main thread for seconds.
        priorityScores: provider.kind == .relay
            ? [:]
            : catalogPriorityScores(for: dedupedCatalog, provider: provider)
    )
    if provider.kind == .relay {
        input.relayFamilies = dedupedCatalog.reduce(into: [:]) { families, model in
            let family = MetadataClient.shared.cachedRelayModelFamilyNow(for: model.id)
                ?? RelayFamilyHeuristics.infer(modelID: model.id)?.rawValue
            if let family { families[model.id] = family }
        }
        input.relayOtherTitle = L10n.tr(RelayCatalogGrouping.otherTitleKey, table: .providers)
    }
    return input
}

func buildProviderCatalogGroups(
    for provider: Provider,
    searchText: String
) -> [ProviderCatalogGroup] {
    projectProviderCatalogGroups(
        input: makeProviderCatalogProjectionInput(for: provider),
        searchText: searchText
    )
}

nonisolated func projectProviderCatalogGroups(
    input: ProviderCatalogProjectionInput,
    searchText: String
) -> [ProviderCatalogGroup] {
    let normalizedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let availableCatalogModels = input.catalogModels.filter { model in
        guard !input.enabledModels.contains(where: {
            ModelResolver.modelsShareSameRemoteModel($0, model, providerKind: input.providerKind)
        }) else {
            return false
        }
        return true
    }
    if input.providerKind == .relay {
        return projectRelayCatalogGroups(input: input, models: availableCatalogModels, normalizedQuery: normalizedQuery)
    }
    let groupScoresByID = Dictionary(
        grouping: input.catalogModels,
        by: { catalogGroupIdentity(for: $0, fallbackID: input.providerKind.rawValue, fallbackTitle: input.providerDisplayName).id }
    )
    .mapValues { catalogGroupScore(for: $0, priorityScores: input.priorityScores) }

    let groupedModels = Dictionary(grouping: availableCatalogModels) { model in
        catalogGroupIdentity(
            for: model,
            fallbackID: input.providerKind.rawValue,
            fallbackTitle: input.providerDisplayName
        ).id
    }

    return groupedModels.compactMap { groupID, models in
        let title = models.first.map {
            catalogGroupIdentity(
                for: $0,
                fallbackID: input.providerKind.rawValue,
                fallbackTitle: input.providerDisplayName
            ).title
        } ?? input.providerDisplayName
        let filteredModels = normalizedQuery.isEmpty
            ? models
            : filterModelsWithinGroup(models, normalizedQuery: normalizedQuery, title: title, groupID: groupID)
        guard !filteredModels.isEmpty else { return nil }

        return ProviderCatalogGroup(
            id: groupID,
            title: title,
            models: filteredModels.sorted { lhs, rhs in
                projectedCatalogModelSort(
                    lhs: lhs,
                    rhs: rhs,
                    priorityScores: input.priorityScores
                )
            }
        )
    }
    .sorted { lhs, rhs in
        let lhsScore = groupScoresByID[lhs.id]
            ?? catalogGroupScore(for: lhs.models, priorityScores: input.priorityScores)
        let rhsScore = groupScoresByID[rhs.id]
            ?? catalogGroupScore(for: rhs.models, priorityScores: input.priorityScores)

        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }

        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}

/// Relay: groups come from `RelayCatalogGrouping`; group order and in-group order both follow the catalog and are never re-ranked by score.
nonisolated private func projectRelayCatalogGroups(
    input: ProviderCatalogProjectionInput,
    models: [AIModel],
    normalizedQuery: String
) -> [ProviderCatalogGroup] {
    let byID = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return RelayCatalogGrouping.groups(models: models.map(\.id)) { input.relayFamilies[$0] }
        .compactMap { group in
            let title = group.label ?? input.relayOtherTitle
            let members = group.models.compactMap { byID[$0] }
            let filtered = normalizedQuery.isEmpty
                ? members
                : filterModelsWithinGroup(members, normalizedQuery: normalizedQuery, title: title, groupID: group.id)
            return filtered.isEmpty ? nil : ProviderCatalogGroup(id: group.id, title: title, models: filtered)
        }
}

func shouldAutoExpandProviderCatalogGroups(searchText: String) -> Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

func sortedProvidersForModelPicker(_ providers: [Provider]) -> [Provider] {
    let scores = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, pickerProviderScore(for: $0)) })
    return providers.sorted { lhs, rhs in
        let lhsScore = scores[lhs.id] ?? 0
        let rhsScore = scores[rhs.id] ?? 0
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
}

nonisolated func recencyScore(for createdAt: TimeInterval?) -> Int {
    guard let createdAt else { return 0 }

    let age = max(0, Date().timeIntervalSince1970 - createdAt)
    let day: TimeInterval = 24 * 60 * 60

    switch age {
    case ..<(30 * day):
        return 24
    case ..<(90 * day):
        return 16
    case ..<(180 * day):
        return 8
    case ..<(365 * day):
        return 3
    default:
        return 0
    }
}

nonisolated func createdAtComparison(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> ComparisonResult? {
    switch (lhs, rhs) {
    case let (lhs?, rhs?):
        if lhs == rhs {
            return .orderedSame
        }
        return lhs > rhs ? .orderedDescending : .orderedAscending
    case (_?, nil):
        return .orderedDescending
    case (nil, _?):
        return .orderedAscending
    case (nil, nil):
        return nil
    }
}

func recencyBadge(for model: AIModel) -> ModelRecency? {
    ModelRecency.from(createdAt: model.createdAt)
}

nonisolated private func catalogGroupIdentity(
    for model: AIModel,
    fallbackID: String,
    fallbackTitle: String
) -> (id: String, title: String) {
    return (
        id: model.groupKey ?? fallbackID,
        title: model.groupName ?? fallbackTitle
    )
}

private func explicitVendorGroupIdentity(for model: AIModel) -> (id: String, title: String)? {
    guard let groupKey = model.groupKey?.trimmingCharacters(in: .whitespacesAndNewlines),
          !groupKey.isEmpty,
          let groupName = model.groupName?.trimmingCharacters(in: .whitespacesAndNewlines),
          !groupName.isEmpty else {
        return nil
    }

    return (id: groupKey, title: groupName)
}

private func firstAppearanceIndexByVendorGroup(_ models: [AIModel]) -> [String: Int] {
    var indexes: [String: Int] = [:]
    for (index, model) in models.enumerated() {
        guard let identity = explicitVendorGroupIdentity(for: model),
              indexes[identity.id] == nil else {
            continue
        }
        indexes[identity.id] = index
    }
    return indexes
}

private func catalogPriorityScores(
    for models: [AIModel],
    provider: Provider
) -> [String: Int] {
    models.reduce(into: [:]) { scores, model in
        scores[model.id] = catalogPriorityScore(for: model, provider: provider)
    }
}

nonisolated private func catalogGroupScore(
    for models: [AIModel],
    priorityScores: [String: Int]
) -> Int {
    let rankedScores = models
        .map { priorityScores[$0.id] ?? 0 }
        .sorted(by: >)
    let first = rankedScores.indices.contains(0) ? rankedScores[0] : 0
    let second = rankedScores.indices.contains(1) ? rankedScores[1] : 0
    let third = rankedScores.indices.contains(2) ? rankedScores[2] : 0

    return first * 10_000 + second * 100 + third
}

private func pickerProviderScore(for provider: Provider) -> Int {
    let models = provider.models
    let scores = catalogPriorityScores(for: models, provider: provider)
    let bestScore = scores.values.max() ?? 0
    var score = bestScore
    if preferredEnabledModel(for: provider)?.isAvailable == true {
        score += 80
    }
    score += min(models.count, 24)
    return score
}

private func preferredEnabledModel(for provider: Provider) -> AIModel? {
    provider.defaultModel
}

nonisolated private func filterModelsWithinGroup(
    _ models: [AIModel],
    normalizedQuery: String,
    title: String,
    groupID: String
) -> [AIModel] {
    let groupMatches = title.localizedCaseInsensitiveContains(normalizedQuery) ||
        groupID.localizedCaseInsensitiveContains(normalizedQuery)

    if groupMatches {
        return models
    }

    return models.filter { model in
        model.name.localizedCaseInsensitiveContains(normalizedQuery) ||
        model.id.localizedCaseInsensitiveContains(normalizedQuery) ||
        (model.summary?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
    }
}

// MARK: - Panel Slices

/// Once a card / panel is flattened into sibling subviews, the position of each slice within the whole card (one scroll axis may host only one lazy stack,
/// so a card can no longer be a VStack wrapping an inner LazyVStack). Each slice reports only its bounds; the host lazy container draws the whole-card look once per group.
enum ProviderPanelSlice: Equatable {
    case single
    case first
    case middle
    case last

    init(index: Int, count: Int) {
        if count <= 1 {
            self = .single
        } else if index == 0 {
            self = .first
        } else if index == count - 1 {
            self = .last
        } else {
            self = .middle
        }
    }

    var closesTop: Bool { self == .single || self == .first }
    var closesBottom: Bool { self == .single || self == .last }
}

/// The part of the whole-card rounded rectangle that belongs to this slice: only the closed edge carries rounded corners (used to clip the content of each row of the added panel).
struct ProviderPanelSliceShape: Shape {
    let slice: ProviderPanelSlice
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let top = slice.closesTop ? radius : 0
        let bottom = slice.closesBottom ? radius : 0
        return UnevenRoundedRectangle(
            topLeadingRadius: top,
            bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom,
            topTrailingRadius: top,
            style: .continuous
        )
        .path(in: rect)
    }
}

/// How the whole-card look is drawn: one definition shared by a group of slices, drawn once per card bounds by `providerPanelGroupSurfaces()` on the host lazy container.
enum ProviderPanelGroupStyle: Equatable {
    /// Catalog group card: drawn the same as `oriveoRoundedSurface(fill: surfaceElevated, radius: lg)`;
    /// on the relay / local model library pages there is no outline and no shadow.
    case catalogCard(flat: Bool)
    /// Added-models panel: fill + inner outline on the rounded corners + one soft shadow; on the relay / local model library pages there is no outline and no shadow.
    case enabledPanel(flat: Bool)
}

/// The bounds of one slice within its whole card. A slice reports only this, never fill / outline / shadow / highlight.
struct ProviderPanelGroupFragment {
    let groupID: String
    let style: ProviderPanelGroupStyle
    /// The index of this slice in the whole card and the card's slice count (catalog card: 0 = group header, the rest are rows).
    let index: Int
    let count: Int
    let bounds: Anchor<CGRect>

    var slice: ProviderPanelSlice { ProviderPanelSlice(index: index, count: count) }
}

/// The bounds of the slices built so far in the lazy container, collected in order of appearance; the container receives values only for built slices.
struct ProviderPanelGroupBoundsKey: PreferenceKey {
    static var defaultValue: [ProviderPanelGroupFragment] { [] }

    static func reduce(value: inout [ProviderPanelGroupFragment], nextValue: () -> [ProviderPanelGroupFragment]) {
        value.append(contentsOf: nextValue())
    }
}

/// Where one whole card sits in the host container's coordinates: the union of the bounds of its built slices; when the first / last slice is not built (outside the viewport) it extends out of the viewport on that side.
struct ProviderPanelGroupCard: Identifiable {
    /// How far to extend toward an unbuilt first / last slice: the lazy stack recycles only slices entirely outside the viewport,
    /// so the open edge of the outermost built slice is at least flush with the viewport edge, and extending beyond the corner radius + shadow range puts that side's corners and shadow outside the viewport.
    static let unbuiltEdgeOverhang: CGFloat = 200

    let id: String
    let style: ProviderPanelGroupStyle
    var frame: CGRect
    var closesTop: Bool
    var closesBottom: Bool

    /// The rectangle the highlight gradient spans: from the nominal top edge of the whole card, at the nominal height, not stretching with the built slices.
    /// The card `frame` is only the union of the built slices (plus the extension on the unbuilt side) and changes with slices being built / recycled while scrolling; a gradient spread over it
    /// would stretch / squash as the same card scrolls.
    var highlightFrame: CGRect

    /// Nominal geometry: the group header (14pt padding above and below + two title lines), a catalog row (minimum height of a nested row), the hairline between slices.
    static let nominalHeaderHeight: CGFloat = 72
    static let nominalRowHeight: CGFloat = 62
    static let nominalHairline: CGFloat = 0.5

    /// The nominal distance from the top edge of slice `index` to the top edge of the whole card. The header slice includes the hairline under the header, a row slice includes the hairline under the row.
    static func nominalOffset(ofSlice index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        return nominalHeaderHeight + nominalHairline + CGFloat(index - 1) * (nominalRowHeight + nominalHairline)
    }

    /// "Group header + row count x nominal row height + hairlines": determined only by the slice count.
    static func nominalHeight(sliceCount count: Int) -> CGFloat {
        let rows = max(count - 1, 0)
        guard rows > 0 else { return nominalHeaderHeight }
        return nominalHeaderHeight + nominalHairline + CGFloat(rows) * nominalRowHeight + CGFloat(rows - 1) * nominalHairline
    }

    static func cards(from fragments: [ProviderPanelGroupFragment], in proxy: GeometryProxy) -> [ProviderPanelGroupCard] {
        var order: [String] = []
        var cardsByID: [String: ProviderPanelGroupCard] = [:]
        /// The built slice with the smallest index per card: the nominal top edge is derived back from it.
        var anchorsByID: [String: (index: Int, minY: CGFloat, count: Int)] = [:]
        for fragment in fragments {
            let rect = proxy[fragment.bounds]
            if anchorsByID[fragment.groupID].map({ fragment.index < $0.index }) ?? true {
                anchorsByID[fragment.groupID] = (fragment.index, rect.minY, fragment.count)
            }
            if var card = cardsByID[fragment.groupID] {
                card.frame = card.frame.union(rect)
                card.closesTop = card.closesTop || fragment.slice.closesTop
                card.closesBottom = card.closesBottom || fragment.slice.closesBottom
                cardsByID[fragment.groupID] = card
            } else {
                order.append(fragment.groupID)
                cardsByID[fragment.groupID] = ProviderPanelGroupCard(
                    id: fragment.groupID,
                    style: fragment.style,
                    frame: rect,
                    closesTop: fragment.slice.closesTop,
                    closesBottom: fragment.slice.closesBottom,
                    highlightFrame: .null
                )
            }
        }
        return order.compactMap { id in
            guard var card = cardsByID[id], let anchor = anchorsByID[id] else { return nil }
            card.highlightFrame = CGRect(
                x: card.frame.minX,
                y: anchor.minY - nominalOffset(ofSlice: anchor.index),
                width: card.frame.width,
                height: nominalHeight(sliceCount: anchor.count)
            )
            if !card.closesTop {
                card.frame.origin.y -= unbuiltEdgeOverhang
                card.frame.size.height += unbuiltEdgeOverhang
            }
            if !card.closesBottom {
                card.frame.size.height += unbuiltEdgeOverhang
            }
            return card
        }
    }
}

/// One layer on the host container: the background layer draws fill / highlight / shadow, the overlay layer draws the outline (above the content, as before the flattening).
private struct ProviderPanelGroupLayer: View {
    let cards: [ProviderPanelGroupCard]
    let part: ProviderPanelGroupSurface.Part

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(cards) { card in
                ProviderPanelGroupSurface(
                    style: card.style,
                    part: part,
                    size: card.frame.size,
                    highlight: card.highlightFrame.offsetBy(dx: -card.frame.minX, dy: -card.frame.minY)
                )
                    .frame(width: card.frame.width, height: card.frame.height)
                    .offset(x: card.frame.minX, y: card.frame.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The look of one whole card, with parameters matching the pre-flattening whole-card drawing one for one.
private struct ProviderPanelGroupSurface: View {
    enum Part {
        case background
        case overlay
    }

    let style: ProviderPanelGroupStyle
    let part: Part
    /// The size of this card, and the rectangle of the highlight gradient in this card's local coordinates (see `ProviderPanelGroupCard.highlightFrame`).
    let size: CGSize
    let highlight: CGRect

    @Environment(\.colorScheme) private var colorScheme

    /// A top-leading to bottom-trailing gradient whose start and end points sit at the two corners of `highlight` (unit coordinates relative to this card); beyond the end point the last color (transparent) continues.
    /// Still a single `shape.fill`, with no extra clipping layer added for the highlight.
    private func highlightGradient(_ colors: [Color]) -> some View {
        let measurable = size.width > 0 && size.height > 0
        let start = measurable
            ? UnitPoint(x: highlight.minX / size.width, y: highlight.minY / size.height)
            : .topLeading
        let end = measurable
            ? UnitPoint(x: highlight.maxX / size.width, y: highlight.maxY / size.height)
            : .bottomTrailing
        return shape.fill(LinearGradient(colors: colors, startPoint: start, endPoint: end))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
    }

    var body: some View {
        let dark = colorScheme == .dark
        switch (style, part) {
        case let (.catalogCard(flat), .background):
            shape
                .fill(OriveoTheme.Palette.surfaceElevated)
                .overlay(highlightGradient([OriveoTheme.Palette.cardHighlight, Color.clear]))
                .shadow(
                    color: flat ? .clear : OriveoTheme.Palette.shadow,
                    radius: flat ? 0 : (dark ? 16 : 8),
                    y: flat ? 0 : (dark ? 10 : 6)
                )
                .shadow(
                    color: flat ? .clear : OriveoTheme.Palette.shadow.opacity(0.6),
                    radius: flat ? 0 : 2,
                    y: flat ? 0 : 1
                )
        case let (.catalogCard(flat), .overlay):
            shape
                .stroke(flat ? Color.clear : OriveoTheme.Palette.border.opacity(0.66), lineWidth: 1)
                .overlay {
                    if dark {
                        shape
                            .stroke(OriveoTheme.Palette.hairline, lineWidth: 0.6)
                            .blur(radius: 0.4)
                            .mask(highlightGradient([.white, .white.opacity(0)]))
                    }
                }
        case let (.enabledPanel(flat), .background):
            shape
                .fill(OriveoTheme.Palette.surfaceElevated)
                .shadow(
                    color: flat ? .clear : OriveoTheme.Palette.shadow.opacity(dark ? 0.45 : 0.55),
                    radius: flat ? 0 : 12,
                    x: 0,
                    y: flat ? 0 : 6
                )
        case let (.enabledPanel(flat), .overlay):
            // The outline sits inside the corner clipping: only the inner half of the line width remains.
            shape
                .stroke(flat ? Color.clear : OriveoTheme.Palette.border.opacity(0.72), lineWidth: 1)
                .clipShape(shape)
        }
    }
}

extension View {
    /// A slice reports its own bounds within the whole card (by group id); the look is drawn by the host lazy container.
    func providerPanelSlice(
        index: Int,
        count: Int,
        group groupID: String,
        style: ProviderPanelGroupStyle
    ) -> some View {
        anchorPreference(key: ProviderPanelGroupBoundsKey.self, value: .bounds) { anchor in
            [ProviderPanelGroupFragment(groupID: groupID, style: style, index: index, count: count, bounds: anchor)]
        }
    }

    /// Attached to the host's single lazy container: reads the slice-bounds preference and draws each group's look once per whole-card bounds
    /// (background layer: fill / highlight / shadow; overlay layer: outline, which does not receive taps). It only reads the preference and writes no view state.
    func providerPanelGroupSurfaces() -> some View {
        backgroundPreferenceValue(ProviderPanelGroupBoundsKey.self) { fragments in
            GeometryReader { proxy in
                ProviderPanelGroupLayer(cards: ProviderPanelGroupCard.cards(from: fragments, in: proxy), part: .background)
            }
        }
        .overlayPreferenceValue(ProviderPanelGroupBoundsKey.self) { fragments in
            GeometryReader { proxy in
                ProviderPanelGroupLayer(cards: ProviderPanelGroupCard.cards(from: fragments, in: proxy), part: .overlay)
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Shared Catalog Group Views

/// The catalog group list. **It hosts no lazy stack of its own**: it produces only sibling subviews (group headers, rows), placed lazily row by row by the host's single `LazyVStack`
/// (the detail page's outer container / the home "Add model" page / the test host).
/// Previously each group was "VStack card -> inner LazyVStack" nested in the outer LazyVStack: on iOS 26 lazy allocation of nested lazy stacks has a race,
/// and closing the keyboard after a search expanded everything could freeze the main thread permanently (confirmed by Apple DTS).
/// The host's spacing must be 0: the gap between groups is given explicitly here (`leadingSpacing` above the first group, `Spacing.sm` for the rest).
/// Each slice reports only the whole-card bounds, and the host lazy container must attach `providerPanelGroupSurfaces()` to draw the whole-card look.
struct ProviderCatalogGroupList: View {
    let provider: Provider
    let capabilityEvidenceRevision: UInt64
    let groups: [ProviderCatalogGroup]
    let searchText: String
    let expandedGroupIDs: Set<String>
    let coordinateSpaceName: String?
    /// Passed only by the relay / local model-library subpages; the home "Add model" page and
    /// official providers always leave it nil.
    var catalogBoard: RelayCatalogBoardContext? = nil
    /// The spacing above the first group: between the block placed before the list in the host and the first group.
    var leadingSpacing: CGFloat = 0
    var onToggleGroup: (String) -> Void
    /// The second argument is the frame of the tapped row in `coordinateSpaceName` (`.null` = unavailable),
    /// taken once at the moment of the tap to set the start point of the fly-in animation.
    var onAddModel: (AIModel, CGRect) -> Void
    /// Tapping a catalog row on the board (read-only advanced page); nil means a tap enables the model.
    var onOpenModel: ((AIModel) -> Void)? = nil
    /// "Add All" on a board group header; nil hides it (home "Add model" page and official providers).
    var onEnableAllInGroup: ((ProviderCatalogGroup) -> Void)? = nil

    @State private var rowFrames = CatalogRowFrameStore()

    var body: some View {
        let autoExpands = shouldAutoExpandProviderCatalogGroups(searchText: searchText)
        let firstGroupID = groups.first?.id
        let style = ProviderPanelGroupStyle.catalogCard(flat: catalogBoard != nil)
        // Group headers and catalog rows are siblings in the host's single lazy stack, so identities are namespaced: a family id (qwen / deepseek / other) may equal
        // a model id, and using the raw id would collide and make the lazy stack reuse the old view (the added section uses "enabled:"). Expansion state and group keys still use the raw id.
        ForEach(groups, id: \.headerRowIdentity) { group in
            let isExpanded = autoExpands || expandedGroupIDs.contains(group.id)
            let sliceCount = isExpanded ? group.models.count + 1 : 1
            let cardID = "catalog:\(group.id)"

            ProviderCatalogGroupHeader(
                provider: provider,
                group: group,
                isExpanded: isExpanded,
                canToggle: !autoExpands,
                catalogBoard: catalogBoard,
                onToggle: { onToggleGroup(group.id) },
                onEnableAll: onEnableAllInGroup.map { enableAll in { enableAll(group) } }
            )
            .providerPanelSlice(index: 0, count: sliceCount, group: cardID, style: style)
            .padding(.top, group.id == firstGroupID ? leadingSpacing : OriveoTheme.Spacing.sm)

            if isExpanded {
                ForEach(Array(group.models.enumerated()), id: \.element.catalogRowIdentity) { index, model in
                    ProviderCatalogGroupRow(
                        provider: provider,
                        capabilityEvidenceRevision: capabilityEvidenceRevision,
                        model: model,
                        showsDivider: index < group.models.count - 1,
                        coordinateSpaceName: coordinateSpaceName,
                        rowFrames: rowFrames,
                        catalogBoard: catalogBoard,
                        onAddModel: onAddModel,
                        onOpenModel: onOpenModel
                    )
                    .providerPanelSlice(index: index + 1, count: sliceCount, group: cardID, style: style)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

struct ProviderCatalogGroupHeader: View {
    let provider: Provider
    let group: ProviderCatalogGroup
    let isExpanded: Bool
    let canToggle: Bool
    let catalogBoard: RelayCatalogBoardContext?
    var onToggle: () -> Void
    var onEnableAll: (() -> Void)? = nil

    /// "Add All" on a board group header; shown only while the group still has models that can be enabled (`RelayCatalogBoardModel.enableAllModelIDs`).
    private var enableAllAction: (() -> Void)? {
        guard catalogBoard != nil, let onEnableAll,
              !RelayCatalogBoardModel.enableAllModelIDs(provider: provider, groupModels: group.models).isEmpty
        else { return nil }
        return onEnableAll
    }

    private var enableAllTitle: String {
        L10n.tr(RelayCatalogBoardModel.enableAllKey, table: .providers)
    }

    private var enableAllLabel: some View {
        RelayCatalogTextButtonLabel(title: enableAllTitle)
    }

    var body: some View {
        let enableAll = enableAllAction
        VStack(spacing: 0) {
            Button {
                if canToggle {
                    onToggle()
                }
            } label: {
                HStack(spacing: OriveoTheme.Spacing.md) {
                    ModelVendorIcon(groupKey: group.id, groupName: group.title, size: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title)
                            .font(OriveoTheme.Typography.title3.weight(.semibold))
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)

                        Text(L10n.format(L10n.tr("%lld models"), group.models.count))
                            .font(OriveoTheme.Typography.footnote)
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    }

                    Spacer()

                    if enableAll != nil {
                        // Placeholder only: the real button is overlaid on the group header (see below) instead of being nested in the expand button.
                        enableAllLabel.hidden()
                    }

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(OriveoTheme.Palette.surfaceInset.opacity(0.55)))
                }
                .padding(.horizontal, OriveoTheme.Spacing.md)
                .padding(.vertical, 14)
                .background(groupHeaderBackground)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // "Add All" is its own tap target on the group header: it works while collapsed and does not expand the group.
            // Aligned with the placeholder above (trailing chevron 28 + two md paddings).
            .overlay(alignment: .trailing) {
                if let enableAll {
                    Button(action: enableAll) {
                        enableAllLabel
                    }
                    .buttonStyle(OriveoTextButtonStyle())
                    // Several "Add All" buttons can be on screen at once, so VoiceOver needs the group name.
                    .accessibilityLabel(Text(verbatim: "\(enableAllTitle), \(group.title)"))
                    .padding(.trailing, OriveoTheme.Spacing.md * 2 + 28)
                }
            }

            if isExpanded {
                // Header/body divider: a full-width thin, faint hairline (the same 0.5pt / border 0.45 as the added-models panel),
                // replacing the heavier solid line of the default Divider for a more refined, consistent look
                Rectangle()
                    .fill(OriveoTheme.Palette.border.opacity(0.45))
                    .frame(height: 0.5)
            }
        }
    }

    /// A slight tint on the group header so the "parent panel" and the "child rows on white" have a visible hierarchy within the same card.
    /// The expanded state uses a stronger tint to stress "this group is being browsed now"; the collapsed state uses clear.
    @ViewBuilder
    private var groupHeaderBackground: some View {
        if isExpanded {
            OriveoTheme.Palette.surfaceInset.opacity(0.55)
        } else {
            Color.clear
        }
    }
}

struct ProviderCatalogGroupRow: View {
    let provider: Provider
    let capabilityEvidenceRevision: UInt64
    let model: AIModel
    let showsDivider: Bool
    let coordinateSpaceName: String?
    let rowFrames: CatalogRowFrameStore
    let catalogBoard: RelayCatalogBoardContext?
    var onAddModel: (AIModel, CGRect) -> Void
    var onOpenModel: ((AIModel) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            catalogModelRow

            if showsDivider {
                // Divider between rows: a thin, faint hairline aligned to the left edge of the child-row text (child rows are already flush at md)
                Rectangle()
                    .fill(OriveoTheme.Palette.border.opacity(0.45))
                    .frame(height: 0.5)
                    .padding(.leading, OriveoTheme.Spacing.md)
            }
        }
    }

    @ViewBuilder
    private var catalogModelRow: some View {
        let row = ProviderCatalogModelRow(
            model: model,
            provider: provider,
            capabilityEvidenceRevision: capabilityEvidenceRevision,
            nested: true,
            catalogBoard: catalogBoard,
            openAdvancedAction: { onOpenModel?(model) }
        ) {
            onAddModel(model, rowFrames.frame(for: model.id))
        }
        .equatable()

        if let coordinateSpaceName {
            // Write into the reference box rather than a preference/@State: it fires every scroll frame, and any view-state write
            // would rebuild the whole catalog.
            row.onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(coordinateSpaceName))
            } action: { frame in
                rowFrames.record(frame, for: model.id)
            }
        } else {
            row
        }
    }
}

private extension ProviderCatalogGroup {
    /// The identity of the group header in the host lazy stack (see `ProviderCatalogGroupList.body`).
    var headerRowIdentity: String { "group:" + id }
}

private extension AIModel {
    /// The identity of a catalog row in the host lazy stack (see `ProviderCatalogGroupList.body`).
    var catalogRowIdentity: String { "row:" + id }
}
