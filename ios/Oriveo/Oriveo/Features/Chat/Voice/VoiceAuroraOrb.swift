import os
import SwiftUI

// Liquid aurora orb (148 pt) on the voice stage, and the aurora haze at the bottom of the panel.
// Geometry and colors are given on the canvas viewBox 200 (orb radius 78); scaled by size/200 when drawing:
// size is the orb box (including the glow margin); visible orb diameter = size x 0.78.
// Animation reads frame time only inside the Canvas draw closure; the timeline pauses under Reduce Motion, or when muted with no level.

/// Display mode of the orb and haze, mapped from session state by the caller.
enum VoiceOrbMode: Equatable, Sendable {
    case listen
    case user
    case think
    case ai
    case muted
}

/// Pure functions for the orb and haze, shared by the view and tests.
enum VoiceOrbMath {
    /// Canvas viewBox edge length: orb box size maps to 200 units.
    static let viewBoxUnits: Double = 200
    /// Canvas units: orb radius 78, diameter 156.
    static let orbRadiusUnits: Double = 78

    /// Points per canvas unit.
    static func unit(size: Double) -> Double { size / viewBoxUnits }
    /// Visible orb radius (pt) = size x 78 / 200.
    static func visibleOrbRadius(size: Double) -> Double { orbRadiusUnits * unit(size: size) }

    /// Ellipse in viewBox coordinates: center and semi-axes.
    struct OrbEllipse: Equatable {
        let cx: Double
        let cy: Double
        let rx: Double
        let ry: Double
    }

    /// Top-left highlight: center (82,58), semi-axes 52 x 32.
    static let highlightEllipse = OrbEllipse(cx: 82, cy: 58, rx: 52, ry: 32)
    /// Bottom reflection: center (100,152), semi-axes 56 x 26.
    static let reflectionEllipse = OrbEllipse(cx: 100, cy: 152, rx: 56, ry: 26)

    /// Circumscribed rect of the ellipse in the orb box (size x size, origin top-left).
    static func rect(_ e: OrbEllipse, size: Double) -> CGRect {
        let k = unit(size: size)
        return CGRect(x: (e.cx - e.rx) * k, y: (e.cy - e.ry) * k, width: 2 * e.rx * k, height: 2 * e.ry * k)
    }
    /// Time constant (seconds) of the envelope first-order filter.
    static let attack: Double = 0.040
    static let release: Double = 0.200
    /// Secondary smoothing time constant (seconds): a symmetric first-order filter after the envelope, smoothing the corners of the 15 Hz level steps.
    static let smoothTau: Double = 0.024
    /// Light jitter: +/-4 pt, three back-and-forth swings, 240 ms.
    static let nudgeDuration: Double = 0.240
    static let nudgeAmplitude: Double = 4
    static let nudgeCycles: Double = 3
    /// Muted group parameters.
    static let dimmedAlpha: Double = 0.55
    static let dimmedSaturation: Double = 0.15
    static let dimmedGlowAlpha: Double = 0.10

    static func clamp01(_ value: Double) -> Double { min(1, max(0, value)) }

    /// Minimum timeline frame interval: orb 60 fps, haze 30 fps (not following the screen refresh rate).
    static let orbFrameInterval: Double = 1.0 / 60
    static let fogFrameInterval: Double = 1.0 / 30
    /// Duration of the switch between the user and AI palettes and the amber hint (easeInOut).
    static let paletteTransition: Double = 0.200

