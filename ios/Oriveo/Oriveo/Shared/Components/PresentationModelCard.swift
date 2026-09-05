import SwiftUI

// MARK: - Presentation Contract: PresentationModelCard
//   displayName / vendorKey / vendorName / groupKey / groupName / pricing / pricingStatus /
//   capabilities / badgeOrder / rank / recommended / contextLength

struct PresentationModelDescriptor: Equatable, Hashable {
    let canonicalModelID: String
    let displayName: String
    let vendorKey: String?
    let vendorName: String?
    let groupKey: String?
    let groupName: String?
    let contextLength: Int?
    let promptPerToken: Double?
    let completionPerToken: Double?
    let pricingStatus: String
    let capabilities: [ModelCapability]
    let badgeOrder: [ModelCapability]?
    let recommended: Bool
    let rank: Int?
    let isEnabled: Bool
    let isDefault: Bool
}

extension PresentationModelDescriptor {
    init(from model: AIModel, isEnabled: Bool, isDefault: Bool) {
        self.canonicalModelID = model.canonicalModelId ?? model.id
        self.displayName = model.name
        self.vendorKey = nil
        self.vendorName = nil
        self.groupKey = model.groupKey
        self.groupName = model.groupName
        self.contextLength = model.contextLength
        self.promptPerToken = model.promptPrice
        self.completionPerToken = model.completionPrice
        if model.priceTier == L10n.tr("Free") {
            self.pricingStatus = "free"
        } else if model.pricingUnit != "per_token", !model.priceTier.isEmpty {
            self.pricingStatus = "priced"
        } else if model.promptPrice != nil || model.completionPrice != nil {
            self.pricingStatus = "priced"
        } else {
            self.pricingStatus = "unknown"
        }
        self.capabilities = model.capabilities
        self.badgeOrder = model.badgeOrder
        self.recommended = model.isRecommended ?? false
        self.rank = model.sortRank
        self.isEnabled = isEnabled
        self.isDefault = isDefault
    }

    var sortTieBreakerKey: String { canonicalModelID.lowercased() }
}


struct PresentationModelCard: View {
    let descriptor: PresentationModelDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headline
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(orderedBadges, id: \.rawValue) { capability in
                    PresentationCapabilityBadge(capability: capability)
                }
                if descriptor.recommended {
                    Text(L10n.tr("Recommended"))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
            }
            pricingLine
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var headline: some View {
        Text(descriptor.displayName)
            .font(.headline)
    }

    private var subtitle: String? {
        if let vendor = descriptor.vendorName, !vendor.isEmpty {
            return vendor
        }
        if let group = descriptor.groupName, !group.isEmpty {
            return group
        }
        return nil
    }

    private var orderedBadges: [ModelCapability] {
        guard let order = descriptor.badgeOrder, !order.isEmpty else {
            return descriptor.capabilities
        }
        return order.filter { descriptor.capabilities.contains($0) }
    }

    @ViewBuilder
    private var pricingLine: some View {
        switch descriptor.pricingStatus {
        case "priced":
            if let prompt = descriptor.promptPerToken {
                Text(CostFormatter.formatPerMillion(prompt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case "free":
            Text(L10n.tr("Free"))
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            Text(L10n.tr("Pricing Unknown"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct PresentationCapabilityBadge: View {
    let capability: ModelCapability

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: capability.systemImage)
            Text(capability.title)
                .font(.caption2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }
}


enum PresentationModelSorter {
    static func sorted(_ descriptors: [PresentationModelDescriptor]) -> [PresentationModelDescriptor] {
        descriptors.sorted { lhs, rhs in
            let lhsRank = lhs.rank ?? Int.min
            let rhsRank = rhs.rank ?? Int.min
            if lhsRank != rhsRank { return lhsRank > rhsRank }
            return lhs.sortTieBreakerKey < rhs.sortTieBreakerKey
        }
    }
}
