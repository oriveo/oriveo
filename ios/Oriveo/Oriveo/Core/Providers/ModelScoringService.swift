import Foundation

enum ModelScoringService {

    static func selectDefault(
        from models: [AIModel],
        scoreFn: (AIModel) -> Int
    ) -> [AIModel] {
        guard let preferredIndex = models.indices.max(by: { scoreFn(models[$0]) < scoreFn(models[$1]) }) else {
            return models
        }
        return models.enumerated().map { index, model in
            var m = model
            m.isDefault = index == preferredIndex
            return m
        }
    }

    static func selectRecommended(
        from models: [AIModel],
        scoreFn: (AIModel) -> Int,
        preferredGroups: [String],
        maxCount: Int = 6
    ) -> [AIModel] {
        let availableModels = models.filter(\.isAvailable)
        let candidatePool = availableModels.isEmpty ? models : availableModels
        let ranked = candidatePool.sorted { scoreFn($0) > scoreFn($1) }

        var selected: [AIModel] = []

        for groupKey in preferredGroups {
            if let m = ranked.first(where: { $0.groupKey == groupKey }),
               !selected.contains(where: { $0.id == m.id }) {
                selected.append(m)
            }
        }

        if selected.count < maxCount {
            for m in ranked where !selected.contains(where: { $0.id == m.id }) {
                selected.append(m)
                if selected.count >= maxCount { break }
            }
        }

        return selected
    }
}
