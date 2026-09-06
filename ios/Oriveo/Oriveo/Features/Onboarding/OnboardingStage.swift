import SwiftUI



enum OnboardingAct: Int, CaseIterable, Identifiable {
    case brand = 0
    case models
    case byok
    case start

    var id: Int { rawValue }

    var stepName: String {
        switch self {
        case .brand: return "welcome"
        case .models: return "models"
        case .byok: return "byok"
        case .start: return "start"
        }
    }
}


enum OnboardingMath {
    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    static func lerp(_ from: Double, _ to: Double, _ t: Double) -> Double {
        from + (to - from) * t
    }

    static func tri(_ p: Double, _ center: Double, _ half: Double) -> Double {
        guard half > 0 else { return p == center ? 1 : 0 }
        return clamp(1 - abs(p - center) / half, 0, 1)
    }

    static func smoothstep(_ t: Double) -> Double {
        let x = clamp(t, 0, 1)
        return x * x * (3 - 2 * x)
    }
}


struct OnboardingRGB: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    static func lerp(_ from: OnboardingRGB, _ to: OnboardingRGB, _ t: Double) -> OnboardingRGB {
        OnboardingRGB(
            red: OnboardingMath.lerp(from.red, to.red, t),
            green: OnboardingMath.lerp(from.green, to.green, t),
            blue: OnboardingMath.lerp(from.blue, to.blue, t)
        )
    }

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}


struct OnboardingStageValues {
    static let auroraPalette: [(top: OnboardingRGB, bottom: OnboardingRGB)] = [
        (OnboardingRGB(hex: 0x7C3AED), OnboardingRGB(hex: 0x2A1E5C)),
        (OnboardingRGB(hex: 0x4F46E5), OnboardingRGB(hex: 0x0D9488)),
        (OnboardingRGB(hex: 0x6D28D9), OnboardingRGB(hex: 0xB45309)),
        (OnboardingRGB(hex: 0x9D7BFF), OnboardingRGB(hex: 0x7C3AED))
    ]

    static let dotsBarWidth: Double = 84
    static let referenceWidth: Double = 390

    let progress: Double

    let auroraTop: OnboardingRGB
    let auroraBottom: OnboardingRGB

    let ringsOpacity: Double
    let orbitersOpacity: Double
    let orbitersOffsetX: Double

    let nucleusOpacity: Double
    let nucleusOffsetX: Double
    let nucleusScale: Double

    let byokOpacity: Double
    let byokOffsetX: Double
    let byokScale: Double

    let startBadgeOpacity: Double
    let startBadgeOffsetX: Double
    let startBadgeScale: Double

    let ctaMorph: Double
    let pillWidth: Double
    let dotsOpacity: Double
    let ctaLabelOpacity: Double
    let loginOpacity: Double
    let loginOffsetY: Double
    let skipOpacity: Double

    init(progress: Double, width: Double) {
        let pageCount = Double(OnboardingAct.allCases.count)
        let pc = OnboardingMath.clamp(progress, -0.35, pageCount - 1 + 0.35)
        self.progress = pc

        let index = Int(OnboardingMath.clamp(floor(pc), 0, pageCount - 2))
        let fraction = OnboardingMath.clamp(pc - Double(index), 0, 1)
        auroraTop = OnboardingRGB.lerp(
            Self.auroraPalette[index].top,
            Self.auroraPalette[index + 1].top,
            fraction
        )
        auroraBottom = OnboardingRGB.lerp(
            Self.auroraPalette[index].bottom,
            Self.auroraPalette[index + 1].bottom,
            fraction
        )

        let parallax = width * 0.25

        ringsOpacity = OnboardingMath.clamp(
            0.35
                + 0.65 * max(OnboardingMath.tri(pc, 0, 1.2), OnboardingMath.tri(pc, 1, 1.2))
                - 0.25 * OnboardingMath.tri(pc, 2, 1),
            0,
            1
        )

        orbitersOpacity = OnboardingMath.tri(pc, 1, 1.0)
        orbitersOffsetX = (1 - pc) * width * 0.18

        let nucleus = max(OnboardingMath.tri(pc, 0, 1), OnboardingMath.tri(pc, 1, 1) * 0.92)
        nucleusOpacity = nucleus
        nucleusOffsetX = -OnboardingMath.clamp(pc - 1, 0, 2) * parallax
            + OnboardingMath.clamp(-pc, 0, 1) * parallax
        nucleusScale = 0.86 + 0.14 * nucleus

        let byok = OnboardingMath.tri(pc, 2, 0.85)
        byokOpacity = byok
        byokOffsetX = (2 - pc) * parallax
        byokScale = 0.9 + 0.1 * byok

        let free = OnboardingMath.tri(pc, 3, 0.85)
        startBadgeOpacity = free
        startBadgeOffsetX = (3 - pc) * parallax
        startBadgeScale = 0.9 + 0.1 * free

        let raw = OnboardingMath.clamp((pc - 2.2) / 0.8, 0, 1)
        let morph = OnboardingMath.smoothstep(raw)
        ctaMorph = morph
        pillWidth = OnboardingMath.lerp(
            Self.dotsBarWidth,
            max(width - 72, Self.dotsBarWidth),
            morph
        )
        dotsOpacity = 1 - OnboardingMath.clamp(morph * 1.6, 0, 1)
        ctaLabelOpacity = OnboardingMath.clamp((morph - 0.45) / 0.55, 0, 1)
        loginOpacity = OnboardingMath.clamp((morph - 0.55) / 0.45, 0, 1)
        loginOffsetY = (1 - morph) * 8
        skipOpacity = 1 - OnboardingMath.clamp((pc - 2.1) / 0.6, 0, 1)
    }