    /// Palette blend factor: after a switch, elapsed seconds take 0 to 1 over 200 ms easeInOut; Reduce Motion jumps straight to 1.
    static func paletteMix(elapsed: Double, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 1 }
        guard elapsed > 0 else { return 0 }
        guard elapsed < paletteTransition else { return 1 }
        return easeInOut(elapsed / paletteTransition)
    }

    /// Same cubic bezier as SwiftUI `.easeInOut` (0.42, 0, 0.58, 1): bisect on x to find the parameter, then take y.
    static func easeInOut(_ progress: Double) -> Double {
        let x = clamp01(progress)
        func bezier(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s
        }
        var low = 0.0
        var high = 1.0
        for _ in 0..<32 {
            let mid = (low + high) / 2
            if bezier(mid, 0.42, 0.58) < x { low = mid } else { high = mid }
        }
        return bezier((low + high) / 2, 0, 1)
    }

    /// Split 0xRRGGBB into 0...1 components.
    struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init(hex: UInt32) {
            self.init(
                red: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255
            )
        }
    }

    /// Linear interpolation of two colors by t (t = 0 gives from, 1 gives to).
    static func mix(_ from: UInt32, _ to: UInt32, _ t: Double) -> RGB {
        let a = RGB(hex: from)
        let b = RGB(hex: to)
        let k = clamp01(t)
        return RGB(
            red: a.red + (b.red - a.red) * k,
            green: a.green + (b.green - a.green) * k,
            blue: a.blue + (b.blue - a.blue) * k
        )
    }

    /// breathe = .5 + .5 sin(t / 1100 ms).
    static func breathe(time: Double) -> Double {
        0.5 + 0.5 * sin(time / 1.1)
    }

    /// Envelope: first-order filter using attack when rising and release when falling, stepped per frame interval.
    static func envelope(current: Double, target: Double, dt: Double) -> Double {
        let goal = clamp01(target)
        guard dt > 0 else { return current }
        let tau = goal > current ? attack : release
        return current + (goal - current) * (1 - exp(-dt / tau))
    }

    /// Secondary smoothing: symmetric first-order filter with time constant smoothTau applied to the first envelope.
    static func smooth(current: Double, target: Double, dt: Double) -> Double {
        guard dt > 0 else { return current }
        return current + (target - current) * (1 - exp(-dt / smoothTau))
    }

    /// Energy under the stage-clock override (sample frames): the envelope is the level, using production energy (AI = 0.9 x envelope), i.e. the production steady state at that level.
    static func stageEnergy(mode: VoiceOrbMode, level: Double, time: Double) -> Double {
        energy(mode: mode, envelope: level, breathe: breathe(time: time))
    }

    static func isDimmed(_ mode: VoiceOrbMode) -> Bool { mode == .muted }

    /// Only AI speaking uses the AI palette; thinking and the rest keep the user palette (same convention as canvas and Android).
    static func usesAIPalette(_ mode: VoiceOrbMode) -> Bool { mode == .ai }

    /// Energy E. Under Reduce Motion all modes are 0 (glow and haze alpha do not follow the level); the level is expressed only by orb alpha.
    static func energy(mode: VoiceOrbMode, envelope: Double, breathe: Double, reduceMotion: Bool = false) -> Double {
        guard !reduceMotion else { return 0 }
        let env = clamp01(envelope)
        switch mode {
        case .user: return env
        case .ai: return 0.9 * env
        case .think: return 0.45
        case .listen: return 0.15 * breathe
        case .muted: return 0.05
        }
    }

    /// Scale; not scaled under Reduce Motion.
    static func scale(mode: VoiceOrbMode, energy: Double, breathe: Double, reduceMotion: Bool = false) -> Double {
        guard !reduceMotion else { return 1 }
        switch mode {
        case .user: return 1 + 0.16 * energy
        case .ai: return 1 + 0.08 * energy
        case .listen: return 1 + 0.025 * breathe
        case .think: return 0.95
        case .muted: return 1
        }
    }

    /// Phase speed (per second); phase does not advance under Reduce Motion.
    static func phaseSpeed(mode: VoiceOrbMode, energy: Double, reduceMotion: Bool = false) -> Double {
        guard !reduceMotion else { return 0 }
        switch mode {
        case .listen: return 0.22
        case .user: return 0.45 + 0.9 * energy
        case .think: return 1.25
        case .ai: return 0.4 + 0.6 * energy
        case .muted: return 0.05
        }
    }

    /// Overall orb alpha: muted group .55; under Reduce Motion the level is expressed as 0.6 + 0.4 x level.
    static func orbAlpha(mode: VoiceOrbMode, level: Double, reduceMotion: Bool) -> Double {
        if isDimmed(mode) { return dimmedAlpha }
        guard reduceMotion else { return 1 }
        return 0.6 + 0.4 * clamp01(level)
    }

    static func saturation(mode: VoiceOrbMode) -> Double {
        isDimmed(mode) ? dimmedSaturation : 1
    }

    /// Whole-group alpha of the outer glow: bright .38 / dark .55, plus .45E; muted group .1.
    static func glowAlpha(mode: VoiceOrbMode, energy: Double, dark: Bool) -> Double {
        if isDimmed(mode) { return dimmedGlowAlpha }
        return clamp01((dark ? 0.55 : 0.38) + 0.45 * energy)
    }

    /// Three outer glow circles (viewBox units): centers orbit (100,108) on an 18 x 14 ellipse, radius 58 + 16E.
    static func glowCircles(phase: Double, energy: Double) -> [(cx: Double, cy: Double, r: Double)] {
        (0..<3).map { i in
            let a = 0.7 * phase + 2.1 * Double(i)
            return (100 + 18 * cos(a), 108 + 14 * sin(a), 58 + 16 * energy)
        }
    }

    /// Light jitter horizontal offset (pt): three swings within 240 ms after start, then zero; no jitter under Reduce Motion.
    static func nudgeOffset(elapsed: Double, reduceMotion: Bool = false) -> Double {
        guard !reduceMotion, elapsed >= 0, elapsed < nudgeDuration else { return 0 }
        return nudgeAmplitude * sin(2 * .pi * nudgeCycles * elapsed / nudgeDuration)
    }

    /// Under Reduce Motion, light jitter becomes an alpha flash instead (multiplier, minimum .6).
    static func nudgeAlpha(elapsed: Double, reduceMotion: Bool) -> Double {
        guard reduceMotion, elapsed >= 0, elapsed < nudgeDuration else { return 1 }
        return 1 - 0.4 * sin(.pi * elapsed / nudgeDuration)
    }

    /// Opposite horizontal drift of the two haze blobs (pt): +/-20 sin(t / 2600 ms); no drift under Reduce Motion.
    static func fogDrift(time: Double, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 0 }
        return 20 * sin(time / 2.6)
    }

    /// One haze blob.
    struct FogCircle: Equatable {
        let color: UInt32
        let alpha: Double
        /// Canvas Gaussian sigma (pt); when drawing, use the disc-convolved-with-Gaussian profile from fogProfile(diameter:sigma:).
        let blur: Double
        let diameter: Double
        /// Drift direction: +1 / -1 / 0.
        let driftSign: Double
    }

    static let amber: UInt32 = 0xF59E0B

    /// Reference panel width 390 for the haze blob centers (x scales with panel width).
    static let fogBaseWidth: Double = 390
    /// Haze canvas extends 40 pt beyond the panel on each side (width = panel + 80).
    static let fogBleed: Double = 40
    /// Haze frame height 520 (canvas Main / Android FogHeight).
    static let fogHeight: Double = 520
    /// Haze frame bottom extends 120 pt below the stage bottom (canvas bottom -120 / Android FogBelow).
    static let fogBelow: Double = 120

    /// Haze frame (panel coordinates): 40 bleed on each side, height 520, bottom = stage bottom + bottom safe-area inset + 120,
    /// matching the canvas haze container relative to full-screen bottom -120; the frame moves with the bottom edge when the stage grows taller.
    static func fogFrame(panelSize: CGSize, bottomInset: Double = 0) -> CGRect {
        CGRect(
            x: -fogBleed,
            y: Double(panelSize.height) + bottomInset + fogBelow - fogHeight,
            width: Double(panelSize.width) + 2 * fogBleed,
            height: fogHeight
        )
    }

    /// Actual Gaussian sigma / radius of GraphicsContext blur(radius:): unit tests measure the 16%-84% transition width of a white half-plane;
    /// radius 14-80 measures 0.950-0.967, so 0.96 is used.
    static let blurSigmaPerRadius: Double = 0.96

    /// Canvas Gaussian sigma (pt) to GraphicsContext blur(radius:), so the actual sigma equals the canvas sigma.
    static func blurRadius(sigma: Double) -> CGFloat {
        CGFloat(sigma / blurSigmaPerRadius)
    }

    /// Radial profile of one haze blob: disc (radius R) convolved with Gaussian sigma at rho, 41 evenly spaced stops covering [0, extent], extent = R + 4 sigma, last stop set to 0.
    struct FogProfile: Equatable, Sendable {
        let sigma: Double
        let extent: Double
        let stops: [Double]
    }

    static let fogProfileStopCount = 41

    /// Disc convolved with Gaussian: P(rho) = integral from 0 to R of (t/sigma^2) e^(-(rho-t)^2/2sigma^2) I0e(rho t/sigma^2) dt, Simpson with 256 segments.
    static func fogDiscIntensity(rho: Double, radius: Double, sigma: Double) -> Double {
        guard radius > 0, sigma > 0 else { return 0 }
        let s2 = sigma * sigma
        func f(_ t: Double) -> Double {
            let d = rho - t
            return t / s2 * exp(-d * d / (2 * s2)) * besselI0e(rho * t / s2)
        }
        let n = 256
        let h = radius / Double(n)
        var sum = f(0) + f(radius)
        for k in 1..<n { sum += (k % 2 == 1 ? 4 : 2) * f(Double(k) * h) }
        return sum * h / 3
    }

    /// e^(-x) I0(x) (x >= 0), Abramowitz & Stegun 9.8.1 / 9.8.2.
    static func besselI0e(_ x: Double) -> Double {
        let ax = abs(x)
        if ax <= 3.75 {
            let t = ax / 3.75, y = t * t
            let i0 = 1 + y * (3.5156229 + y * (3.0899424 + y * (1.2067492 + y * (0.2659732 + y * (0.0360768 + y * 0.0045813)))))
            return exp(-ax) * i0
        }
        let y = 3.75 / ax
        let p = 0.39894228 + y * (0.01328592 + y * (0.00225319 + y * (-0.00157565 + y * (0.00916281
            + y * (-0.02057706 + y * (0.02635537 + y * (-0.01647633 + y * 0.00392377)))))))
        return p / ax.squareRoot()
    }

    private struct FogProfileKey: Hashable {
        let diameter: Double
        let sigma: Double
    }

    private static let fogProfileCache = OSAllocatedUnfairLock(initialState: [FogProfileKey: FogProfile]())

    /// Haze blob profile, cached by (diameter 0.5, sigma 0.5); during transitions diameter and sigma interpolate continuously but land on only a finite set of steps.
    static func fogProfile(diameter: Double, sigma: Double) -> FogProfile {
        func half(_ x: Double) -> Double { (x * 2).rounded() / 2 }
        let key = FogProfileKey(diameter: half(diameter), sigma: half(sigma))
        if let hit = fogProfileCache.withLock({ $0[key] }) { return hit }
        let radius = key.diameter / 2
        let extent = radius + 4 * key.sigma
        let last = fogProfileStopCount - 1
        var stops = (0..<fogProfileStopCount).map { i in
            fogDiscIntensity(rho: extent * Double(i) / Double(last), radius: radius, sigma: key.sigma)
        }
        stops[last] = 0
        let profile = FogProfile(sigma: key.sigma, extent: extent, stops: stops)
        fogProfileCache.withLock { $0[key] = profile }
        return profile
    }

    /// Center of haze blob index: x relative to the panel left edge, y relative to the haze frame top (see fogFrame, bottom-anchored):
    /// blob 1 (150+20d, 260), blob 2 (290-20d, 310), blob 3 (220, 340);
    /// drift is 20d (pt, see fogDrift); x scales by panel width / 390, y does not scale.
    static func fogCenter(index: Int, panelWidth: Double, drift: Double) -> CGPoint {
        let k = panelWidth / fogBaseWidth
        switch index {
        case 0: return CGPoint(x: (150 + drift) * k, y: 260)
        case 1: return CGPoint(x: (290 - drift) * k, y: 310)
        default: return CGPoint(x: 220 * k, y: 340)
        }
    }

    /// Blobs of the haze for a given mode, energy, light/dark, and hint.
    static func fogCircles(
        mode: VoiceOrbMode, energy: Double, dark: Bool, notice: Bool, aiPalette: Bool? = nil
    ) -> [FogCircle] {
        let colors = fogPalette(ai: aiPalette ?? usesAIPalette(mode))
        if notice {
            return [
                FogCircle(color: colors[0], alpha: 0.40, blur: 70, diameter: 300, driftSign: 1),
                FogCircle(color: amber, alpha: 0.20, blur: 80, diameter: 280, driftSign: -1)
            ]
        }
        return [
            FogCircle(color: colors[0], alpha: fogAlpha(index: 0, mode: mode, energy: energy, dark: dark), blur: 70, diameter: 300, driftSign: 1),
            FogCircle(color: colors[1], alpha: fogAlpha(index: 1, mode: mode, energy: energy, dark: dark), blur: 70, diameter: 280, driftSign: -1),
            FogCircle(color: colors[2], alpha: fogAlpha(index: 2, mode: mode, energy: energy, dark: dark), blur: 60, diameter: 220, driftSign: 0)
        ]
    }

    /// Haze alpha: resting bright .32 / dark .55; user speaking .30 + .35E, AI speaking .45 + .30E (only blobs 1 and 2 change);
    /// blob 3 fixed at bright .18 / dark .35, independent of mode and level.
    static func fogAlpha(index: Int, mode: VoiceOrbMode, energy: Double, dark: Bool) -> Double {
        if index == 2 { return dark ? 0.35 : 0.18 }
        let e = clamp01(energy)
        switch mode {
        case .user: return clamp01(0.30 + 0.35 * e)
        case .ai: return clamp01(0.45 + 0.30 * e)
        case .listen, .think, .muted: return dark ? 0.55 : 0.32
        }
    }

    static func orbPalette(_ mode: VoiceOrbMode) -> [UInt32] { orbPalette(ai: usesAIPalette(mode)) }

    static func orbPalette(ai: Bool) -> [UInt32] {
        ai
            ? [0x5EEAD4, 0x38BDF8, 0x4F7BFF, 0xA5F3FC]
            : [0x38D6E8, 0xE04FC0, 0x4F7BFF, 0xB79CFF]
    }

    /// Base radial gradient stops: center, .55, edge.
    static func basePalette(_ mode: VoiceOrbMode) -> [UInt32] { basePalette(ai: usesAIPalette(mode)) }

    static func basePalette(ai: Bool) -> [UInt32] {
        ai ? [0xBAE6FD, 0x5B8CFF, 0x3249C9] : [0xD9CCFF, 0x8B6CFF, 0x4A2FC9]
    }

    static func reflectionColor(_ mode: VoiceOrbMode) -> UInt32 { reflectionColor(ai: usesAIPalette(mode)) }

    static func reflectionColor(ai: Bool) -> UInt32 {
        ai ? 0xA5F3FC : 0x7DD3FC
    }

    static func fogPalette(_ mode: VoiceOrbMode) -> [UInt32] { fogPalette(ai: usesAIPalette(mode)) }

    static func fogPalette(ai: Bool) -> [UInt32] {
        // dark-palette-guard: keep (c) fixed aurora palette from the spec, same in light and dark
        ai ? [0x22D3EE, 0x4F7BFF, 0x7C5CFF] : [0x8B5CF6, 0x4F7BFF, 0xE04FC0]
    }

    /// One interpolated haze blob.
    struct BlendedFogCircle: Equatable {
        let color: RGB
        let alpha: Double
        let blur: Double
        let diameter: Double
        let driftSign: Double
    }

    /// Blend old and new haze groups by t; a blob missing on one side is filled with the same color at alpha 0 (e.g. the hint state has only two blobs).
    static func blendFog(from old: [FogCircle], to new: [FogCircle], _ t: Double) -> [BlendedFogCircle] {
        let k = clamp01(t)
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * k }
        return (0..<max(old.count, new.count)).map { index in
            let a = index < old.count ? old[index] : nil
            let b = index < new.count ? new[index] : nil
            let from = a ?? FogCircle(color: b!.color, alpha: 0, blur: b!.blur, diameter: b!.diameter, driftSign: b!.driftSign)
            let to = b ?? FogCircle(color: from.color, alpha: 0, blur: from.blur, diameter: from.diameter, driftSign: from.driftSign)
            return BlendedFogCircle(
                color: mix(from.color, to.color, k),
                alpha: lerp(from.alpha, to.alpha),
                blur: lerp(from.blur, to.blur),
                diameter: lerp(from.diameter, to.diameter),
                driftSign: k < 0.5 ? from.driftSign : to.driftSign
            )
        }
    }
}

