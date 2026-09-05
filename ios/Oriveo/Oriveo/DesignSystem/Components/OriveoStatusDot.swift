import SwiftUI

struct OriveoStatusDot: View {
    let color: Color
    let size: CGFloat
    let pulsing: Bool

    @State private var animating = false

    init(color: Color, size: CGFloat = 7, pulsing: Bool = false) {
        self.color = color
        self.size = size
        self.pulsing = pulsing
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.18), lineWidth: 2)
                    .blur(radius: 0.4)
            )
            .opacity(pulsing && animating ? 0.4 : 1)
            .scaleEffect(pulsing && animating ? 0.8 : 1)
            .animation(
                pulsing
                    ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                    : .default,
                value: animating
            )
            .onAppear {
                if pulsing { animating = true }
            }
    }
}
