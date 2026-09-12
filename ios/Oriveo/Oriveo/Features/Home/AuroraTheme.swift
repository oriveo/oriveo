import SwiftUI

/// Aurora is the visual system used only by the Home screen.
///
/// It leans on iOS 26 Liquid Glass and a soft violet glow, and stays scoped to Home so it
/// does not leak into the global V2 design system.
enum AuroraTheme {

    // MARK: - Palette

    enum Colors {
        /// Primary violet. Same family as the V2 brand `#8C5FF8`, a touch brighter.
        static let accent = Color.dynamic(light: 0x8B5CF6, dark: 0xA78BFA)

        /// Primary violet used for glows and gradient highlights.
        static let accentGlow = Color.dynamic(light: 0x8B5CF6, dark: 0xC4B5FD)

        /// Secondary accent: aurora blue, a subtle complement to the violet.
        static let auroraBlue = Color.dynamic(light: 0x60A5FA, dark: 0x93C5FD)

        /// Aurora green, reserved for live / streaming / online states.
        static let auroraGreen = Color.dynamic(light: 0x10B981, dark: 0x34D399)

        /// Primary text for the hero (warm white / warm ink).
        static let textPrimary = Color.dynamic(light: 0x0A0612, dark: 0xFAFAFB)

        /// Secondary text.
        static let textSecondary = Color.dynamic(light: 0x6B6378, dark: 0xC4BFD3)

        /// Tertiary text (placeholders, supporting labels).
        static let textTertiary = Color.dynamic(light: 0x9C95AA, dark: 0x8C8499)

        /// Tertiary grey used inside the hero card (placeholder, provider name, the up/down chevron).
        /// In dark mode it is a cool grey that shares the card's hue: the global tertiary is a warm
        /// grey-violet (hue 302) and sitting it on a hue-288 card made the dark card look muddy.
        static let heroTextTertiary = Color.dynamic(light: 0x9C95AA, dark: 0x9493A8)

        /// Card fill beneath the liquid glass.
        static let cardFill = Color.dynamic(light: 0xFFFFFF, dark: 0x1A1530, lightAlpha: 0.72, darkAlpha: 0.55)

        /// Highlight stroke on card edges.
        static let cardEdgeHighlight = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.85, darkAlpha: 0.10)

        /// Card border.
        static let cardBorder = Color.dynamic(light: 0x6B5BD0, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.08)

        /// Very light hairline for separators.
        static let hairline = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.08)

        /// Fill of the "search | new folder" capsule in the top bar. No stroke; in light mode the
        /// capsule floats on two very faint shadow layers instead.
        static let chromeFill = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.78, darkAlpha: 0.05)

        /// The 1×16 vertical divider inside the capsule.
        static let chromeDivider = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.11)

        /// Conversation group card fill (dark #221F35 / light pure white).
        static let groupCardFill = Color.dynamic(light: 0xFFFFFF, dark: 0x221F35)

        /// Conversation group card border (dark 5.5% white / light 5% black).
        static let groupCardBorder = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.055)

        /// Model pill fill: a tonal surface without a stroke (light #F3F0FA). Dark mode uses an opaque
        /// tone from the same family; translucent white on the card surface washed out into a grey patch.
        static let pillFill = Color.dynamic(light: 0xF3F0FA, dark: 0x2F2D3F)

        /// Send button: one solid violet in both schemes, no gradient, no shadow.
        static let sendFill = Color(hex: 0x8B5CF6)
    }

    // MARK: - Typography

    enum Typography {
        /// Hero display, 32pt bold. Heavy would flatten the subtitle underneath.
        static let hero = Font.system(size: 32, weight: .bold, design: .default)

        /// Secondary display, 28pt semibold.
        static let heroSecondary = Font.system(size: 28, weight: .semibold, design: .default)

        /// Composer placeholder, 18pt medium. Stays on one line in both CJK and Latin scripts.
        static let composerPlaceholder = Font.system(size: 18, weight: .medium)

        /// Section title, 17pt bold (paired with -0.3 tracking).
        static let section = Font.system(size: 17, weight: .bold)

        /// Body.
        static let body = Font.system(size: 15, weight: .regular)

        /// Caption.
        static let caption = Font.system(size: 13, weight: .medium)

        /// Eyebrow, all caps.
        static let eyebrow = Font.system(size: 11, weight: .semibold).width(.expanded)

        /// Monospaced counters.
        static let countMono = Font.system(size: 13, weight: .medium, design: .monospaced)
    }
}

