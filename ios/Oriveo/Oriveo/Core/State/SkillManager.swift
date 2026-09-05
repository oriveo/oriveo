import Foundation
import Observation

private let defaultHomeSkillKeys = [
    "translation_expert",
    "writing_coach",
    "email_assistant",
    "brainstorm",
    "document_summarizer",
]

func selectHomeSkills(
    catalogSkills: [Skill],
    userSkills: [Skill],
    limit: Int = 7
) -> [Skill] {
    guard limit > 0 else { return [] }

    let all = catalogSkills + userSkills
    let pinned = all
        .filter(\.isPinned)
        .sorted { $0.pinOrder < $1.pinOrder }
    let recent = all
        .filter { !$0.isPinned && $0.lastUsedAt != nil }
        .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
    let recommended = defaultHomeSkillKeys.compactMap { key in
        catalogSkills.first { $0.key == key }
    }
    let remainingBuiltin = catalogSkills

    var selected: [Skill] = []
    var selectedIDs = Set<UUID>()

    func appendUnique(_ candidates: [Skill]) {
        for skill in candidates where selected.count < limit {
            if selectedIDs.insert(skill.id).inserted {
                selected.append(skill)
            }
        }
    }

    appendUnique(pinned)
    appendUnique(recent)
    appendUnique(recommended)
    appendUnique(remainingBuiltin)
    return selected
}

private struct SkillDraftPayload: Codable {
    var name: String
    var description: String?
    var icon: String?
    var color: String?
    var systemPrompt: String?
    var suggestedProviderId: String?
    var suggestedModelId: String?
    var modelCapabilityHint: String?
    var starterMessages: [String]?
    var knowledgeFiles: [SkillKnowledgeFile]?
    var useMemory: Bool?
    var temperature: Double?
    var reasoningLevel: String?
    var webSearchEnabled: Bool?
    var isPinned: Bool?
    var pinOrder: Int?
}

@MainActor
@Observable
final class SkillManager {
    @ObservationIgnored unowned private(set) var appState: AppState!

    private(set) var catalogSkills: [Skill] = []
    private(set) var catalogCategories: [SkillCategory] = []
    private(set) var userSkills: [Skill] = []
    private(set) var usage: SkillUsage?

    private(set) var isRefreshing = false
    @ObservationIgnored private var hasLoadedInitialData = false

    func bind(to appState: AppState) {
        self.appState = appState
        loadCache()
    }

    var homeSkills: [Skill] {
        selectHomeSkills(catalogSkills: catalogSkills, userSkills: userSkills)
    }

    var catalogByCategory: [(category: SkillCategory, skills: [Skill])] {
        let grouped = Dictionary(grouping: catalogSkills) { $0.category ?? "other" }
        return catalogCategories
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { cat in
                guard let skills = grouped[cat.id], !skills.isEmpty else { return nil }
                return (category: cat, skills: skills.sorted { $0.sortOrder < $1.sortOrder })
            }
    }

    func skill(by id: UUID) -> Skill? {
        catalogSkills.first(where: { $0.id == id }) ?? userSkills.first(where: { $0.id == id })
    }

    var totalSkillCount: Int {
        catalogSkills.count + userSkills.count
    }

    func refreshAll() async {
        isRefreshing = true
        loadCache()
        isRefreshing = false
        hasLoadedInitialData = true
    }

    func refreshCatalog() async {
        loadCache()
    }

    func refreshUserSkills() async {
        loadCache()
    }

    func createSkill(_ body: [String: Any]) async throws -> Skill {
        let skill = try skillFromBody(body, existing: nil, forkedFromId: nil)
        userSkills.append(skill)
        saveUserCache()
        return skill
    }

    func updateSkill(_ id: UUID, _ body: [String: Any]) async throws -> Skill {
        guard let existing = skill(by: id), existing.isEditable else {
            throw SkillError.notAuthenticated
        }
        let updated = try skillFromBody(body, existing: existing, forkedFromId: existing.forkedFromId)
        if let idx = userSkills.firstIndex(where: { $0.id == id }) {
            userSkills[idx] = updated
        } else {
            userSkills.append(updated)
        }
        saveUserCache()
        return updated
    }

    func deleteSkill(_ id: UUID, body: [String: Any]? = nil) async throws {
        _ = body
        userSkills.removeAll { $0.id == id }
        saveUserCache()
    }

    func forkSkill(_ id: UUID) async throws -> Skill {
        guard let origin = skill(by: id) else {
            throw SkillError.notAuthenticated
        }
        let now = Date()
        let forked = Skill(
            id: UUID(),
            key: nil,
            name: origin.name,
            description: origin.description,
            icon: origin.icon,
            color: origin.color,
            systemPrompt: origin.systemPrompt,
            suggestedProviderId: origin.suggestedProviderId,
            suggestedModelId: origin.suggestedModelId,
            modelCapabilityHint: origin.modelCapabilityHint,
            temperature: origin.temperature,
            reasoningLevel: origin.reasoningLevel,
            webSearchEnabled: origin.webSearchEnabled,
            starterMessages: origin.starterMessages,
            knowledgeFiles: origin.knowledgeFiles,
            knowledgeBase: nil,
            useMemory: origin.useMemory,
            isPinned: false,
            pinOrder: 0,
            source: .user,
            forkedFromId: origin.id,
            category: origin.category,
            sortOrder: 0,
            usageCount: 0,
            lastUsedAt: nil,
            createdAt: now,
            updatedAt: now
        )
        userSkills.append(forked)
        saveUserCache()
        return forked
    }