/// Parameters for drawing one orb frame.
struct VoiceOrbFrame: Equatable {
    let phase: Double
    let energy: Double
    let scale: Double
    let nudgeOffset: Double
    let nudgeAlpha: Double
}

/// Orb state stepped by frame time: envelope, phase, jitter. Advanced only inside the draw closure.
struct VoiceOrbAnimator {
    /// When the timeline resumes after a pause, a single frame steps at most 0.1 s, to avoid jumps in phase and envelope.
    static let maxStep: Double = 0.1

    /// First-level envelope a (attack 40 / release 200 ms).
    private(set) var envelope: Double = 0
    /// Second-level smoothing b (symmetric 24 ms); energy uses this one.
    private(set) var smoothed: Double = 0
    private(set) var phase: Double = 0
    private var lastTime: Double?
    private var lastNudges: Int?
    private var nudgeStart: Double?

    /// Energy and scale as displayed; used as the easing start point on mode change.
    private struct Shown {
        let energy: Double
        let scale: Double
    }

    private var lastMode: VoiceOrbMode?
    private var shown: Shown?
    private var easeFrom: Shown?
    private var easeElapsed: Double = 0

    mutating func advance(time: Double, mode: VoiceOrbMode, level: Double, nudges: Int, reduceMotion: Bool) -> VoiceOrbFrame {
        let dt = lastTime.map { min(Self.maxStep, max(0, time - $0)) } ?? 0
        lastTime = time
        if let lastNudges, lastNudges != nudges { nudgeStart = time }
        lastNudges = nudges

        envelope = VoiceOrbMath.envelope(current: envelope, target: level, dt: dt)
        smoothed = VoiceOrbMath.smooth(current: smoothed, target: envelope, dt: dt)
        let breathe = VoiceOrbMath.breathe(time: time)
        var energy = VoiceOrbMath.energy(mode: mode, envelope: smoothed, breathe: breathe, reduceMotion: reduceMotion)
        var scale = VoiceOrbMath.scale(mode: mode, energy: energy, breathe: breathe, reduceMotion: reduceMotion)

        // On mode change: ease from the current displayed value to the new mode's per-frame target over 200 ms easeInOut; Reduce Motion and the muted group switch directly.
        if let lastMode, lastMode != mode {
            let direct = reduceMotion || VoiceOrbMath.isDimmed(lastMode) || VoiceOrbMath.isDimmed(mode)
            easeFrom = direct ? nil : shown
            // On a mode change, the current frame advances one step: frame 12 at 60 Hz (200 ms) reaches the target, same as Android.
            easeElapsed = dt
        } else if easeFrom != nil {
            easeElapsed += dt
        }
        lastMode = mode
        if reduceMotion { easeFrom = nil }
        if let from = easeFrom {
            let mix = VoiceOrbMath.paletteMix(elapsed: easeElapsed, reduceMotion: false)
            if mix >= 1 {
                easeFrom = nil
            } else {
                energy = from.energy + (energy - from.energy) * mix
                scale = from.scale + (scale - from.scale) * mix
            }
        }
        shown = Shown(energy: energy, scale: scale)

        phase += dt * VoiceOrbMath.phaseSpeed(mode: mode, energy: energy, reduceMotion: reduceMotion)
        let elapsed = nudgeStart.map { time - $0 } ?? -1
        return VoiceOrbFrame(
            phase: phase,
            energy: energy,
            scale: scale,
            nudgeOffset: VoiceOrbMath.nudgeOffset(elapsed: elapsed, reduceMotion: reduceMotion),
            nudgeAlpha: VoiceOrbMath.nudgeAlpha(elapsed: elapsed, reduceMotion: reduceMotion)
        )
    }

