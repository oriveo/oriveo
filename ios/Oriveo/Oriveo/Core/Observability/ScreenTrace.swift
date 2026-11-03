import SwiftUI

extension View {
    /// Page-load trace hook. The Community Edition ships no crash/performance reporting, so this is a no-op;
    /// business views keep calling the same modifier.
    func observabilityScreenTrace(_ viewName: String) -> some View {
        self
    }
}
