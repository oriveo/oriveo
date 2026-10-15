import SwiftUI
import UIKit

/// Dragging a conversation row out opens a new window (iPad multiple windows).
///
/// SwiftUI in the iOS SDK has no native "drag out to open a window" (`openWindow` can only be called from
/// code, and `draggable` carries no window meaning), so it uses `NSUserActivity`: the drag item registers an
/// activity, the system creates a scene from it when the drop lands outside the window, and the new window
/// turns the payload back into a `WindowOpenRequest` in `AppRootView.onContinueUserActivity`, then takes the
/// same `WindowOpenRequestPolicy.consume` as "Open in New Window" from the menu.
enum ConversationWindowDrag {
    /// Matches the value registered under `NSUserActivityTypes` in `Config/Info.plist`; without it the system does not create a scene from the activity.
    static let activityType = "ai.oriveo.community.open-conversation-window"

    /// The same condition as "Open in New Window" in the menu. Editing mode is ignored: it toggles often with
    /// multiple selection, and attaching or not attaching by it would replace the row's view identity, turning
    /// the row's slide animation into a cross-fade when entering or leaving editing; dragging a row out to a new
    /// window in editing mode does not conflict with multiple selection either.
    static func isAvailable(canOpenConversationWindow: Bool) -> Bool {
        canOpenConversationWindow
    }

    /// Every drag creates a new request with a fresh nonce, so dragging the same conversation twice opens two windows (see `WindowOpenRequest`).
    static func makeActivity(conversationID: UUID) -> NSUserActivity {
        let activity = NSUserActivity(activityType: activityType)
        try? activity.setTypedPayload(WindowOpenRequest(conversationID: conversationID))
        return activity
    }

    /// Turns an activity payload back into a window request; nil for another type or a broken payload.
    static func request(from activity: NSUserActivity) -> WindowOpenRequest? {
        guard activity.activityType == activityType else { return nil }
        return try? activity.typedPayload(WindowOpenRequest.self)
    }

    static func itemProvider(conversationID: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerObject(makeActivity(conversationID: conversationID), visibility: .all)
        return provider
    }
}

/// The drag source of a conversation row: not attached where unavailable (compact windows), so a long press only shows the menu.
struct ConversationWindowDragSource: ViewModifier {
    let conversationID: UUID
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.onDrag {
                ConversationWindowDrag.itemProvider(conversationID: conversationID)
            }
        } else {
            content
        }
    }
}