    /// One frame under the stage-clock override (sample frames): time frozen at time, envelope equals level directly, phase = time x phase speed;
    /// rendered with normal motion (not Reduce Motion), no jitter.
    static func stageFrame(time: Double, mode: VoiceOrbMode, level: Double) -> VoiceOrbFrame {
        let breathe = VoiceOrbMath.breathe(time: time)
        let energy = VoiceOrbMath.stageEnergy(mode: mode, level: level, time: time)
        return VoiceOrbFrame(
            phase: time * VoiceOrbMath.phaseSpeed(mode: mode, energy: energy),
            energy: energy,
            scale: VoiceOrbMath.scale(mode: mode, energy: energy, breathe: breathe),
            nudgeOffset: 0,
            nudgeAlpha: 1
        )
    }
}

/// Palette switch blend progress: when the key (which palette) changes, transition from the previous palette over 200 ms to the new one; Reduce Motion switches directly.
/// Wall-clock time is passed in (when the timeline is paused, frame time stops at the pause moment and cannot time the transition).
struct VoicePaletteBlend<Key: Equatable> {
    private(set) var from: Key?
    private(set) var to: Key?
    private var start: Double = 0

    /// Returns the old key and the blend factor (1 = fully the new key).
    mutating func advance(key: Key, time: Double, reduceMotion: Bool) -> (from: Key, mix: Double) {
        guard let current = to else {
            from = key
            to = key
            return (key, 1)
        }
        if key != current {
            from = current
            to = key
            start = time
        }
        guard let old = from, old != key else { return (key, 1) }
        let mix = VoiceOrbMath.paletteMix(elapsed: time - start, reduceMotion: reduceMotion)
        if mix >= 1 {
            from = key
            return (key, 1)
        }
        return (old, mix)
    }
}

