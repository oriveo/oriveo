import SwiftUI

/// Reads the presenter's `AppState` so the modal modifiers below can write it into their content.
private struct PresenterAppStateRelay<Presenter: View>: View {
    @Environment(AppState.self) private var appState: AppState?
    @ViewBuilder let presenter: (AppState?) -> Presenter

    var body: some View {
        presenter(appState)
    }
}

/// Modal modifiers that carry `AppState` through the view tree instead of relying on inheritance.
///
/// On a Mac (iOS App on Mac, Mac Catalyst) `PresentationHostingController.init` reads the modal's host preferences
/// before the presenter's environment reaches the modal's graph, so a root view whose body feeds those preferences
/// runs once with an empty environment. That covers `presentation*` modifiers, nested `sheet` / `alert` modifiers and
/// a root `if`. In that pass a non-optional `@Environment(AppState.self)` is a fatal error. iPhone and iPad never take
/// that pass, so simulators cannot show the crash. A value written by `.environment(...)` inside the presented content
/// is part of the root view and exists from the first pass.
extension View {
    /// What each modifier presents; `nil` when the presenter sits outside the app root (tests, previews).
    func carryingAppState(_ appState: AppState?) -> some View {
        environment(appState)
    }

    func oriveoSheet<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        PresenterAppStateRelay { appState in
            self.sheet(isPresented: isPresented, onDismiss: onDismiss) {
                content().carryingAppState(appState)
            }
        }
    }

    func oriveoSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        PresenterAppStateRelay { appState in
            self.sheet(item: item, onDismiss: onDismiss) { value in
                content(value).carryingAppState(appState)
            }
        }
    }

    func oriveoFullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        PresenterAppStateRelay { appState in
            self.fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) {
                content().carryingAppState(appState)
            }
        }
    }

    func oriveoFullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        PresenterAppStateRelay { appState in
            self.fullScreenCover(item: item, onDismiss: onDismiss) { value in
                content(value).carryingAppState(appState)
            }
        }
    }

    func oriveoPopover<Content: View>(
        isPresented: Binding<Bool>,
        attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds),
        arrowEdge: Edge? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        PresenterAppStateRelay { appState in
            self.popover(isPresented: isPresented, attachmentAnchor: attachmentAnchor, arrowEdge: arrowEdge) {
                content().carryingAppState(appState)
            }
        }
    }

    func oriveoPopover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds),
        arrowEdge: Edge? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        PresenterAppStateRelay { appState in
            self.popover(item: item, attachmentAnchor: attachmentAnchor, arrowEdge: arrowEdge) { value in
                content(value).carryingAppState(appState)
            }
        }
    }
}
