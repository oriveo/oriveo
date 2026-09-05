import Foundation

enum ProviderDisclosureStore {
    private static let acceptedListKey = "provider.disclosure.accepted.list"

    static func hasAccepted(_ kind: ProviderKind) -> Bool {
        acceptedKinds().contains(kind.rawValue)
    }

    static func markAccepted(_ kind: ProviderKind) {
        var accepted = acceptedKinds()
        guard !accepted.contains(kind.rawValue) else { return }
        accepted.insert(kind.rawValue)
        UserDefaults.standard.set(Array(accepted), forKey: acceptedListKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: acceptedListKey)
    }

    private static func acceptedKinds() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: acceptedListKey) ?? [])
    }
}