/// Haze palette key: whether the AI palette is used, and whether the amber hint is shown.
struct VoiceFogPaletteKey: Equatable {
    let ai: Bool
    let notice: Bool
}

/// Mutable frame state used inside the draw closure; reference type, so changes do not trigger view recomputation.
private final class VoiceOrbClock {
    var orb = VoiceOrbAnimator()
    var orbPalette = VoicePaletteBlend<Bool>()
    var fogPalette = VoicePaletteBlend<VoiceFogPaletteKey>()
    var fogEnvelope: Double = 0
    var fogSmoothed: Double = 0
    var fogLastTime: Double?
}

private extension Color {
    init(orbHex hex: UInt32, opacity: Double = 1) {
        self.init(orbRGB: VoiceOrbMath.RGB(hex: hex), opacity: opacity)
    }

    init(orbRGB rgb: VoiceOrbMath.RGB, opacity: Double = 1) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: opacity)
    }
}

/// Stage-clock override (seconds): when non-nil, orb and haze freeze at this instant (timeline paused, frame time and palette time both use it). Sample frames only; always nil in production.
private struct VoiceStageClockKey: EnvironmentKey {
    static let defaultValue: TimeInterval? = nil
}

extension EnvironmentValues {
    var voiceStageClock: TimeInterval? {
        get { self[VoiceStageClockKey.self] }
        set { self[VoiceStageClockKey.self] = newValue }
    }
}

