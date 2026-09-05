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
}

nonisolated struct ProviderCatalogProjectionInput: Sendable {
    let providerID: UUID
    let providerKind: ProviderKind
    let providerDisplayName: String
    let enabledModels: [AIModel]
    let catalogModels: [AIModel]
    let priorityScores: [String: Int]
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

    if let value = perMillionPriceText(fromPerToken: model.promptPrice) {
        specifications.append(.init(id: "input", label: L10n.tr("Input", table: .chat), value: value, systemImage: nil))
    }
    if let value = perMillionPriceText(fromPerToken: model.completionPrice) {
        specifications.append(.init(id: "output", label: L10n.tr("Output", table: .chat), value: value, systemImage: nil))
    }
    if let value = perMillionPriceText(fromPerMillion: model.cacheReadInputPerMToken) {
        specifications.append(.init(id: "cache-read", label: L10n.tr("Cache read", table: .chat), value: value, systemImage: nil, isSecondary: true))
    }

    let cacheWrite = model.cacheWrite5mPerMToken ?? model.cacheCreationInputPerMToken
    if let value = perMillionPriceText(fromPerMillion: cacheWrite) {
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
    if let value = perMillionPriceText(fromPerMillion: model.cacheWrite1hPerMToken) {
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
        let separator = Text("  •  ")
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

private func perMillionPriceText(fromPerToken price: Double?) -> String? {
    guard let price, price.isFinite, price > 0 else { return nil }
    let formatted = CostFormatter.formatPerMillion(price)
    return formatted.isEmpty ? nil : formatted
}

private func perMillionPriceText(fromPerMillion price: Double?) -> String? {
    guard let price, price.isFinite, price > 0 else { return nil }
    let formatted = CostFormatter.formatPerMillion(price / 1_000_000)
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
    if model.capabilities.contains(.file) {
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
    let dedupedCatalog = CatalogModelBuilder.deduplicateByCanonical(catalogSource)
    return ProviderCatalogProjectionInput(
        providerID: provider.id,
        providerKind: provider.kind,
        providerDisplayName: provider.displayName,
        enabledModels: provider.models,
        catalogModels: dedupedCatalog,
        priorityScores: catalogPriorityScores(for: dedupedCatalog, provider: provider)
    )
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
    provider.models.first(where: \.isDefault) ?? provider.models.first
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

// MARK: - Shared Catalog Group Views

struct ProviderCatalogGroupList: View {
    let provider: Provider
    let capabilityEvidenceRevision: UInt64
    let groups: [ProviderCatalogGroup]
    let searchText: String
    let expandedGroupIDs: Set<String>
    let coordinateSpaceName: String?
    var onToggleGroup: (String) -> Void
    var onAddModel: (AIModel, CGRect) -> Void

    @State private var rowFrames = CatalogRowFrameStore()

    var body: some View {
        LazyVStack(spacing: OriveoTheme.Spacing.sm) {
            ForEach(groups) { group in
                ProviderCatalogGroupCard(
                    provider: provider,
                    capabilityEvidenceRevision: capabilityEvidenceRevision,
                    group: group,
                    isExpanded: shouldAutoExpandProviderCatalogGroups(searchText: searchText) ||
                        expandedGroupIDs.contains(group.id),
                    canToggle: !shouldAutoExpandProviderCatalogGroups(searchText: searchText),
                    coordinateSpaceName: coordinateSpaceName,
                    rowFrames: rowFrames,
                    onToggle: { onToggleGroup(group.id) },
                    onAddModel: onAddModel
                )
            }
        }
    }
}

private struct ProviderCatalogGroupCard: View {
    let provider: Provider
    let capabilityEvidenceRevision: UInt64
    let group: ProviderCatalogGroup
    let isExpanded: Bool
    let canToggle: Bool
    let coordinateSpaceName: String?
    let rowFrames: CatalogRowFrameStore
    var onToggle: () -> Void
    var onAddModel: (AIModel, CGRect) -> Void

    var body: some View {
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

                        Text(String(format: L10n.tr("%lld models"), group.models.count))
                            .font(OriveoTheme.Typography.footnote)
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
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

            if isExpanded {
                Rectangle()
                    .fill(OriveoTheme.Palette.border.opacity(0.45))
                    .frame(height: 0.5)

                LazyVStack(spacing: 0) {
                    ForEach(Array(group.models.enumerated()), id: \.element.id) { index, model in
                        catalogModelRow(for: model)

                        if index < group.models.count - 1 {
                            Rectangle()
                                .fill(OriveoTheme.Palette.border.opacity(0.45))
                                .frame(height: 0.5)
                                .padding(.leading, OriveoTheme.Spacing.md)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .oriveoRoundedSurface(
            fill: OriveoTheme.Palette.surfaceElevated,
            border: OriveoTheme.Palette.border.opacity(0.66),
            radius: OriveoTheme.Radius.lg,
            shadow: .soft
        )
    }

    @ViewBuilder
    private var groupHeaderBackground: some View {
        if isExpanded {
            OriveoTheme.Palette.surfaceInset.opacity(0.55)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func catalogModelRow(for model: AIModel) -> some View {
        let row = ProviderCatalogModelRow(
            model: model,
            provider: provider,
            capabilityEvidenceRevision: capabilityEvidenceRevision,
            nested: true
        ) {
            onAddModel(model, rowFrames.frame(for: model.id))
        }

        if let coordinateSpaceName {
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
