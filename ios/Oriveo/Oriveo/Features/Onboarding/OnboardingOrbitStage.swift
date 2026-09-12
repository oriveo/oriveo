import SwiftUI



struct OnboardingPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.9 : 1).scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

enum OnboardingPalette {
    static let bg0 = Color(red: 11/255, green: 10/255, blue: 20/255)
    static let ink = Color(hex: 0xF3F1FF)
    static let muted = Color(hex: 0xA9A3C2)
    static let faint = Color(hex: 0x6E6890)
    static let purple = Color(red: 124/255, green: 58/255, blue: 237/255)
    static let purpleBright = Color(red: 157/255, green: 123/255, blue: 1)
    static let line = Color(hex: 0x9D7BFF).opacity(0.14)
    static let hairline = Color.white.opacity(0.08)

    static let highlightGradient = LinearGradient(
        colors: [Color(hex: 0xEDE6FF), Color(hex: 0x9D7BFF), Color(hex: 0xEDE6FF)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let keyGradient = LinearGradient(
        colors: [Color(hex: 0xFCD34D), Color(hex: 0xF59E0B)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let shieldFill = LinearGradient(
        colors: [Color(hex: 0x221D40), Color(hex: 0x0F0C1F)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static func ctaGradient(opacity: Double) -> LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 131 / 255, green: 71 / 255, blue: 245 / 255).opacity(opacity),
                Color(red: 107 / 255, green: 59 / 255, blue: 199 / 255).opacity(opacity)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}


struct OnboardingOrbitStage: View {
    let values: OnboardingStageValues
    let scale: CGFloat
    let ringsRevealed: Bool
    let nucleusRevealed: Bool
    let isAnimating: Bool

    static let nucleusSize: CGFloat = 68
    static let nucleusCornerRadius: CGFloat = 16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate = Date()
    @State private var costCardLift = false
    @State private var costCardDrift = false

    private var isClockPaused: Bool {
        OnboardingMotionPolicy.isOrbitClockPaused(reduceMotion: reduceMotion, isStageActive: isAnimating)
    }

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isClockPaused)) { context in
                let time = isClockPaused ? 0 : context.date.timeIntervalSince(startDate)

                ZStack {
                    rings(time: time)
                        .opacity(values.ringsOpacity * (ringsRevealed ? 1 : 0))
                        .zIndex(-2)

                    ForEach(OnboardingOrbitCatalog.orbiters) { orbiter in
                        let point = OnboardingOrbitCatalog.position(for: orbiter, time: time)
                        orbiterView(orbiter, point: point)
                            .zIndex(point.depth)
                    }

                    nucleus
                        .zIndex(0)
                }
            }

            byokPiece
            startBadgePiece
        }
        .scaleEffect(scale)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 6.0).repeatForever(autoreverses: true)) {
                costCardLift = true
            }
            withAnimation(.easeInOut(duration: 7.4).repeatForever(autoreverses: true)) {
                costCardDrift = true
            }
        }
    }


    private func rings(time: Double) -> some View {
        ZStack {
            ringShape(OnboardingOrbitCatalog.rings[0], tiltDegrees: OnboardingOrbitCatalog.rings[0].tiltDegrees)
            ringShape(OnboardingOrbitCatalog.rings[1], tiltDegrees: OnboardingOrbitCatalog.rings[1].tiltDegrees)
            ringShape(
                OnboardingOrbitCatalog.rings[2],
                tiltDegrees: OnboardingOrbitCatalog.decorativeSpinDegrees(time: time)
            )
        }
    }

    private func ringShape(_ ring: OnboardingOrbitRing, tiltDegrees: Double) -> some View {
        Ellipse()
            .stroke(OnboardingPalette.purpleBright.opacity(ring.strokeOpacity), lineWidth: 1)
            .frame(width: ring.radiusX * 2, height: ring.radiusY * 2)
            .rotationEffect(.degrees(tiltDegrees))
    }


    private func orbiterView(_ orbiter: OnboardingOrbiter, point: OnboardingOrbitPoint) -> some View {
        let depthScale = 1 + 0.08 * point.depth
        let depthOpacity = 0.82 + 0.18 * (point.depth + 1) / 2

        return Image(orbiter.assetName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: orbiter.size, height: orbiter.size)
            .shadow(color: .black.opacity(0.6), radius: 6, y: 5)
            .shadow(color: OnboardingPalette.purple.opacity(0.22), radius: 10)
            .scaleEffect(depthScale)
            .opacity(values.orbitersOpacity * depthOpacity)
            .offset(x: point.x + values.orbitersOffsetX, y: point.y)
    }


    private var nucleus: some View {
        Image("OriveoLogo")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: Self.nucleusSize, height: Self.nucleusSize)
            .clipShape(RoundedRectangle(cornerRadius: Self.nucleusCornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.7), radius: 30, y: 24)
            .shadow(color: OnboardingPalette.purple.opacity(0.55), radius: 35)
            .scaleEffect(values.nucleusScale * (nucleusRevealed ? 1 : 0.82))
            .opacity(values.nucleusOpacity * (nucleusRevealed ? 1 : 0))
            .offset(x: values.nucleusOffsetX)
    }


    private var byokPiece: some View {
        ZStack {
            OnboardingShieldShape()
                .fill(OnboardingPalette.shieldFill)
                .overlay(
                    OnboardingShieldShape()
                        .stroke(OnboardingPalette.purpleBright.opacity(0.4), lineWidth: 1.6)
                )
                .overlay(
                    OnboardingShieldEdgeShape()
                        .stroke(Color(hex: 0xFCD34D).opacity(0.35), lineWidth: 1.6)
                )
                .overlay(
                    OnboardingKeyShape()
                        .stroke(OnboardingPalette.keyGradient, style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
                )
                .frame(width: 128, height: 142)
                .offset(x: -30)

            OnboardingCostCard(lift: costCardLift ? 1 : 0)
                .scaleEffect(costCardLift ? 1.03 : 0.99)
                .rotation3DEffect(
                    .degrees(costCardLift ? -2.6 : 1.6),
                    axis: (x: 1, y: 0, z: 0),
                    perspective: 0.55
                )
                .offset(
                    x: 46 + (costCardDrift ? 7 : -5),
                    y: 115 + (costCardLift ? -17 : 5)
                )
        }
        .scaleEffect(values.byokScale)
        .opacity(values.byokOpacity)
        .offset(x: values.byokOffsetX)
    }


    private var startBadgePiece: some View {
        VStack(spacing: 14) {
            HStack(spacing: 9) {
                OnboardingSparkShape()
                    .fill(LinearGradient(
                        colors: [Color(hex: 0xE9D5FF), Color(hex: 0x9D7BFF)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 20, height: 20)

                Text(L10n.tr("Bring your own key", table: .onboarding))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(OnboardingPalette.ink)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(
                Capsule().fill(LinearGradient(
                    colors: [
                        OnboardingPalette.purple.opacity(0.32),
                        OnboardingPalette.purpleBright.opacity(0.14)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            )
            .overlay(Capsule().strokeBorder(OnboardingPalette.purpleBright.opacity(0.45), lineWidth: 1))
            .shadow(color: OnboardingPalette.purple.opacity(0.55), radius: 30)

            Text(L10n.tr("No account. Your keys stay on this device.", table: .onboarding))
                .font(.system(size: 12.5))
                .foregroundStyle(OnboardingPalette.muted)
                .multilineTextAlignment(.center)
        }
        .frame(width: 268)
        .scaleEffect(values.startBadgeScale)
        .opacity(values.startBadgeOpacity)
        .offset(x: values.startBadgeOffsetX)
    }
}



struct OnboardingCostCard: View {
    var lift: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            row(title: "GPT-5.2", value: "$0.0042", isSummary: false)
            row(title: "Claude", value: "$0.0117", isSummary: false)

            Rectangle()
                .fill(OnboardingPalette.hairline)
                .frame(height: 1)
                .padding(.top, 3)

            row(
                title: L10n.tr("This week", table: .onboarding),
                value: "$1.83",
                isSummary: true
            )
            .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 172)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hex: 0x141124).opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(OnboardingPalette.line, lineWidth: 1)
        )
        .shadow(
            color: .black.opacity(0.66 - 0.22 * lift),
            radius: 20 + 20 * lift,
            y: 15 + 13 * lift
        )
        .shadow(
            color: OnboardingPalette.purple.opacity(0.10 + 0.16 * lift),
            radius: 12 + 18 * lift,
            y: 6 + 8 * lift
        )
    }

    private func row(title: String, value: String, isSummary: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(isSummary ? Color(hex: 0xFCD34D) : OnboardingPalette.muted)
                .lineLimit(1)

            Spacer(minLength: 0)

            Group {
                if isSummary {
                    Text(value)
                        .foregroundStyle(OnboardingPalette.keyGradient)
                } else {
                    Text(value)
                        .foregroundStyle(OnboardingPalette.ink)
                }
            }
            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
        }
        .padding(.vertical, 3.5)
    }
}


struct OnboardingShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let s = OnboardingVectorScaler(rect: rect, designSize: CGSize(width: 128, height: 142))

        path.move(to: s.point(64, 6))
        path.addLine(to: s.point(116, 26))
        path.addLine(to: s.point(116, 64))
        path.addCurve(to: s.point(64, 136), control1: s.point(116, 98), control2: s.point(94, 124))
        path.addCurve(to: s.point(12, 64), control1: s.point(34, 124), control2: s.point(12, 98))
        path.addLine(to: s.point(12, 26))
        path.closeSubpath()
        return path
    }
}