    func recordUse(_ id: UUID) async {
        var isUserSkill = false
        var hasKnowledge = false
        if let idx = catalogSkills.firstIndex(where: { $0.id == id }) {
            catalogSkills[idx].usageCount += 1
            catalogSkills[idx].lastUsedAt = Date()
            hasKnowledge = catalogSkills[idx].knowledgeBase != nil
        } else if let idx = userSkills.firstIndex(where: { $0.id == id }) {
            userSkills[idx].usageCount += 1
            userSkills[idx].lastUsedAt = Date()
            isUserSkill = true
            hasKnowledge = userSkills[idx].knowledgeBase != nil
        }
        saveCatalogCache()
        saveUserCache()

    }

    @discardableResult
    func togglePin(_ id: UUID) -> Bool {
        if let idx = catalogSkills.firstIndex(where: { $0.id == id }) {
            catalogSkills[idx].isPinned.toggle()
            if catalogSkills[idx].isPinned {
                catalogSkills[idx].pinOrder = nextPinOrder()
            }
            saveCatalogCache()
        } else if let idx = userSkills.firstIndex(where: { $0.id == id }) {
            let newPinned = !userSkills[idx].isPinned
            userSkills[idx].isPinned = newPinned
            if newPinned { userSkills[idx].pinOrder = nextPinOrder() }
            saveUserCache()
        } else {
            return false
        }
        return true
    }

    private func nextPinOrder() -> Int {
        let all = catalogSkills + userSkills
        let maxOrder = all.filter(\.isPinned).map(\.pinOrder).max() ?? 0
        return maxOrder + 1
    }

    private func skillFromBody(
        _ body: [String: Any],
        existing: Skill?,
        forkedFromId: UUID?
    ) throws -> Skill {
        let data = try JSONSerialization.data(withJSONObject: body)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let draft = try decoder.decode(SkillDraftPayload.self, from: data)
        let now = Date()
        return Skill(
            id: existing?.id ?? UUID(),
            key: existing?.key,
            name: draft.name,
            description: draft.description ?? existing?.description ?? "",
            icon: draft.icon ?? existing?.icon ?? "🤖",
            color: draft.color ?? existing?.color ?? "#6d38ff",
            systemPrompt: draft.systemPrompt ?? existing?.systemPrompt ?? "",
            suggestedProviderId: draft.suggestedProviderId ?? existing?.suggestedProviderId,
            suggestedModelId: draft.suggestedModelId ?? existing?.suggestedModelId,
            modelCapabilityHint: draft.modelCapabilityHint ?? existing?.modelCapabilityHint ?? "any",
            temperature: draft.temperature ?? existing?.temperature,
            reasoningLevel: draft.reasoningLevel ?? existing?.reasoningLevel,
            webSearchEnabled: draft.webSearchEnabled ?? existing?.webSearchEnabled,
            starterMessages: draft.starterMessages ?? existing?.starterMessages ?? [],
            knowledgeFiles: draft.knowledgeFiles ?? existing?.knowledgeFiles ?? [],
            knowledgeBase: nil,
            useMemory: draft.useMemory ?? existing?.useMemory ?? true,
            isPinned: draft.isPinned ?? existing?.isPinned ?? false,
            pinOrder: draft.pinOrder ?? existing?.pinOrder ?? 0,
            source: .user,
            forkedFromId: forkedFromId,
            category: existing?.category,
            sortOrder: existing?.sortOrder ?? 0,
            usageCount: existing?.usageCount ?? 0,
            lastUsedAt: existing?.lastUsedAt,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
    }

    private var cacheKeyPrefix: String {
        let uid = AppSessionStore.activeUID
        return "skills_\(uid)_"
    }

    private func loadCache() {
        clearRuntimeState()

        let defaults = UserDefaults.standard
        let prefix = cacheKeyPrefix

        if let data = defaults.data(forKey: "\(prefix)catalog") {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            catalogSkills = (try? decoder.decode([Skill].self, from: data)) ?? []
        }
        if let data = defaults.data(forKey: "\(prefix)categories") {
            catalogCategories = (try? JSONDecoder().decode([SkillCategory].self, from: data)) ?? []
        }
        if let data = defaults.data(forKey: "\(prefix)user") {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            userSkills = (try? decoder.decode([Skill].self, from: data)) ?? []
        }
    }

    func reloadCacheForCurrentAccount() {
        loadCache()
    }

    private func saveCatalogCache() {
        let defaults = UserDefaults.standard
        let prefix = cacheKeyPrefix
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        if let data = try? encoder.encode(catalogSkills) {
            defaults.set(data, forKey: "\(prefix)catalog")
        }
        if let data = try? JSONEncoder().encode(catalogCategories) {
            defaults.set(data, forKey: "\(prefix)categories")
        }
    }

    private func saveUserCache() {
        let defaults = UserDefaults.standard
        let prefix = cacheKeyPrefix
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        if let data = try? encoder.encode(userSkills) {
            defaults.set(data, forKey: "\(prefix)user")
        }
    }

    func replaceUserSkills(_ skills: [Skill]) {
        userSkills = skills
        saveUserCache()
    }

    func clearCache() {
        clearCache(for: AppSessionStore.activeUID)
    }

    func clearCache(for uid: String) {
        let defaults = UserDefaults.standard
        let prefix = "skills_\(uid)_"
        defaults.removeObject(forKey: "\(prefix)catalog")
        defaults.removeObject(forKey: "\(prefix)categories")
        defaults.removeObject(forKey: "\(prefix)user")
        defaults.removeObject(forKey: "\(prefix)catalog_version")

        if AppSessionStore.activeUID == uid {
            clearRuntimeState()
        }
    }

    func clearRuntimeState() {
        catalogSkills = []
        catalogCategories = []
        userSkills = []
        usage = nil
        hasLoadedInitialData = false
    }
}