/// During a palette switch, let the timeline run the full transition duration (when muted with no level the timeline is otherwise paused).
private let paletteRunTime: Duration = .milliseconds(Int(VoiceOrbMath.paletteTransition * 1000) + 60)

// MARK: - Orb

/// Layered drawing of the orb, shared by the view and pixel tests.
enum VoiceOrbPaint {
    /// Outer glow, corresponding to canvas `<g filter=glow opacity=bloom>`: the group's three opaque circles are composited first, the group is blurred, and finally the whole group is multiplied by bloom.
    /// GraphicsContext opacity and filter apply to every draw operation after them; set inside the layer they would multiply alpha and blur per circle (overlaps get denser),
    /// so they are set on an outer copy and apply only to the composited layer.
    static func drawGlow(in ctx: GraphicsContext, circles: [(Path, Color)], sigma: CGFloat, bloom: Double) {
        var group = ctx
        group.opacity *= bloom
        group.addFilter(.blur(radius: VoiceOrbMath.blurRadius(sigma: Double(sigma))))
        group.drawLayer { glow in
            for (path, color) in circles { glow.fill(path, with: .color(color)) }
        }
    }

    /// One haze blob: no longer blurred per frame at large radius; instead draws a radial gradient from the precomputed disc-convolved-Gaussian profile, stop color = blob color x alpha x P.
    /// Each blob was originally blurred individually and source-over blended, so replacing blob by blob is equivalent to the original look.
    static func drawFogCircle(
        in ctx: GraphicsContext, center: CGPoint, color: VoiceOrbMath.RGB, alpha: Double, diameter: Double, sigma: Double
    ) {
        guard alpha > 0, diameter > 0 else { return }
        let profile = VoiceOrbMath.fogProfile(diameter: diameter, sigma: sigma)
        let last = Double(profile.stops.count - 1)
        let gradient = Gradient(stops: profile.stops.enumerated().map { i, p in
            Gradient.Stop(color: Color(orbRGB: color, opacity: alpha * p), location: Double(i) / last)
        })
        let r = profile.extent
        ctx.fill(
            Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
            with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: r)
        )
    }
}