// MARK: - Aurora Background

/// Full-screen background: one soft, uniform gradient with no local glow, so there is no colour banding.
struct AuroraScreenBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        Rectangle()
            .fill(baseFill)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    /// Flat by design: a clean off-white with a hint of warmth (neither pure white nor cold grey).
    /// Colour lives on the cards; the background neither glows nor hazes.
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

// MARK: - Aurora Hero Surface

/// The material shared by the hero composer card and the Notes entry card.
///
/// - Light: a pure white card with two soft radial glows, clipped inside the corners. Each glow is
///   defined the way the design source positions it: a w×h block filled with
///   `radial-gradient(closest-side, colour, transparent)`, so the ellipse is inscribed in the block and
///   centred at the block origin plus half its size. The end colour is the same colour at 0 alpha,
///   which keeps the interpolation free of grey fringes.
/// - Dark ("aurora rising"): the card is a deep tone from the same family as the list cards, even from
///   left to right and slightly lighter at the top. The aurora lives on the top edge of the 1pt rim
///   ([AuroraCrownRim]) and outside the card ([AuroraCrownHalo]); inside, only a finger-width of
///   afterglow remains. An earlier material with a directional glow inside the card read as muddy:
///   uneven brightness, too much saturation in the dark areas, and grey text whose hue did not match
///   the card.
struct AuroraHeroSurface: View {
    enum Glow {
        /// Hero: violet top-left plus pink top-right in light mode; full-strength aurora afterglow in dark mode.
        case heroPair
        /// Notes: a single violet glow top-right in light mode; a softer aurora afterglow in dark mode.
        case notesCorner
    }

