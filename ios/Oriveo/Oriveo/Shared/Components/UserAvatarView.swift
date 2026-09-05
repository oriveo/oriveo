import SwiftUI

/// Circular avatar shown next to the user's own messages.
struct UserAvatarView: View {
    let size: CGFloat

    var body: some View {
        Image("UserAvatar")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}