struct VoiceAuroraOrb: View {
    let mode: VoiceOrbMode
    let level: Double
    var nudges: Int = 0
    var notice: Bool = false
    var size: CGFloat = 148

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.voiceStageClock) private var stageClock
    @State private var clock = VoiceOrbClock()
    @State private var nudgeRunning = false
    @State private var paletteRunning = false

    /// The canvas is larger than the orb box; glow and blur stay outside the box uncropped (units: viewBox 200):
    /// outer glow edge ~ offset 18 + radius 74 + 3 sigma 66 = 158, times max scale 1.16 ~ 183.
    static let canvasUnits: Double = 380

    private var paused: Bool {
        if stageClock != nil { return true }
        guard !nudgeRunning else { return false }
        if reduceMotion { return true }
        return !paletteRunning && mode == .muted && level <= 0
    }

    /// Under the stage-clock override, render with normal motion.
    private var motionReduced: Bool { stageClock == nil && reduceMotion }

    private var usesAIPalette: Bool { VoiceOrbMath.usesAIPalette(mode) }

    var body: some View {
        let unit = VoiceOrbMath.unit(size: Double(size))
        let canvasSide = CGFloat(Self.canvasUnits * unit)
        TimelineView(.animation(minimumInterval: VoiceOrbMath.orbFrameInterval, paused: paused)) { context in
            Canvas { ctx, canvasSize in
                let frame: VoiceOrbFrame
                if let stageClock {
                    frame = VoiceOrbAnimator.stageFrame(time: stageClock, mode: mode, level: level)
                } else {
                    frame = clock.orb.advance(
                        time: context.date.timeIntervalSinceReferenceDate, mode: mode, level: level, nudges: nudges,
                        reduceMotion: reduceMotion
                    )
                }
                let palette = clock.orbPalette.advance(
                    key: usesAIPalette, time: stageClock ?? Date().timeIntervalSinceReferenceDate,
                    reduceMotion: motionReduced
                )
                VoiceOrbPaint.drawOrb(
                    in: &ctx, canvasSize: canvasSize, unit: unit, frame: frame, palette: palette,
                    mode: mode, dark: colorScheme == .dark
                )
            }
            .frame(width: canvasSide, height: canvasSide)
        }
        .frame(width: size, height: size)
        .opacity(VoiceOrbMath.orbAlpha(mode: mode, level: level, reduceMotion: motionReduced))
        .saturation(VoiceOrbMath.saturation(mode: mode))
        .animation(.easeInOut(duration: 0.2), value: mode)
        .onChange(of: nudges) { nudgeRunning = true }
        .task(id: nudges) {
            try? await Task.sleep(for: .milliseconds(Int(VoiceOrbMath.nudgeDuration * 1000) + 60))
            nudgeRunning = false
        }
        .onChange(of: usesAIPalette) { paletteRunning = true }
        .task(id: usesAIPalette) {
            try? await Task.sleep(for: paletteRunTime)
            paletteRunning = false
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

}

extension VoiceOrbPaint {
    /// One orb frame: glow, base, color blobs, reflection, highlight, stroke; orb center at canvas center. Shared by the view and performance tests.
    static func drawOrb(
        in ctx: inout GraphicsContext, canvasSize: CGSize, unit: Double, frame: VoiceOrbFrame,
        palette: (from: Bool, mix: Double), mode: VoiceOrbMode, dark: Bool
    ) {
        let scale = frame.scale
        let originX = Double(canvasSize.width) / 2 + frame.nudgeOffset
        let originY = Double(canvasSize.height) / 2
        // Canvas coordinates 200 to canvas points; scaling centered on orb center (100,100).
        func pt(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: originX + (x - 100) * unit * scale, y: originY + (y - 100) * unit * scale)
        }
        func len(_ l: Double) -> CGFloat { CGFloat(l * unit * scale) }
        func circle(_ cx: Double, _ cy: Double, _ r: Double) -> Path {
            let c = pt(cx, cy)
            return Path(ellipseIn: CGRect(x: c.x - len(r), y: c.y - len(r), width: len(2 * r), height: len(2 * r)))
        }
        // Ellipses by semi-axes (viewBox units).
        func ellipse(_ e: VoiceOrbMath.OrbEllipse) -> Path {
            let c = pt(e.cx, e.cy)
            return Path(ellipseIn: CGRect(x: c.x - len(e.rx), y: c.y - len(e.ry), width: len(2 * e.rx), height: len(2 * e.ry)))
        }

        ctx.opacity = frame.nudgeAlpha
        let p = frame.phase
        let e = frame.energy
        let ai = VoiceOrbMath.usesAIPalette(mode)
        // Blend old and new palettes by the blend factor.
        func blended(_ table: (Bool) -> [UInt32]) -> [VoiceOrbMath.RGB] {
            zip(table(palette.from), table(ai)).map { VoiceOrbMath.mix($0, $1, palette.mix) }
        }
        let colors = blended(VoiceOrbMath.orbPalette(ai:))

        // Outer glow: three circles, first three colors, blur 22.
        VoiceOrbPaint.drawGlow(
            in: ctx,
            circles: VoiceOrbMath.glowCircles(phase: p, energy: e).enumerated().map { i, c in
                (circle(c.cx, c.cy, c.r), Color(orbRGB: colors[i]))
            },
            sigma: len(22),
            bloom: VoiceOrbMath.glowAlpha(mode: mode, energy: e, dark: dark)
        )

        let r78 = VoiceOrbMath.orbRadiusUnits
        let body = circle(100, 100, r78)
        ctx.drawLayer { orb in
            orb.clip(to: body)
            // Base radial: center (36%, 30%), radius 78%.
            let base = blended(VoiceOrbMath.basePalette(ai:))
            let box = 2 * r78
            orb.fill(body, with: .radialGradient(
                Gradient(stops: [
                    .init(color: Color(orbRGB: base[0]), location: 0),
                    .init(color: Color(orbRGB: base[1]), location: 0.55),
                    .init(color: Color(orbRGB: base[2]), location: 1)
                ]),
                center: pt(100 - r78 + 0.36 * box, 100 - r78 + 0.30 * box),
                startRadius: 0,
                endRadius: len(0.78 * box)
            ))
            // Four color blobs, blur 14: on canvas each circle in `<g filter=blur>` is composited at .85 before the group is blurred; the filter is set on the outer copy.
            var blobGroup = orb
            blobGroup.addFilter(.blur(radius: VoiceOrbMath.blurRadius(sigma: Double(len(14)))))
            blobGroup.drawLayer { blobs in
                for i in 0..<4 {
                    let fi = Double(i)
                    let a = p * (0.9 + 0.25 * fi) + fi * .pi / 2
                    let cx = 100 + 30 * cos(a) * (1 + 0.25 * e)
                    let cy = 100 + 25.5 * sin(1.3 * a) * (1 + 0.25 * e)
                    let r = 40 + 12 * e + 3 * sin(2 * p + fi)
                    blobs.fill(circle(cx, cy, r), with: .color(Color(orbRGB: colors[i], opacity: 0.85)))
                }
            }
            // Bottom reflection, blur 14.
            orb.drawLayer { reflection in
                reflection.addFilter(.blur(radius: VoiceOrbMath.blurRadius(sigma: Double(len(14)))))
                reflection.fill(
                    ellipse(VoiceOrbMath.reflectionEllipse),
                    with: .color(Color(
                        orbRGB: VoiceOrbMath.mix(
                            VoiceOrbMath.reflectionColor(ai: palette.from), VoiceOrbMath.reflectionColor(ai: ai), palette.mix
                        ),
                        opacity: 0.45
                    ))
                )
            }
            // Top-left highlight: white radial .42 to 0; gradient follows the ellipse (circular gradient squeezed along y); reaches 0 at the edge, no hard edge.
            let spec = VoiceOrbMath.highlightEllipse
            orb.drawLayer { highlight in
                // Clip to the same ellipse: the gradient is already 0 at the ellipse edge; the clip only guards against float overflow and creates no visible edge.
                highlight.clip(to: ellipse(VoiceOrbMath.highlightEllipse))
                let c = pt(spec.cx, spec.cy)
                let squash = spec.ry / spec.rx
                highlight.translateBy(x: c.x, y: c.y)
                highlight.scaleBy(x: 1, y: CGFloat(squash))
                highlight.translateBy(x: -c.x, y: -c.y)
                highlight.fill(circle(spec.cx, spec.cy, spec.rx), with: .radialGradient(
                    Gradient(colors: [Color.white.opacity(0.42), Color.white.opacity(0)]),
                    center: c,
                    startRadius: 0,
                    endRadius: len(spec.rx)
                ))
            }
        }

        // Stroke: white .55 to .05 to .18 diagonal gradient.
        ctx.stroke(body, with: .linearGradient(
            Gradient(stops: [
                .init(color: Color.white.opacity(0.55), location: 0),
                .init(color: Color.white.opacity(0.05), location: 0.5),
                .init(color: Color.white.opacity(0.18), location: 1)
            ]),
            startPoint: pt(100 - r78, 100 - r78),
            endPoint: pt(100 + r78, 100 + r78)
        ), lineWidth: len(1.2))
    }
}

