import SwiftUI

enum AuroraTheme {


    enum Colors {
        static let accent = Color.dynamic(light: 0x8B5CF6, dark: 0xA78BFA)

        static let accentGlow = Color.dynamic(light: 0x8B5CF6, dark: 0xC4B5FD)

        static let auroraBlue = Color.dynamic(light: 0x60A5FA, dark: 0x93C5FD)

        static let auroraGreen = Color.dynamic(light: 0x10B981, dark: 0x34D399)

        static let textPrimary = Color.dynamic(light: 0x0A0612, dark: 0xFAFAFB)

        static let textSecondary = Color.dynamic(light: 0x6B6378, dark: 0xC4BFD3)

        static let textTertiary = Color.dynamic(light: 0x9C95AA, dark: 0x8C8499)

        static let cardFill = Color.dynamic(light: 0xFFFFFF, dark: 0x1A1530, lightAlpha: 0.72, darkAlpha: 0.55)

        static let cardEdgeHighlight = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.85, darkAlpha: 0.10)

        static let cardBorder = Color.dynamic(light: 0x6B5BD0, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.08)

        static let hairline = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.08)
    }


    enum Typography {
        static let hero = Font.system(size: 32, weight: .bold, design: .default)

        static let heroSecondary = Font.system(size: 28, weight: .semibold, design: .default)

        static let composerPlaceholder = Font.system(size: 18, weight: .medium)

        static let section = Font.system(size: 20, weight: .bold)

        static let body = Font.system(size: 15, weight: .regular)

        static let caption = Font.system(size: 13, weight: .medium)

        static let eyebrow = Font.system(size: 11, weight: .semibold).width(.expanded)

        static let countMono = Font.system(size: 13, weight: .medium, design: .monospaced)
    }
}

// MARK: - Aurora Background

struct AuroraScreenBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        Rectangle()
            .fill(baseFill)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    private var baseFill: LinearGradient {
        if isDark {
            return LinearGradient(
                colors: [Color(hex: 0x1B1A2A), Color(hex: 0x131019)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [Color(hex: 0xF7F5FB), Color(hex: 0xF2EEF7)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Aurora Glass Card

struct AuroraGlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let cornerRadius: CGFloat
    let focused: Bool

    private var isDark: Bool { colorScheme == .dark }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return content
            .background(
                shape
                    .fill(OriveoTheme.Palette.surfaceElevated)
                    .overlay(
                        shape.fill(
                            RadialGradient(
                                colors: [AuroraTheme.Colors.accent.opacity(isDark ? 0.24 : 0.12), .clear],
                                center: .topLeading, startRadius: 0, endRadius: 300
                            )
                        )
                    )
                    .overlay(
                        shape.fill(
                            RadialGradient(
                                colors: [Color(hex: 0xEC8FEA).opacity(isDark ? 0.18 : 0.09), .clear],
                                center: .topTrailing, startRadius: 0, endRadius: 280
                            )
                        )
                    )
                    .overlay {
                        if isDark {
                            shape.fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.05), Color.clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                        }
                    }
            )
            .overlay {
                if isDark {
                    shape
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.75)
                        .allowsHitTesting(false)
                }
            }
            .overlay(
                AuroraGlowBorder(cornerRadius: cornerRadius, active: focused)
                    .allowsHitTesting(false)
            )
            .shadow(color: contactShadow, radius: isDark ? 6 : 5, y: 2)
            .shadow(color: ambientShadow, radius: isDark ? 26 : 24, y: isDark ? 16 : 12)
            .shadow(
                color: AuroraTheme.Colors.accent.opacity(focused ? (isDark ? 0.30 : 0.18) : (isDark ? 0.16 : 0.09)),
                radius: focused ? 46 : 32, y: 14
            )
            .animation(.easeInOut(duration: 0.45), value: focused)
    }

    private var ambientShadow: Color {
        isDark ? Color.black.opacity(0.45) : OriveoTheme.Palette.shadow
    }

    private var contactShadow: Color {
        isDark ? Color.black.opacity(0.30) : Color(hex: 0x0F172A).opacity(0.05)
    }
}

private let auroraGlowColors: [Color] = [
    Color(hex: 0x8B5CF6), Color(hex: 0xA78BFA), Color(hex: 0xEC8FEA),
    Color(hex: 0x8DB4FF), Color(hex: 0x86D2E6), Color(hex: 0xC4B5FD),
    Color(hex: 0x8B5CF6)
]

struct AuroraGlowBorder: View {
    let cornerRadius: CGFloat
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let grad = AngularGradient(gradient: Gradient(colors: auroraGlowColors), center: .center)
        let pulse = active ? ((reduceMotion || breathe) ? 1.0 : 0.72) : 0.82
        ZStack {
            shape.stroke(grad, lineWidth: active ? 4 : 2.4)
                .blur(radius: active ? 6 : 3)
                .opacity((active ? 0.7 : 0.45) * pulse)
            shape.stroke(grad, lineWidth: active ? 2.0 : 1.4)
                .opacity((active ? 1.0 : 0.9) * pulse)
        }
        .animation(.easeInOut(duration: 0.4), value: active)
        .onAppear {
            updateBreathing()
        }
        .onChange(of: active) { _, _ in
            updateBreathing()
        }
        .onChange(of: reduceMotion) { _, _ in
            updateBreathing()
        }
    }

    private func updateBreathing() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            breathe = false
        }

        guard active && !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
            breathe = true
        }
    }
}