    func copyOpacity(for act: OnboardingAct) -> Double {
        OnboardingMath.tri(progress, Double(act.rawValue), 0.62)
    }

    var isSkipInteractive: Bool { progress <= 2.6 }
    var isCTAInteractive: Bool { progress > 2.7 }
    var areDotsInteractive: Bool { ctaMorph <= 0.4 }
}


struct OnboardingOrbitRing {
    let radiusX: Double
    let radiusY: Double
    let tiltDegrees: Double
    let strokeOpacity: Double
    let periodSeconds: Double
    let isReversed: Bool
}

struct OnboardingOrbiter: Identifiable {
    let assetName: String
    let size: Double
    let ringIndex: Int
    let phase: Double

    var id: String { assetName }
}

struct OnboardingOrbitPoint {
    let x: Double
    let y: Double
    let depth: Double
}

enum OnboardingOrbitCatalog {
    static let rings: [OnboardingOrbitRing] = [
        OnboardingOrbitRing(
            radiusX: 176, radiusY: 62, tiltDegrees: -24,
            strokeOpacity: 0.30, periodSeconds: 64, isReversed: false
        ),
        OnboardingOrbitRing(
            radiusX: 150, radiusY: 54, tiltDegrees: 30,
            strokeOpacity: 0.20, periodSeconds: 78, isReversed: true
        ),
        OnboardingOrbitRing(
            radiusX: 122, radiusY: 46, tiltDegrees: 84,
            strokeOpacity: 0.12, periodSeconds: 105, isReversed: false
        )
    ]

    static let orbiters: [OnboardingOrbiter] = [
        OnboardingOrbiter(assetName: "ProviderOpenAI", size: 40, ringIndex: 0, phase: 0.00),
        OnboardingOrbiter(assetName: "ProviderGemini", size: 38, ringIndex: 0, phase: 0.26),
        OnboardingOrbiter(assetName: "ProviderDeepSeek", size: 44, ringIndex: 0, phase: 0.52),
        OnboardingOrbiter(assetName: "ProviderMistral", size: 34, ringIndex: 0, phase: 0.76),
        OnboardingOrbiter(assetName: "ProviderAnthropic", size: 36, ringIndex: 1, phase: 0.05),
        OnboardingOrbiter(assetName: "ProviderQwen", size: 36, ringIndex: 1, phase: 0.30),
        OnboardingOrbiter(assetName: "ProviderGrok", size: 32, ringIndex: 1, phase: 0.55),
        OnboardingOrbiter(assetName: "ProviderKimi", size: 28, ringIndex: 1, phase: 0.80)
    ]

    static func position(for orbiter: OnboardingOrbiter, time: Double) -> OnboardingOrbitPoint {
        let ring = rings[min(orbiter.ringIndex, rings.count - 1)]
        let direction: Double = ring.isReversed ? -1 : 1
        let theta = (orbiter.phase + direction * time / ring.periodSeconds) * 2 * .pi
        let localX = ring.radiusX * cos(theta)
        let localY = ring.radiusY * sin(theta)
        let tilt = ring.tiltDegrees * .pi / 180
        return OnboardingOrbitPoint(
            x: localX * cos(tilt) - localY * sin(tilt),
            y: localX * sin(tilt) + localY * cos(tilt),
            depth: sin(theta)
        )
    }

    static func decorativeSpinDegrees(time: Double) -> Double {
        let ring = rings[2]
        return ring.tiltDegrees + time / ring.periodSeconds * 360
    }
}


enum OnboardingMotionPolicy {
    static func isOrbitClockPaused(reduceMotion: Bool, isStageActive: Bool) -> Bool {
        reduceMotion || !isStageActive
    }

    static func revealsInstantly(reduceMotion: Bool) -> Bool {
        reduceMotion
    }
}


enum OnboardingCopyMarkup {
    struct Segment: Equatable {
        let text: String
        let isHighlighted: Bool
    }

    static func parse(_ raw: String) -> [Segment] {
        var segments: [Segment] = []
        var buffer = ""
        var isInsideHighlight = false

        for character in raw {
            if character == "{", !isInsideHighlight {
                if !buffer.isEmpty {
                    segments.append(Segment(text: buffer, isHighlighted: false))
                    buffer = ""
                }
                isInsideHighlight = true
            } else if character == "}", isInsideHighlight {
                if !buffer.isEmpty {
                    segments.append(Segment(text: buffer, isHighlighted: true))
                    buffer = ""
                }
                isInsideHighlight = false
            } else {
                buffer.append(character)
            }
        }

        if !buffer.isEmpty {
            segments.append(Segment(text: isInsideHighlight ? "{" + buffer : buffer, isHighlighted: false))
        }
        return segments
    }

    static func plainText(_ raw: String) -> String {
        parse(raw).map(\.text).joined()
    }
}