// MARK: - Aurora haze

/// Aurora haze at the bottom of the panel; width given by the caller (panel + 80, 40 bleed on each side), top edge aligned with the panel content top.
struct VoiceAuroraFog: View {
    let mode: VoiceOrbMode
    let level: Double
    var notice: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.voiceStageClock) private var stageClock
    @State private var clock = VoiceOrbClock()
    @State private var paletteRunning = false

    private var paused: Bool {
        if stageClock != nil { return true }
        if reduceMotion { return true }
        return !paletteRunning && mode == .muted && level <= 0
    }

    private var paletteKey: VoiceFogPaletteKey {
        VoiceFogPaletteKey(ai: VoiceOrbMath.usesAIPalette(mode), notice: notice)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: VoiceOrbMath.fogFrameInterval, paused: paused)) { context in
            Canvas { ctx, size in
                // Stage-clock override (samples): time frozen at the override value, envelope equals level, rendered with normal motion.
                let motionReduced = stageClock == nil && reduceMotion
                let time = stageClock ?? context.date.timeIntervalSinceReferenceDate
                let energy: Double
                if let stageClock {
                    energy = VoiceOrbMath.stageEnergy(mode: mode, level: level, time: stageClock)
                } else {
                    let dt = clock.fogLastTime.map { min(VoiceOrbAnimator.maxStep, max(0, time - $0)) } ?? 0
                    clock.fogLastTime = time
                    clock.fogEnvelope = VoiceOrbMath.envelope(current: clock.fogEnvelope, target: level, dt: dt)
                    clock.fogSmoothed = VoiceOrbMath.smooth(current: clock.fogSmoothed, target: clock.fogEnvelope, dt: dt)
                    // Under Reduce Motion the timeline is paused and E is always 0; haze alpha does not follow the level.
                    energy = VoiceOrbMath.energy(
                        mode: mode, envelope: clock.fogSmoothed, breathe: VoiceOrbMath.breathe(time: time),
                        reduceMotion: reduceMotion
                    )
                }
                let drift = VoiceOrbMath.fogDrift(time: time, reduceMotion: motionReduced)
                let dark = colorScheme == .dark
                let key = paletteKey
                let palette = clock.fogPalette.advance(
                    key: key, time: stageClock ?? Date().timeIntervalSinceReferenceDate, reduceMotion: motionReduced
                )
                // Palette and amber hint: blend old and new haze groups by the blend factor.
                let circles = VoiceOrbMath.blendFog(
                    from: VoiceOrbMath.fogCircles(
                        mode: mode, energy: energy, dark: dark, notice: palette.from.notice, aiPalette: palette.from.ai
                    ),
                    to: VoiceOrbMath.fogCircles(mode: mode, energy: energy, dark: dark, notice: key.notice, aiPalette: key.ai),
                    palette.mix
                )
                let panelWidth = max(0, Double(size.width) - 2 * VoiceOrbMath.fogBleed)
                for (index, circle) in circles.enumerated() {
                    let center = VoiceOrbMath.fogCenter(index: index, panelWidth: panelWidth, drift: drift)
                    let cx = Double(center.x) + VoiceOrbMath.fogBleed
                    let cy = Double(center.y)
                    VoiceOrbPaint.drawFogCircle(
                        in: ctx, center: CGPoint(x: cx, y: cy), color: circle.color, alpha: circle.alpha,
                        diameter: circle.diameter, sigma: circle.blur
                    )
                }
            }
        }
        .onChange(of: paletteKey) { paletteRunning = true }
        .task(id: paletteKey) {
            try? await Task.sleep(for: paletteRunTime)
            paletteRunning = false
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