extension View {
    func auroraBackground() -> some View {
        background(AuroraScreenBackground())
    }

    func auroraGlassCard(cornerRadius: CGFloat = 24, focused: Bool = false) -> some View {
        modifier(AuroraGlassCardModifier(cornerRadius: cornerRadius, focused: focused))
    }
}

// MARK: - Aurora Section Rule

struct AuroraSectionRule: View {
    var body: some View {
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        AuroraTheme.Colors.accentGlow,
                        AuroraTheme.Colors.accent
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 3, height: 22)
            .shadow(color: AuroraTheme.Colors.accent.opacity(0.55), radius: 6, y: 0)
    }
}

// MARK: - Greeting

enum AuroraGreeting {
    enum Bucket: String {
        case morning, afternoon, evening, night

        static func current(date: Date = .now, calendar: Calendar = .current) -> Bucket {
            let hour = calendar.component(.hour, from: date)
            switch hour {
            case 5..<12: return .morning
            case 12..<18: return .afternoon
            case 18..<23: return .evening
            default: return .night
            }
        }
    }

    static func currentKey(date: Date = .now, calendar: Calendar = .current) -> String {
        switch Bucket.current(date: date, calendar: calendar) {
        case .morning: return "Good morning"
        case .afternoon: return "Good afternoon"
        case .evening: return "Good evening"
        case .night: return "Still up"
        }
    }

    static func placeholderKey(date: Date = .now, calendar: Calendar = .current) -> String {
        return "What can I help with?"
    }


    private static let taglines: [Bucket: [String]] = [
        .morning: [
            "Soft morning.",
            "Take it slow.",
            "Glad you're up.",
            "The day is yours."
        ],
        .afternoon: [
            "Pause if you need.",
            "Still with you.",
            "Halfway is plenty.",
            "Breathe, I'll wait."
        ],
        .evening: [
            "You did enough today.",
            "Soft landing.",
            "You can let it rest.",
            "Today was a lot."
        ],
        .night: [
            "Still here, still listening.",
            "It's okay to be up.",
            "The world is quieter now.",
            "Take your time, the night is patient."
        ]
    ]

    static func taglineKey(date: Date = .now, calendar: Calendar = .current) -> String {
        let bucket = Bucket.current(date: date, calendar: calendar)
        let pool = taglines[bucket] ?? ["Soft morning."]
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let year = calendar.component(.year, from: date)
        let index = abs(dayOfYear &* 31 &+ year) % pool.count
        return pool[index]
    }
}