    let cornerRadius: CGFloat
    let glow: Glow

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                fill(size: size)
                if isDark {
                    crownWash(size: size, scale: glow == .heroPair ? 1 : AuroraCrown.notesWashScale)
                } else {
                    switch glow {
                    case .heroPair:
                        // left -60 / top -80 / 260×220; right -70 / top -90 / 240×210
                        blob(tintA, block: CGSize(width: 260, height: 220), center: CGPoint(x: 70, y: 30))
                        blob(tintB, block: CGSize(width: 240, height: 210), center: CGPoint(x: size.width - 50, y: 15))
                    case .notesCorner:
                        // right -50 / top -70 / 220×200
                        blob(tintA, block: CGSize(width: 220, height: 200), center: CGPoint(x: size.width - 60, y: 30))
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func fill(size: CGSize) -> some View {
        if isDark {
            LinearGradient(
                colors: [Color(hex: 0x242235), Self.darkBaseBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            Color.white
        }
    }

    /// The crown's afterglow inside the card: three elliptical glows a finger-width below the top edge,
    /// plus a thin haze that fades out from the top.
    private func crownWash(size: CGSize, scale: Double) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(
                stops: [
                    .init(color: AuroraCrown.wash.opacity(0.075 * scale), location: 0),
                    .init(color: AuroraCrown.wash.opacity(0.03 * scale), location: 38.0 / 70.0),
                    .init(color: AuroraCrown.wash.opacity(0), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: min(70, size.height))
            .frame(maxHeight: .infinity, alignment: .top)

            blob(AuroraCrown.lavender.opacity(0.16 * scale), block: CGSize(width: size.width * 0.72, height: 32), center: CGPoint(x: size.width * 0.22, y: 0))
            blob(AuroraCrown.pink.opacity(0.12 * scale), block: CGSize(width: size.width * 0.60, height: 28), center: CGPoint(x: size.width * 0.52, y: 0))
            blob(AuroraCrown.sky.opacity(0.14 * scale), block: CGSize(width: size.width * 0.72, height: 32), center: CGPoint(x: size.width * 0.80, y: 0))
        }
    }

    private func blob(_ color: Color, block: CGSize, center: CGPoint) -> some View {
        EllipticalGradient(
            colors: [color, color.opacity(0)],
            center: .center,
            startRadiusFraction: 0,
            endRadiusFraction: 0.5
        )
        .frame(width: block.width, height: block.height)
        .position(center)
    }

    /// The violet glow (top-left on the hero, the single glow on Notes) in light mode.
    private var tintA: Color { Color(hex: 0x8B5CF6, alpha: 0.10) }
    /// The pink glow top-right in light mode.
    private var tintB: Color { Color(hex: 0xEC8FEA, alpha: 0.08) }

    /// Bottom colour of the dark card gradient; also the fill of the shadow shape.
    static let darkBaseBottom = Color(hex: 0x201F31)

    /// The 1pt inner rim: a uniform cardBorder in light mode. Dark mode draws it with [AuroraCrownRim].
    static func rim(isDark: Bool) -> AnyShapeStyle {
        AnyShapeStyle(AuroraTheme.Colors.cardBorder)
    }
}

// MARK: - Aurora Crown (dark-mode aurora)

/// Colours and strengths of the aurora crown. The three hues match the Notes glyph; the near-white
/// hot core is reserved for the hero, and Notes always runs one step weaker.
enum AuroraCrown {
    static let lavender = Color(hex: 0xC4B5FD)
    static let pink = Color(hex: 0xEC8FEA)
    static let sky = Color(hex: 0x8DB4FF)
    static let hot = Color(hex: 0xECE6FF)
    /// Haze colour of the afterglow inside the card.
    static let wash = Color(hex: 0xC8BCFF)
    /// Strength on the Notes card: the same light one step weaker, so both cards read as one material.
    static let notesRimScale: Double = 0.55
    static let notesWashScale: Double = 0.6

    /// Five-stop, near-Gaussian falloff (0 / .62 / .28 / .08 / 0).
    static func glowStops(_ color: Color, _ alpha: Double) -> Gradient {
        Gradient(stops: [
            .init(color: color.opacity(alpha), location: 0),
            .init(color: color.opacity(alpha * 0.62), location: 0.26),
            .init(color: color.opacity(alpha * 0.28), location: 0.52),
            .init(color: color.opacity(alpha * 0.08), location: 0.78),
            .init(color: color.opacity(0), location: 1),
        ])
    }
}

/// The aurora crown: a ring of light along the card's 1pt inner rim. Along the top edge it runs
/// lavender → pink → sky from left to right (the hero adds a near-white hot core), fades out quickly
/// past the top corners, and the remaining edges keep the white rim that is brighter at the top.
struct AuroraCrownRim: View {
    let cornerRadius: CGFloat
    /// 1 for the hero, [AuroraCrown.notesRimScale] for Notes.
    var scale: Double = 1
    var hotCore: Bool = true

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                LinearGradient(
                    colors: [Color.white.opacity(0.07), Color.white.opacity(0.035)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                glow(AuroraCrown.sky, 0.95 * scale, radii: CGSize(width: size.width * 0.40, height: 64), x: size.width * 0.86)
                glow(AuroraCrown.pink, 0.80 * scale, radii: CGSize(width: size.width * 0.32, height: 44), x: size.width * 0.52)
                glow(AuroraCrown.lavender, 1.0 * scale, radii: CGSize(width: size.width * 0.40, height: 64), x: size.width * 0.16)
                if hotCore {
                    glow(AuroraCrown.hot, 0.95, radii: CGSize(width: size.width * 0.30, height: 22), x: size.width * 0.50)
                }
            }
            .mask(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.black, lineWidth: 1)
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// An elliptical glow whose centre sits on the top edge. `radii` are radii, as in CSS
    /// `radial-gradient(ellipse rx ry at …)`.
    private func glow(_ color: Color, _ alpha: Double, radii: CGSize, x: CGFloat) -> some View {
        EllipticalGradient(
            gradient: AuroraCrown.glowStops(color, alpha),
            center: .center,
            startRadiusFraction: 0,
            endRadiusFraction: 0.5
        )
        .frame(width: radii.width * 2, height: radii.height * 2)
        .position(x: x, y: 0)
    }
}

/// The halo outside the card: two blurred colour bands hugging the card shape and lifted upwards.
/// The wide band spreads light beyond the card; the bright core sits tight against the top edge and
/// produces the bright line. The card surface is opaque and covers the middle, so only the ring outside
/// the card shows through. The values match the two-layer brush shadow used on Android.
struct AuroraCrownHalo: View {
    let cornerRadius: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                // SwiftUI's `.blur(radius:)` spreads about 1.5× wider than Compose's shadow radius
                // (measured on both platforms), so the Android sigma is divided by 1.5 here to get the
                // same halo width.
                layer(size: size, blur: 10, dy: -11, inset: 7, opacity: 0.56)
                layer(size: size, blur: 2.3, dy: -2.5, inset: 1, opacity: 0.65)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func layer(size: CGSize, blur: CGFloat, dy: CGFloat, inset: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: max(cornerRadius - inset, 0), style: .continuous)
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: AuroraCrown.lavender.opacity(0.20), location: 0),
                        .init(color: AuroraCrown.lavender.opacity(0.95), location: 0.2),
                        .init(color: AuroraCrown.pink.opacity(0.85), location: 0.5),
                        .init(color: AuroraCrown.sky.opacity(0.95), location: 0.8),
                        .init(color: AuroraCrown.sky.opacity(0.20), location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: max(size.width - inset * 2, 0), height: max(size.height - inset * 2, 0))
            .offset(y: dy)
            .blur(radius: blur)
            .opacity(opacity)
            .frame(width: size.width, height: size.height)
    }
}

// MARK: - Aurora Glass Card

/// Resolves the hero card's state into its appearance: idle is purely flat (surface + 1pt rim + two
/// soft glows, no aurora ring); focus shows the existing AuroraGlowBorder and hides the 1pt rim.
/// Both shadow slots always exist so colour and radius can animate continuously across the focus change.
struct AuroraHeroCardAppearance: Equatable {
    struct Shadow: Equatable {
        let color: Color
        let radius: CGFloat
        let y: CGFloat

        static let none = Shadow(color: .clear, radius: 0, y: 0)
    }

    let showsGlowBorder: Bool
    let showsHairlineBorder: Bool
    let contactShadow: Shadow
    let ambientShadow: Shadow

    static func resolve(isDark: Bool, focused: Bool) -> AuroraHeroCardAppearance {
        let contact: Shadow
        let ambient: Shadow
        if isDark {
            // 0 12 28 -6 rgba(0,0,0,.36), unchanged on focus (the coloured light comes from the crown
            // and the glow ring). SwiftUI's `.shadow` has no spread, and the 6pt shrink is invisible
            // on a dark ground, so only blur and y are kept.
            contact = .none
            ambient = Shadow(color: Color.black.opacity(0.36), radius: 14, y: 12)
        } else if focused {
            // 0 14 40 rgba(139,92,246,.16)
            contact = .none
            ambient = Shadow(color: Color(hex: 0x8B5CF6, alpha: 0.16), radius: 20, y: 14)
        } else {
            // 0 1 2 rgba(15,23,42,.04) + 0 10 28 rgba(139,92,246,.08)
            contact = Shadow(color: Color(hex: 0x0F172A, alpha: 0.04), radius: 1, y: 1)
            ambient = Shadow(color: Color(hex: 0x8B5CF6, alpha: 0.08), radius: 14, y: 10)
        }
        return AuroraHeroCardAppearance(
            showsGlowBorder: focused,
            showsHairlineBorder: !focused,
            contactShadow: contact,
            ambientShadow: ambient
        )
    }
}

/// The hero composer card: AuroraHeroSurface material plus the state-driven appearance
/// (see AuroraHeroCardAppearance). Transitions (0.4s) only touch the decorative layers, never the
/// text field content.
struct AuroraGlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let cornerRadius: CGFloat
    let focused: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let isDark = colorScheme == .dark
        let appearance = AuroraHeroCardAppearance.resolve(isDark: isDark, focused: focused)
        let transition = Animation.easeInOut(duration: 0.4)

        return content
            .background {
                AuroraHeroSurface(cornerRadius: cornerRadius, glow: .heroPair)
                    .background {
                        // The halo outside the card only exists in the dark idle state. On focus it fades
                        // out together with the crown and hands over to the glow ring; two lights on top
                        // of each other would smear.
                        AuroraCrownHalo(cornerRadius: cornerRadius)
                            .opacity(isDark && !focused ? 1 : 0)
                            .animation(transition, value: focused)
                    }
                    .background {
                        // Shadows hang off the card shape only, so text and the glow ring cast none.
                        shape
                            .fill(isDark ? AuroraHeroSurface.darkBaseBottom : Color.white)
                            .shadow(
                                color: appearance.contactShadow.color,
                                radius: appearance.contactShadow.radius,
                                y: appearance.contactShadow.y
                            )
                            .shadow(
                                color: appearance.ambientShadow.color,
                                radius: appearance.ambientShadow.radius,
                                y: appearance.ambientShadow.y
                            )
                            .animation(transition, value: focused)
                    }
            }
            .overlay {
                Group {
                    if isDark {
                        AuroraCrownRim(cornerRadius: cornerRadius)
                    } else {
                        shape.strokeBorder(AuroraHeroSurface.rim(isDark: isDark), lineWidth: 1)
                    }
                }
                .opacity(appearance.showsHairlineBorder ? 1 : 0)
                .animation(transition, value: focused)
                .allowsHitTesting(false)
            }
            .overlay {
                // The ring sits entirely outside the card (inset -2): the stroke centreline is pushed
                // out by 1pt, so the 2pt ring runs from the card edge to 2pt outside it.
                AuroraGlowBorder(cornerRadius: cornerRadius + 1, active: focused)
                    .padding(-1)
                    .opacity(appearance.showsGlowBorder ? 1 : 0)
                    .animation(transition, value: focused)
                    .allowsHitTesting(false)
            }
    }
}

/// The flowing aurora edge: an AngularGradient ring (violet → pink → blue → teal) plus a blurred glow.
/// The hero only shows it while focused (idle is flat; AuroraGlassCardModifier hides it). When active
/// it gets thicker and brighter and breathes (a repeatForever animation that only runs while active);
/// with reduce motion it holds still.
/// The ring is violet-led: violet → lavender → pink → blue → soft teal (an accent) → lavender → violet.
/// The teal is 0x86D2E6, a bluer tone than the earlier fluorescent mint 0x67E8C9, which keeps the
/// cool aurora accent without the candy glow.
private let auroraGlowColors: [Color] = [
    Color(hex: 0x8B5CF6), Color(hex: 0xA78BFA), Color(hex: 0xEC8FEA),
    Color(hex: 0x8DB4FF), Color(hex: 0x86D2E6), Color(hex: 0xC4B5FD),
    Color(hex: 0x8B5CF6)
]

/// The aurora stroke: `shape.stroke(AngularGradient)` gives a crisp rainbow edge (deterministic, so it
/// can be screenshotted) with a slow brightness "breath". Breathing replaces rotating colour blocks:
/// it is alive without spilling large patches outside the card. Focus makes it thicker and brighter;
/// reduce motion disables the breathing.
struct AuroraGlowBorder: View {
    let cornerRadius: CGFloat
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // The source is `conic-gradient(from 200deg, …)`. CSS puts 0° at 12 o'clock and SwiftUI at
        // 3 o'clock, so the start angle is 200 - 90 = 110°.
        let grad = AngularGradient(gradient: Gradient(colors: auroraGlowColors), center: .center, angle: .degrees(110))
        // Stay static while unfocused, otherwise the vertical violet highlight on the bottom-right
        // corner reads as a second caret. Only breathe between 0.72 and 1.0 once focused.
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
    /// Applies the Aurora screen background.
    func auroraBackground() -> some View {
        background(AuroraScreenBackground())
    }

