import Observation
import SwiftUI

@MainActor
@Observable
final class NavigationManager {

    var path: [AppRoute] = []

    func openProviderSetup(from entryPoint: ProviderSetupEntryPoint, preselectedKind: ProviderKind? = nil) {
        attemptNavigate(to: .providerSetup(entryPoint: entryPoint, preselectedKind: preselectedKind))
    }

    func openProviderDetail(providerID: UUID) {
        attemptNavigate(to: .providerDetail(providerID: providerID))
    }

    func openManualModelEntry(providerID: UUID, context: ManualModelEntryContext) {
        attemptNavigate(to: .manualModelEntry(providerID: providerID, context: context))
    }

    func openChat(conversationID: UUID) {
        attemptNavigate(to: .chat(conversationID: conversationID))
    }

    func openBackup() {
        attemptNavigate(to: .backup)
    }

    func openRelaySetup(from entryPoint: ProviderSetupEntryPoint) {
        attemptNavigate(to: .relaySetup(entryPoint: entryPoint))
    }

    func openMemory() {
        attemptNavigate(to: .memory)
    }

    func openSkillsList() {
        attemptNavigate(to: .skillsList)
    }

    func openSkillEdit(skillID: UUID? = nil) {
        attemptNavigate(to: .skillEdit(skillID))
    }

    func openNotesList() {
        attemptNavigate(to: .notesList)
    }

    func openNoteDetail(noteID: UUID) {
        attemptNavigate(to: .noteDetail(noteID: noteID))
    }

    func attemptNavigate(to route: AppRoute) {
        path.append(route)
    }

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    func popToRoot() {
        path = []
    }

    func replaceLast(with route: AppRoute) {
        guard !path.isEmpty else {
            path.append(route)
            return
        }
        path[path.count - 1] = route
    }
}
