//
//  ConversationModelRetirement.swift
//  Oriveo
//
//  Retirement check for the session model of official BYOK connections.
//  Pure functions: they take only the catalog values, the models the user enabled, the session model and the current time, and read no global state.
//  Relay connections still use the removed check of relay/model-selection and do not come through here.
//

import Foundation

nonisolated enum ConversationModelRetirement {

    // MARK: - Inputs

    struct Lifecycle: Sendable, Equatable {
        var state: String?
        var shutdownAt: Date?
        var routedTo: String?
    }

    struct CatalogModel: Sendable, Equatable {
        var id: String
        var displayName: String?
        var lifecycle: Lifecycle?
    }

    struct Catalog: Sendable, Equatable {
        var models: [CatalogModel]
        var retiredModels: [MetadataClient.RetiredModelTombstone]
        var resolveMap: [String: String]
        var defaultModelId: String?
    }

    // MARK: - Results

    enum Status: String, Sendable, Equatable {
        case available
        case retired
        case missing
    }

    struct ConversationResult: Sendable, Equatable {
        var status: Status
        var successorId: String?
        var displayName: String
        /// The session model id is kept as-is: it is neither rewritten nor synced out before the user acts.
        var modelId: String

        /// retired and missing both show a banner and block sending; available never does.
        var sendBlocked: Bool { status != .available }
    }

    enum NewChatHint: String, Sendable, Equatable {
        case lastUsedRetired = "last_used_retired"
    }

    struct NewChatResult: Sendable, Equatable {
        var modelId: String?
        var hint: NewChatHint?
    }

    // MARK: - Judgment

    /// Session model status; the first matching rule stops the check.
    static func conversationStatus(
        catalog: Catalog?,
        userModels: [String],
        modelId: String,
        storedName: String?,
        now: Date
    ) -> ConversationResult {
        let status: Status
        var successorId: String?
        if let catalog {
            let model = catalog.models.first { $0.id == modelId }
            if let tombstone = catalog.retiredModels.first(where: { $0.id == modelId }) {
                status = .retired
                successorId = availableSuccessor(tombstone.routedTo, in: catalog, now: now)
            } else if let model, isPastShutdown(model, now: now) {
                status = .retired
                successorId = availableSuccessor(model.lifecycle?.routedTo, in: catalog, now: now)
            } else if model != nil || userModels.contains(modelId) {
                status = .available
            } else if let canonical = catalog.resolveMap[modelId], catalog.models.contains(where: { $0.id == canonical }) {
                status = .available
            } else {
                status = .missing
            }
        } else {
            status = .available
        }
        return ConversationResult(
            status: status,
            successorId: successorId,
            displayName: displayName(catalog: catalog, modelId: modelId, storedName: storedName),
            modelId: modelId
        )
    }

    /// Default model of a new chat: the last used / the user default, then the catalog default, then the first available in the enabled list.
    /// The catalog default is matched among the available enabled models through `ModelResolver.matchingModel` (date snapshot / canonical / case) and returns the enabled id.
    /// When the last used model is not adopted, a last_used_retired hint is given once.
    /// `userModelCanonicalIds`: enabled id to canonical, so the catalog default can match by canonical.
    static func newChatModel(
        catalog: Catalog?,
        userModels: [String],
        userModelCanonicalIds: [String: String] = [:],
        preferredModelId: String?,
        now: Date
    ) -> NewChatResult {
        func usable(_ id: String) -> Bool {
            userModels.contains(id)
                && conversationStatus(catalog: catalog, userModels: userModels, modelId: id, storedName: nil, now: now)
                    .status == .available
        }
        /// Matches only among the already filtered available enabled models; this function serves only official BYOK, so it matches by the non-relay rule.
        func matchEnabled(_ defaultId: String, in ids: [String]) -> String? {
            let models = ids.map { id in
                var model = AIModel(
                    id: id, name: id, capabilities: [], reasoningModeAvailable: false, isAvailable: true,
                    isDefault: false, priceTier: "", summary: nil, groupKey: nil, groupName: nil
                )
                model.canonicalModelId = userModelCanonicalIds[id]
                return model
            }
            return ModelResolver.matchingModel(modelID: defaultId, in: models, providerKind: .openAI)?.id
        }
        let chosen: String?
        if let preferredModelId, usable(preferredModelId) {
            chosen = preferredModelId
        } else if let defaultId = catalog?.defaultModelId, let matched = matchEnabled(defaultId, in: userModels.filter(usable)) {
            chosen = matched
        } else {
            chosen = userModels.first(where: usable)
        }
        let hint: NewChatHint? = (preferredModelId != nil && chosen != preferredModelId) ? .lastUsedRetired : nil
        return NewChatResult(modelId: chosen, hint: hint)
    }

    // MARK: - Internal

    private static func isPastShutdown(_ model: CatalogModel, now: Date) -> Bool {
        guard let lifecycle = model.lifecycle, lifecycle.state == "deprecated", let shutdownAt = lifecycle.shutdownAt else {
            return false
        }
        return shutdownAt <= now
    }

    /// A successor counts only if it is a model in the catalog that is still available right now; otherwise there is no successor.
    private static func availableSuccessor(_ id: String?, in catalog: Catalog, now: Date) -> String? {
        guard let id, !id.isEmpty,
              !catalog.retiredModels.contains(where: { $0.id == id }),
              let model = catalog.models.first(where: { $0.id == id }),
              !isPastShutdown(model, now: now) else { return nil }
        return id
    }

    private static func displayName(catalog: Catalog?, modelId: String, storedName: String?) -> String {
        let candidates: [String?] = [
            storedName,
            catalog?.models.first { $0.id == modelId }?.displayName,
            catalog?.retiredModels.first { $0.id == modelId }?.displayName,
        ]
        return candidates.lazy.compactMap { $0 }.first { !$0.isEmpty } ?? modelId
    }

    /// ISO 8601 (with or without milliseconds).
    static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