    /// Applies the Aurora glass card style (aurora glow that wakes up on focus).
    func auroraGlassCard(cornerRadius: CGFloat = 24, focused: Bool = false) -> some View {
        modifier(AuroraGlassCardModifier(cornerRadius: cornerRadius, focused: focused))
    }
}

// MARK: - Aurora Section Rule

/// The glowing violet bar to the left of section titles: 3×18, #C4B5FD → #8B5CF6, with an outer glow
/// of 8px at 55% in dark mode and 6px at 35% in light mode.
struct AuroraSectionRule: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(hex: 0xC4B5FD), Color(hex: 0x8B5CF6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 3, height: 18)
            .shadow(
                color: isDark ? Color(hex: 0xA78BFA, alpha: 0.55) : Color(hex: 0x8B5CF6, alpha: 0.35),
                radius: isDark ? 4 : 3,
                y: 0
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Aurora Grouped Card

/// The conversation group card on Home: one card per group, no separators inside, rows kept apart by
/// padding alone. Corner radius 20. Dark: #221F35 + 5.5% white border + a 1px 3% white inner highlight
/// at the top. Light: pure white + 5% black border + two very faint shadows.
/// Used only by the Home family (Pinned / date groups / search results / folders); the shared
/// GroupedCard still serves the skill editor and other V2 screens.
struct AuroraGroupedCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let isDark = colorScheme == .dark

        // The 1px border takes up space (border-box): row content sits 1 + row padding from the card
        // edge, and the card is 2pt taller than its rows.
        let innerShape = shape.inset(by: 1)

        content()
            .padding(1)
            .background(AuroraTheme.Colors.groupCardFill)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(AuroraTheme.Colors.groupCardBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                // box-shadow: 0 1px 0 rgba(255,255,255,.03) inset, drawn inside the border (padding
                // box): the inner shape minus a copy of itself shifted down 1px leaves a crescent just
                // below the border.
                if isDark {
                    innerShape.subtracting(innerShape.offset(y: 1))
                        .fill(Color.white.opacity(0.03))
                        .allowsHitTesting(false)
                }
            }
            .background {
                // The shadow hangs off a separate card shape so the clipShape above cannot cut it off.
                shape
                    .fill(AuroraTheme.Colors.groupCardFill)
                    .shadow(color: isDark ? .clear : Color(hex: 0x0F172A, alpha: 0.04), radius: 1, y: 1)
                    .shadow(color: isDark ? .clear : Color(hex: 0x0F172A, alpha: 0.04), radius: 9, y: 6)
            }
    }
}