struct OnboardingShieldEdgeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let s = OnboardingVectorScaler(rect: rect, designSize: CGSize(width: 128, height: 142))

        path.move(to: s.point(64, 6))
        path.addLine(to: s.point(116, 26))
        path.addLine(to: s.point(116, 64))
        path.addCurve(to: s.point(64, 136), control1: s.point(116, 98), control2: s.point(94, 124))
        return path
    }
}

struct OnboardingKeyShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let s = OnboardingVectorScaler(rect: rect, designSize: CGSize(width: 128, height: 142))

        path.addEllipse(in: CGRect(
            origin: s.point(57 - 13, 62 - 13),
            size: CGSize(width: 26 * s.factor, height: 26 * s.factor)
        ))
        path.move(to: s.point(67, 71))
        path.addLine(to: s.point(84, 88))
        path.move(to: s.point(84, 88))
        path.addLine(to: s.point(84, 80))
        path.move(to: s.point(84, 88))
        path.addLine(to: s.point(76, 88))
        return path
    }
}

struct OnboardingSparkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let s = OnboardingVectorScaler(rect: rect, designSize: CGSize(width: 20, height: 20))

        path.move(to: s.point(10, 1.5))
        path.addLine(to: s.point(12, 8))
        path.addLine(to: s.point(18.5, 10))
        path.addLine(to: s.point(12, 12))
        path.addLine(to: s.point(10, 18.5))
        path.addLine(to: s.point(8, 12))
        path.addLine(to: s.point(1.5, 10))
        path.addLine(to: s.point(8, 8))
        path.closeSubpath()
        return path
    }
}

struct OnboardingVectorScaler {
    let factor: CGFloat
    private let originX: CGFloat
    private let originY: CGFloat

    init(rect: CGRect, designSize: CGSize) {
        let scale = min(rect.width / designSize.width, rect.height / designSize.height)
        factor = scale
        originX = rect.minX + (rect.width - designSize.width * scale) / 2
        originY = rect.minY + (rect.height - designSize.height * scale) / 2
    }

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: originX + x * factor, y: originY + y * factor)
    }
}