// MARK: - Greeting

enum AuroraGreeting {
    /// Time of day: morning / afternoon / evening / night.
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

    /// The greeting i18n key for the current time of day (resolved through L10n.tr).
    static func currentKey(date: Date = .now, calendar: Calendar = .current) -> String {
        switch Bucket.current(date: date, calendar: calendar) {
        case .morning: return "Good morning"
        case .afternoon: return "Good afternoon"
        case .evening: return "Good evening"
        case .night: return "Still up"
        }
    }

    /// One short placeholder for every time of day, so it never wraps.
    static func placeholderKey(date: Date = .now, calendar: Calendar = .current) -> String {
        return "What can I help with?"
    }

    // MARK: - Tagline (16 lines = 4 buckets × 4, one picked per day by hash)

    /// Sixteen taglines by time of day, written around self-compassion, autonomy, companionship,
    /// containment, validation and presence. They deliberately avoid toxic positivity ("you've got
    /// this", "keep pushing").
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

    /// The tagline i18n key for the current time of day. Stable within a day (no flicker), new line the next day.
    static func taglineKey(date: Date = .now, calendar: Calendar = .current) -> String {
        let bucket = Bucket.current(date: date, calendar: calendar)
        let pool = taglines[bucket] ?? ["Soft morning."]
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let year = calendar.component(.year, from: date)
        let index = abs(dayOfYear &* 31 &+ year) % pool.count
        return pool[index]
    }
}
