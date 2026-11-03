import Accelerate
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Oriveo

// Pure functions and frame stepping for the liquid aurora orb and aurora fog.

@MainActor
@Suite("Voice aurora orb")
struct VoiceAuroraOrbTests {
    private func close(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

    @Test("scale per mode")
    func scalePerMode() {
        #expect(close(VoiceOrbMath.scale(mode: .user, energy: 1, breathe: 0.5), 1.16))
        #expect(close(VoiceOrbMath.scale(mode: .ai, energy: 0.5, breathe: 0.5), 1.04))
        #expect(close(VoiceOrbMath.scale(mode: .listen, energy: 0, breathe: 1), 1.025))
        #expect(close(VoiceOrbMath.scale(mode: .think, energy: 0.45, breathe: 1), 0.95))
        #expect(close(VoiceOrbMath.scale(mode: .muted, energy: 0.05, breathe: 1), 1))
    }

    @Test("energy per mode")
    func energyPerMode() {
        #expect(close(VoiceOrbMath.energy(mode: .user, envelope: 0.8, breathe: 0.5), 0.8))
        #expect(close(VoiceOrbMath.energy(mode: .ai, envelope: 0.8, breathe: 0.5), 0.72))
        #expect(close(VoiceOrbMath.energy(mode: .think, envelope: 0.8, breathe: 0.5), 0.45))
        #expect(close(VoiceOrbMath.energy(mode: .listen, envelope: 0.8, breathe: 1), 0.15))
        #expect(close(VoiceOrbMath.energy(mode: .muted, envelope: 0.8, breathe: 1), 0.05))
        #expect(close(VoiceOrbMath.breathe(time: 0), 0.5))
        #expect(close(VoiceOrbMath.breathe(time: 1.1 * .pi / 2), 1))
    }

    @Test("phase speed per mode")
    func phaseSpeedPerMode() {
        #expect(close(VoiceOrbMath.phaseSpeed(mode: .listen, energy: 0.1), 0.22))
        #expect(close(VoiceOrbMath.phaseSpeed(mode: .user, energy: 1), 1.35))
        #expect(close(VoiceOrbMath.phaseSpeed(mode: .think, energy: 0.45), 1.25))
        #expect(close(VoiceOrbMath.phaseSpeed(mode: .ai, energy: 0.5), 0.7))
        #expect(close(VoiceOrbMath.phaseSpeed(mode: .muted, energy: 0.05), 0.05))
    }

    @Test("muted group: desaturated, alpha .55, glow .1")
    func mutedGroupDims() {
        #expect(close(VoiceOrbMath.saturation(mode: .muted), 0.15))
        #expect(close(VoiceOrbMath.orbAlpha(mode: .muted, level: 0, reduceMotion: false), 0.55))
        #expect(close(VoiceOrbMath.glowAlpha(mode: .muted, energy: 0.05, dark: true), 0.1))
        #expect(close(VoiceOrbMath.saturation(mode: .user), 1))
        #expect(close(VoiceOrbMath.orbAlpha(mode: .user, level: 0.7, reduceMotion: false), 1))
        #expect(close(VoiceOrbMath.glowAlpha(mode: .listen, energy: 0, dark: false), 0.38))
        #expect(close(VoiceOrbMath.glowAlpha(mode: .ai, energy: 0, dark: true), 0.55))
    }

    @Test("fog alpha follows level")
    func fogAlphaFollowsLevel() {
        #expect(close(VoiceOrbMath.fogAlpha(index: 0, mode: .user, energy: 0, dark: false), 0.30))
        #expect(close(VoiceOrbMath.fogAlpha(index: 0, mode: .user, energy: 1, dark: false), 0.65))
        #expect(close(VoiceOrbMath.fogAlpha(index: 1, mode: .ai, energy: 1, dark: true), 0.75))
        #expect(close(VoiceOrbMath.fogAlpha(index: 0, mode: .listen, energy: 1, dark: false), 0.32))
        #expect(close(VoiceOrbMath.fogAlpha(index: 2, mode: .listen, energy: 0, dark: true), 0.35))
        let quiet = VoiceOrbMath.fogCircles(mode: .user, energy: 0.1, dark: false, notice: false)
        let loud = VoiceOrbMath.fogCircles(mode: .user, energy: 0.9, dark: false, notice: false)
        #expect(quiet.count == 3)
        for index in 0..<2 { #expect(loud[index].alpha > quiet[index].alpha) }
        // Blob 3 ignores level: light .18 / dark .35.
        #expect(loud[2].alpha == quiet[2].alpha)
        for mode in [VoiceOrbMode.user, .ai] {
            for energy in [0.0, 0.5, 1.0] {
                #expect(close(VoiceOrbMath.fogAlpha(index: 2, mode: mode, energy: energy, dark: false), 0.18))
                #expect(close(VoiceOrbMath.fogAlpha(index: 2, mode: mode, energy: energy, dark: true), 0.35))
            }
        }
    }

    @Test("orb follows viewBox 200: visible radius size×78/200, highlight and reflection use half-axes")
    func orbGeometryFollowsViewBox() {
        let size = 148.0
        let k = size / 200
        #expect(close(VoiceOrbMath.unit(size: size), k))
        #expect(close(VoiceOrbMath.visibleOrbRadius(size: size), size * 78 / 200))
        let highlight = VoiceOrbMath.rect(VoiceOrbMath.highlightEllipse, size: size)
        #expect(close(Double(highlight.midX), 82 * k))
        #expect(close(Double(highlight.midY), 58 * k))
        #expect(close(Double(highlight.width) / 2, 52 * k))
        #expect(close(Double(highlight.height) / 2, 32 * k))
        let reflection = VoiceOrbMath.rect(VoiceOrbMath.reflectionEllipse, size: size)
        #expect(close(Double(reflection.midX), 100 * k))
        #expect(close(Double(reflection.midY), 152 * k))
        #expect(close(Double(reflection.width) / 2, 56 * k))
        #expect(close(Double(reflection.height) / 2, 26 * k))
        let source = try? String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "OriveoTests/Features/Chat/VoiceAuroraOrbTests.swift",
                with: "Oriveo/Features/Chat/Voice/VoiceAuroraOrb.swift"
            ),
            encoding: .utf8
        )
        #expect(source?.contains("let unit = VoiceOrbMath.unit(size: Double(size))") == true)
        #expect(source?.contains("ellipse(VoiceOrbMath.highlightEllipse)") == true)
        #expect(source?.contains("ellipse(VoiceOrbMath.reflectionEllipse)") == true)
    }

    @Test("notice keeps only blob 1 in the fog, blob 2 turns amber")
    func noticeFogTurnsAmber() {
        let circles = VoiceOrbMath.fogCircles(mode: .listen, energy: 0, dark: true, notice: true)
        #expect(circles.count == 2)
        #expect(circles[0].color == 0x8B5CF6)
        #expect(close(circles[0].alpha, 0.40))
        #expect(circles[1].color == 0xF59E0B)
        #expect(close(circles[1].alpha, 0.20))
        #expect(close(circles[1].blur, 80))
        // blur is the canvas σ 80; the fog gradient is a disc convolved with a Gaussian profile at σ 80, radius R+4σ = 140+320.
        let profile = VoiceOrbMath.fogProfile(diameter: circles[1].diameter, sigma: circles[1].blur)
        #expect(close(profile.sigma, 80))
        #expect(close(profile.extent, 140 + 4 * 80))
        #expect(profile.stops.count == 41)
    }

    @Test("reduce motion only changes alpha: no phase, no scale, no drift")
    func reduceMotionOnlyAlpha() {
        var animator = VoiceOrbAnimator()
        var last: VoiceOrbFrame?
        for step in 0..<20 {
            last = animator.advance(time: Double(step) * 0.05, mode: .user, level: 1, nudges: 0, reduceMotion: true)
        }
        #expect(last?.phase == 0)
        #expect(last?.scale == 1)
        #expect(last?.nudgeOffset == 0)
        #expect(close(VoiceOrbMath.orbAlpha(mode: .user, level: 0, reduceMotion: true), 0.6))
        #expect(close(VoiceOrbMath.orbAlpha(mode: .user, level: 1, reduceMotion: true), 1.0))
        #expect(VoiceOrbMath.phaseSpeed(mode: .think, energy: 0.45, reduceMotion: true) == 0)
        #expect(VoiceOrbMath.fogDrift(time: 3, reduceMotion: true) == 0)
        #expect(VoiceOrbMath.fogDrift(time: 2.6 * .pi / 2, reduceMotion: false) == 20)

        var moving = VoiceOrbAnimator()
        _ = moving.advance(time: 0, mode: .user, level: 1, nudges: 0, reduceMotion: false)
        let frame = moving.advance(time: 0.05, mode: .user, level: 1, nudges: 0, reduceMotion: false)
        #expect(frame.phase > 0)
        #expect(frame.scale > 1)
    }

    @Test("reduce motion: energy is 0 in every mode, fog alpha ignores level")
    func reduceMotionEnergyZero() {
        let modes: [VoiceOrbMode] = [.user, .ai, .listen, .think, .muted]
        for mode in modes {
            for envelope in [0.0, 0.5, 1.0] {
                #expect(VoiceOrbMath.energy(mode: mode, envelope: envelope, breathe: 1, reduceMotion: true) == 0)
            }
            let quiet = VoiceOrbMath.energy(mode: mode, envelope: 0.05, breathe: 0, reduceMotion: true)
            let loud = VoiceOrbMath.energy(mode: mode, envelope: 0.95, breathe: 1, reduceMotion: true)
            for index in 0..<3 {
                #expect(
                    VoiceOrbMath.fogAlpha(index: index, mode: mode, energy: quiet, dark: false)
                        == VoiceOrbMath.fogAlpha(index: index, mode: mode, energy: loud, dark: false)
                )
            }
        }
        var animator = VoiceOrbAnimator()
        _ = animator.advance(time: 0, mode: .think, level: 1, nudges: 0, reduceMotion: true)
        #expect(animator.advance(time: 0.05, mode: .think, level: 1, nudges: 0, reduceMotion: true).energy == 0)
    }

    @Test("a change in nudges triggers one shake offset sequence")
    func nudgeShakeSequence() {
        var animator = VoiceOrbAnimator()
        // The first frame count is not a change.
        #expect(animator.advance(time: 0, mode: .listen, level: 0, nudges: 3, reduceMotion: false).nudgeOffset == 0)
        #expect(animator.advance(time: 0.5, mode: .listen, level: 0, nudges: 3, reduceMotion: false).nudgeOffset == 0)
        _ = animator.advance(time: 1.0, mode: .listen, level: 0, nudges: 4, reduceMotion: false)
        var offsets: [Double] = []
        for k in 0..<30 {
            let t = 1.005 + 0.01 * Double(k)
            offsets.append(animator.advance(time: t, mode: .listen, level: 0, nudges: 4, reduceMotion: false).nudgeOffset)
        }
        let peak = offsets.map(abs).max() ?? 0
        #expect(peak > 3.5 && peak <= 4.0 + 1e-9)
        // Three back-and-forth swings: sign alternates 5 times, back to zero after 240 ms.
        let signChanges = zip(offsets, offsets.dropFirst()).filter { $0 * $1 < 0 }.count
        #expect(signChanges == 5)
        #expect(offsets.suffix(5).allSatisfy { $0 == 0 })

        // Reduce motion: no shake, alpha flashes once.
        var calm = VoiceOrbAnimator()
        _ = calm.advance(time: 0, mode: .listen, level: 0, nudges: 0, reduceMotion: true)
        _ = calm.advance(time: 0.01, mode: .listen, level: 0, nudges: 1, reduceMotion: true)
        let mid = calm.advance(time: 0.13, mode: .listen, level: 0, nudges: 1, reduceMotion: true)
        #expect(mid.nudgeOffset == 0)
        #expect(mid.nudgeAlpha < 0.7)
        #expect(calm.advance(time: 0.5, mode: .listen, level: 0, nudges: 1, reduceMotion: true).nudgeAlpha == 1)
    }

    @Test("AI palette only when AI speaks; while thinking, reuse the user palette")
    func aiPaletteOnlyWhenAISpeaks() {
        #expect(VoiceOrbMath.orbPalette(.ai) == [0x5EEAD4, 0x38BDF8, 0x4F7BFF, 0xA5F3FC])
        #expect(VoiceOrbMath.fogPalette(.ai) == [0x22D3EE, 0x4F7BFF, 0x7C5CFF])
        for mode in [VoiceOrbMode.think, .listen, .user, .muted] {
            #expect(VoiceOrbMath.orbPalette(mode) == [0x38D6E8, 0xE04FC0, 0x4F7BFF, 0xB79CFF])
            #expect(VoiceOrbMath.basePalette(mode) == [0xD9CCFF, 0x8B6CFF, 0x4A2FC9])
            #expect(VoiceOrbMath.reflectionColor(mode) == 0x7DD3FC)
            #expect(VoiceOrbMath.fogPalette(mode) == [0x8B5CF6, 0x4F7BFF, 0xE04FC0])
        }
    }

    @Test("fog centers scale on the 390 panel base inside the fog frame: x scales, y does not; blobs 1 and 2 drift in opposite directions; at the default stage 366 they fold to panel coordinates, matching Android")
    func fogCentersFollowPanel() {
        #expect(VoiceOrbMath.fogCenter(index: 0, panelWidth: 390, drift: 0) == CGPoint(x: 150, y: 260))
        #expect(VoiceOrbMath.fogCenter(index: 1, panelWidth: 390, drift: 0) == CGPoint(x: 290, y: 310))
        #expect(VoiceOrbMath.fogCenter(index: 2, panelWidth: 390, drift: 0) == CGPoint(x: 220, y: 340))
        #expect(VoiceOrbMath.fogCenter(index: 0, panelWidth: 390, drift: 20) == CGPoint(x: 170, y: 260))
        #expect(VoiceOrbMath.fogCenter(index: 1, panelWidth: 390, drift: 20) == CGPoint(x: 270, y: 310))
        let wide = VoiceOrbMath.fogCenter(index: 2, panelWidth: 780, drift: 20)
        #expect(close(Double(wide.x), 440))
        #expect(close(Double(wide.y), 340))
        #expect(close(Double(VoiceOrbMath.fogCenter(index: 0, panelWidth: 780, drift: -20).x), 260))
        // Bottom anchor: fog frame top = 366 + 120 - 520 = -34; blob 1 center at panel y = 226 (140 from stage bottom).
        let frame = VoiceOrbMath.fogFrame(panelSize: CGSize(width: 390, height: 366))
        #expect(close(Double(frame.minY) + 260, 226))
    }

    @Test("fog frame: height 520, 40 bleed on each side, bottom = stage bottom + 120; fog centers stay fixed relative to the stage bottom as the stage grows taller")
    func fogFrameAnchorsToStageBottom() {
        let base = VoiceOrbMath.fogFrame(panelSize: CGSize(width: 390, height: 366))
        #expect(base == CGRect(x: -40, y: -34, width: 470, height: 520))
        let tall = VoiceOrbMath.fogFrame(panelSize: CGSize(width: 390, height: 520))
        #expect(tall.height == 520)
        #expect(close(Double(tall.maxY), 520 + 120))
        for index in 0..<3 {
            let center = VoiceOrbMath.fogCenter(index: index, panelWidth: 390, drift: 0)
            let fromBottomBase = Double(base.minY + center.y) - 366
            let fromBottomTall = Double(tall.minY + center.y) - 520
            #expect(close(fromBottomBase, fromBottomTall), "blob \(index + 1) bottom-shift delta \(fromBottomTall - fromBottomBase)")
        }
    }

    @Test("envelope attack 40 ms / release 200 ms")
    func envelopeAttackRelease() {
        let up = VoiceOrbMath.envelope(current: 0, target: 1, dt: 0.04)
        #expect(close(up, 1 - exp(-1), 1e-9))
        let down = VoiceOrbMath.envelope(current: 1, target: 0, dt: 0.04)
        #expect(close(down, exp(-0.2), 1e-9))
        #expect(up > 1 - down)
        #expect(VoiceOrbMath.envelope(current: 0.3, target: 0.9, dt: 0) == 0.3)

        var animator = VoiceOrbAnimator()
        _ = animator.advance(time: 0, mode: .user, level: 1, nudges: 0, reduceMotion: false)
        _ = animator.advance(time: 0.1, mode: .user, level: 1, nudges: 0, reduceMotion: false)
        // Contract item 2: after second-stage smoothing, about 0.85 at 100 ms; orb energy follows second-stage b.
        #expect(animator.smoothed > 0.8)
        _ = animator.advance(time: 0.2, mode: .user, level: 0, nudges: 0, reduceMotion: false)
        #expect(animator.envelope > 0.5)
    }

    // MARK: second-stage smoothing and mode-switch easing (contract items 1-4)

    /// Feeds levels to the production animator at a fixed frame rate; returns per-frame first-stage a and second-stage b (first frame dt = 0 is not counted).
    private func feed(_ levels: [Double], hz: Double) -> (a: [Double], b: [Double]) {
        var animator = VoiceOrbAnimator()
        _ = animator.advance(time: 0, mode: .user, level: 0, nudges: 0, reduceMotion: false)
        var a: [Double] = []
        var b: [Double] = []
        for (i, level) in levels.enumerated() {
            let frame = animator.advance(
                time: Double(i + 1) / hz, mode: .user, level: level, nudges: 0, reduceMotion: false
            )
            #expect(close(frame.energy, animator.smoothed), "user-speaking energy uses second-stage b")
            a.append(animator.envelope)
            b.append(animator.smoothed)
        }
        return (a, b)
    }

    private func maxSecondDifference(_ x: [Double]) -> Double {
        (1..<(x.count - 1)).map { abs(x[$0 + 1] - 2 * x[$0] + x[$0 - 1]) }.max() ?? 0
    }

    @Test("second-stage step: b at constant 1 matches contract values frame by frame at 60 / 120 Hz")
    func envelopeTwoStageStep() {
        let b60 = feed(Array(repeating: 1, count: 24), hz: 60).b
        #expect(close(b60[2], 0.541100, 1e-5))
        #expect(close(b60[5], 0.847057, 1e-5))
        #expect(close(b60[11], 0.986347, 1e-5))
        #expect(b60.firstIndex { $0 >= 0.632121 } == 3)

        let b120 = feed(Array(repeating: 1, count: 24), hz: 120).b
        #expect(close(b120[5], 0.509031, 1e-5))
        #expect(close(b120[11], 0.833876, 1e-5))
        #expect(close(b120[23], 0.985061, 1e-5))
        #expect(b120.firstIndex { $0 >= 0.632121 } == 7)

        #expect(close(VoiceOrbMath.smoothTau, 0.024))
        #expect(VoiceOrbMath.smooth(current: 0.3, target: 0.9, dt: 0) == 0.3)
    }

    @Test("second-stage staircase: at a 15 Hz level staircase, the second difference of b is far smaller than that of a")
    func envelopeStaircaseSmooth() {
        let stairs: [Double] = [0.2, 0.6, 0.3, 0.8, 0.5, 0.9, 0.4, 0.7, 0.2, 0, 0.5, 1, 0.6, 0.1]
        let run120 = feed(stairs.flatMap { Array(repeating: $0, count: 8) }, hz: 120)
        #expect(close(maxSecondDifference(run120.b), 0.027111, 1e-5))
        #expect(close(run120.b.last ?? -1, 0.668129, 1e-5))
        #expect(close(maxSecondDifference(run120.a), 0.093291, 1e-5))

        let run60 = feed(stairs.flatMap { Array(repeating: $0, count: 4) }, hz: 60)
        #expect(close(maxSecondDifference(run60.b), 0.083278, 1e-5))
        #expect(close(run60.b.last ?? -1, 0.658897, 1e-5))
        #expect(close(maxSecondDifference(run60.a), 0.167383, 1e-5))
    }

    @Test("mode-switch easing: user-speaking E=1 to thinking over 200 ms easeInOut, frame by frame without jumps and monotonic; switching again mid-way restarts from the current value; reduce motion and muted cut directly")
    func modeSwitchEasesScale() {
        func settledUser(reduceMotion: Bool = false) -> (VoiceOrbAnimator, VoiceOrbFrame, Double) {
            var animator = VoiceOrbAnimator()
            var frame = animator.advance(time: 0, mode: .user, level: 1, nudges: 0, reduceMotion: reduceMotion)
            for i in 1...180 {
                frame = animator.advance(
                    time: Double(i) / 60, mode: .user, level: 1, nudges: 0, reduceMotion: reduceMotion
                )
            }
            return (animator, frame, 180.0 / 60)
        }

        var (animator, last, t0) = settledUser()
        #expect(close(last.scale, 1.16, 1e-6))
        #expect(close(last.energy, 1, 1e-6))
        for i in 1...30 {
            let frame = animator.advance(time: t0 + Double(i) / 60, mode: .think, level: 0, nudges: 0, reduceMotion: false)
            #expect(abs(frame.scale - last.scale) <= 0.04, "frame \(i) Δscale \(frame.scale - last.scale)")
            #expect(abs(frame.energy - last.energy) <= 0.10, "frame \(i) Δenergy \(frame.energy - last.energy)")
            #expect(frame.scale <= last.scale && frame.energy <= last.energy, "frame \(i) not monotonic")
            if i == 12 {
                // The mode-switch frame counts one dt: at 60 Hz, frame 12 is exactly 200 ms, so it settles.
                #expect(close(frame.scale, 0.95, 1e-9), "frame 12 scale \(frame.scale)")
            }
            if Double(i) / 60 >= 0.2 + 1e-9 {
                #expect(close(frame.scale, 0.95, 1e-9))
                #expect(close(frame.energy, 0.45, 1e-9))
            } else if i <= 6 {
                #expect(frame.scale > 0.95 + 0.05, "still transitioning within 200 ms")
            }
            last = frame
        }

        // Switching back to user-speaking mid-transition (100 ms): restart from the current displayed value, do not jump back to the old start.
        (animator, last, t0) = settledUser()
        for i in 1...6 {
            last = animator.advance(time: t0 + Double(i) / 60, mode: .think, level: 1, nudges: 0, reduceMotion: false)
        }
        let mid = last
        #expect(mid.scale < 1.16 - 0.05 && mid.scale > 0.95 + 0.05)
        for i in 7...24 {
            let frame = animator.advance(time: t0 + Double(i) / 60, mode: .user, level: 1, nudges: 0, reduceMotion: false)
            #expect(abs(frame.scale - last.scale) <= 0.04, "restart frame \(i) Δscale \(frame.scale - last.scale)")
            #expect(frame.scale >= last.scale - 1e-12, "restart frame \(i) not monotonic")
            last = frame
        }
        #expect(close(last.scale, 1.16, 1e-6))

        // Muted group cuts directly.
        (animator, last, t0) = settledUser()
        let muted = animator.advance(time: t0 + 1.0 / 60, mode: .muted, level: 1, nudges: 0, reduceMotion: false)
        #expect(close(muted.scale, 1) && close(muted.energy, 0.05))
        let unmuted = animator.advance(time: t0 + 2.0 / 60, mode: .think, level: 0, nudges: 0, reduceMotion: false)
        #expect(close(unmuted.scale, 0.95) && close(unmuted.energy, 0.45))

        // Reduce motion cuts directly: energy stays 0, no scaling, the target applies on the switch frame.
        (animator, last, t0) = settledUser(reduceMotion: true)
        let reduced = animator.advance(time: t0 + 1.0 / 60, mode: .think, level: 0, nudges: 0, reduceMotion: true)
        #expect(reduced.energy == VoiceOrbMath.energy(mode: .think, envelope: 0, breathe: 0, reduceMotion: true))
        #expect(reduced.scale == VoiceOrbMath.scale(mode: .think, energy: 0, breathe: 0, reduceMotion: true))
    }

    // MARK: palette transition and frame rate

    @Test("palette mix factor 0 to 1 takes 200 ms easeInOut; reduce motion jumps straight to 1")
    func paletteMixTakes200ms() {
        #expect(close(VoiceOrbMath.paletteTransition, 0.2))
        #expect(VoiceOrbMath.paletteMix(elapsed: 0, reduceMotion: false) == 0)
        #expect(close(VoiceOrbMath.paletteMix(elapsed: 0.1, reduceMotion: false), 0.5, 1e-6))
        let early = VoiceOrbMath.paletteMix(elapsed: 0.02, reduceMotion: false)
        #expect(early > 0 && early < 0.1, "easeInOut starts slowly")
        #expect(VoiceOrbMath.paletteMix(elapsed: 0.199, reduceMotion: false) < 1)
        #expect(VoiceOrbMath.paletteMix(elapsed: 0.2, reduceMotion: false) == 1)
        #expect(VoiceOrbMath.paletteMix(elapsed: 0, reduceMotion: true) == 1)

        var blend = VoicePaletteBlend<Bool>()
        #expect(blend.advance(key: false, time: 10, reduceMotion: false).mix == 1)
        let start = blend.advance(key: true, time: 11, reduceMotion: false)
        #expect(start.from == false)
        #expect(start.mix == 0)
        let mid = blend.advance(key: true, time: 11.1, reduceMotion: false)
        #expect(mid.from == false)
        #expect(close(mid.mix, 0.5, 1e-6))
        let done = blend.advance(key: true, time: 11.2, reduceMotion: false)
        #expect(done.from == true)
        #expect(done.mix == 1)

        var reduced = VoicePaletteBlend<VoiceFogPaletteKey>()
        _ = reduced.advance(key: VoiceFogPaletteKey(ai: false, notice: false), time: 0, reduceMotion: true)
        let switched = reduced.advance(key: VoiceFogPaletteKey(ai: false, notice: true), time: 1, reduceMotion: true)
        #expect(switched.from == VoiceFogPaletteKey(ai: false, notice: true))
        #expect(switched.mix == 1)
    }

    private func same(_ a: VoiceOrbMath.RGB, _ b: VoiceOrbMath.RGB) -> Bool {
        close(a.red, b.red) && close(a.green, b.green) && close(a.blue, b.blue)
    }

    @Test("palette interpolation: midpoint is between both colors; a blob missing in the fog hint state is filled with alpha 0")
    func paletteInterpolation() {
        let mid = VoiceOrbMath.mix(0x000000, 0xFFFFFF, 0.5)
        #expect(close(mid.red, 0.5) && close(mid.green, 0.5) && close(mid.blue, 0.5))
        #expect(same(VoiceOrbMath.mix(0x38D6E8, 0x5EEAD4, 0), VoiceOrbMath.RGB(hex: 0x38D6E8)))
        #expect(same(VoiceOrbMath.mix(0x38D6E8, 0x5EEAD4, 1), VoiceOrbMath.RGB(hex: 0x5EEAD4)))

        let plain = VoiceOrbMath.fogCircles(mode: .listen, energy: 0, dark: false, notice: false)
        let amber = VoiceOrbMath.fogCircles(mode: .listen, energy: 0, dark: false, notice: true)
        let half = VoiceOrbMath.blendFog(from: plain, to: amber, 0.5)
        #expect(half.count == 3)
        #expect(close(half[2].alpha, plain[2].alpha / 2))
        #expect(same(half[1].color, VoiceOrbMath.mix(plain[1].color, VoiceOrbMath.amber, 0.5)))
        let end = VoiceOrbMath.blendFog(from: plain, to: amber, 1)
        #expect(same(end[1].color, VoiceOrbMath.RGB(hex: VoiceOrbMath.amber)))
        #expect(end[2].alpha == 0)
    }

    @Test("stage clock override: fog drift and orb phase freeze at the override time, repeated frame reads are unchanged; AI-speaking energy = 0.9 × given level")
    func stageClockFreezesFrame() {
        // Manifest stageClockMs = 0: drift 0, phase 0, breathe .5.
        let zero = VoiceOrbAnimator.stageFrame(time: 0, mode: .listen, level: 0)
        #expect(zero.phase == 0)
        #expect(VoiceOrbMath.fogDrift(time: 0, reduceMotion: false) == 0)
        #expect(close(zero.scale, 1 + 0.025 * 0.5))
        #expect(zero.nudgeOffset == 0 && zero.nudgeAlpha == 1)

        // Repeated reads at the same time: phase and energy do not depend on the call count.
        let t = 2.6 * .pi / 2
        let first = VoiceOrbAnimator.stageFrame(time: t, mode: .ai, level: 0.5)
        let again = VoiceOrbAnimator.stageFrame(time: t, mode: .ai, level: 0.5)
        #expect(first == again)
        #expect(close(first.phase, t * VoiceOrbMath.phaseSpeed(mode: .ai, energy: 0.45)))
        #expect(close(VoiceOrbMath.fogDrift(time: t, reduceMotion: false), 20))

        // The envelope equals the level directly; energy uses the production formula: AI speaking = 0.9 × level, user speaking = level.
        #expect(close(first.energy, 0.45))
        #expect(close(VoiceOrbMath.stageEnergy(mode: .ai, level: 0.5, time: 0), 0.45))
        #expect(close(VoiceOrbMath.stageEnergy(mode: .user, level: 0.6, time: 0), 0.6))
        #expect(close(VoiceOrbMath.stageEnergy(mode: .think, level: 0, time: 0), 0.45))
        #expect(close(VoiceOrbAnimator.stageFrame(time: 0, mode: .think, level: 0).scale, 0.95))

        // The view reads the environment value: default nil (production follows the wall clock). When overridden, the timeline pauses and frame and palette times use the override.
        #expect(EnvironmentValues().voiceStageClock == nil)
        let source = try? String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "OriveoTests/Features/Chat/VoiceAuroraOrbTests.swift",
                with: "Oriveo/Features/Chat/Voice/VoiceAuroraOrb.swift"
            ),
            encoding: .utf8
        )
        #expect(source?.components(separatedBy: "@Environment(\\.voiceStageClock)").count == 3)
        #expect(source?.components(separatedBy: "if stageClock != nil { return true }").count == 3)
        #expect(source?.components(separatedBy: "time: stageClock ?? Date().timeIntervalSinceReferenceDate").count == 3)
    }

    @Test("timeline minimum interval: orb 1/60 s, fog 1/30 s")
    func timelineMinimumInterval() {
        #expect(close(VoiceOrbMath.orbFrameInterval, 1.0 / 60))
        #expect(close(VoiceOrbMath.fogFrameInterval, 1.0 / 30))
        let source = try? String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "OriveoTests/Features/Chat/VoiceAuroraOrbTests.swift",
                with: "Oriveo/Features/Chat/Voice/VoiceAuroraOrb.swift"
            ),
            encoding: .utf8
        )
        #expect(source != nil, "cannot read the orb source")
        #expect(source?.contains(".animation(minimumInterval: VoiceOrbMath.orbFrameInterval") == true)
        #expect(source?.contains(".animation(minimumInterval: VoiceOrbMath.fogFrameInterval") == true)
        #expect(source?.contains("TimelineView(.animation(paused") == false)
    }

    @Test("fog frame includes the bottom safe area: bottom = stage bottom + safe area + 120, same as the canvas full-screen bottom -120; top shifts down with it")
    func fogFrameAnchorsToScreenBottom() {
        let frame = VoiceOrbMath.fogFrame(panelSize: CGSize(width: 390, height: 366), bottomInset: 34)
        #expect(close(Double(frame.maxY), 366 + 34 + 120))
        #expect(frame.height == 520)
        #expect(close(Double(frame.minX), -40))
        #expect(close(Double(frame.width), 470))
        #expect(VoiceOrbMath.fogFrame(panelSize: CGSize(width: 390, height: 366), bottomInset: 0)
            == VoiceOrbMath.fogFrame(panelSize: CGSize(width: 390, height: 366)))
        // The panel background and fogFrame share one formula instead of offsetting fogBelow on their own.
        let source = try? String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "OriveoTests/Features/Chat/VoiceAuroraOrbTests.swift",
                with: "Oriveo/Features/Chat/Voice/VoiceConversationBar.swift"
            ),
            encoding: .utf8
        )
        #expect(source?.contains("VoiceOrbMath.fogFrame(") == true)
        #expect(source?.contains(".offset(y: CGFloat(VoiceOrbMath.fogBelow))") == false)
    }

    @Test("GraphicsContext blur measured: the 16%-84% transition width of a white half-plane after blur = 2σ; converted σ is within 3% of the target")
    func blurRadiusMatchesCanvasSigma() throws {
        for target in [70.0, 60, 80, 14, 22] {
            let radius = VoiceOrbMath.blurRadius(sigma: target)
            let sigma = try #require(Self.measuredSigma(radius: Double(radius)), "σ\(target) transition not measured")
            #expect(abs(sigma / target - 1) <= 0.03, "target σ\(target) radius \(radius) measured σ \(sigma) (ratio \(sigma / Double(radius)))")
        }
    }

    /// Canvas `<g filter=glow opacity=bloom>`: the three circles are composited opaque first, then the whole group is Gaussian-blurred, then multiplied by bloom and laid over the background.
    /// Draws only the glow layer over a plain background, sampling every 2 units from r58 to r110 along 8 directions (viewBox units; at size 200, 1 unit = 1 pt), and compares against the analytic values.
    @Test("outer glow composed as a group: union of three circles ⊗ Gaussian × bloom")
    func glowComposesAsGroup() throws {
        let side = 380, energy = 0.3, phase = 1.3, sigma = 22.0
        let origin = Double(side) / 2
        let geometry = VoiceOrbMath.glowCircles(phase: phase, energy: energy).map {
            (cx: $0.cx - 100 + origin, cy: $0.cy - 100 + origin, r: $0.r)
        }
        let colors = VoiceOrbMath.orbPalette(ai: false).prefix(3).map { VoiceOrbMath.RGB(hex: $0) }
        // Analytic: per pixel, 4×4 subsampling gives the premultiplied RGBA of the top opaque color, then a separable Gaussian.
        var planes = [[Double]](repeating: [Double](repeating: 0, count: side * side), count: 4)
        for y in 0..<side {
            for x in 0..<side {
                var acc = [0.0, 0, 0, 0]
                for sy in 0..<4 {
                    for sx in 0..<4 {
                        let px = Double(x) + (Double(sx) + 0.5) / 4, py = Double(y) + (Double(sy) + 0.5) / 4
                        guard let top = geometry.indices.last(where: {
                            let dx = px - geometry[$0].cx, dy = py - geometry[$0].cy
                            return dx * dx + dy * dy <= geometry[$0].r * geometry[$0].r
                        }) else { continue }
                        acc[0] += colors[top].red; acc[1] += colors[top].green; acc[2] += colors[top].blue; acc[3] += 1
                    }
                }
                for c in 0..<4 { planes[c][y * side + x] = acc[c] / 16 }
            }
        }
        let blurred = planes.map { Self.gaussian($0, side: side, sigma: sigma) }
        for dark in [false, true] {
            let bg = VoiceOrbMath.RGB(hex: dark ? 0x0B0B12 : 0xF4F5F8)
            let bloom = VoiceOrbMath.glowAlpha(mode: .user, energy: energy, dark: dark)
            let content = Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(.sRGB, red: bg.red, green: bg.green, blue: bg.blue)))
                VoiceOrbPaint.drawGlow(
                    in: ctx,
                    circles: geometry.enumerated().map { i, c in
                        (Path(ellipseIn: CGRect(x: c.cx - c.r, y: c.cy - c.r, width: 2 * c.r, height: 2 * c.r)), Color(.sRGB, red: colors[i].red, green: colors[i].green, blue: colors[i].blue))
                    },
                    sigma: CGFloat(sigma),
                    bloom: bloom
                )
            }
            .frame(width: CGFloat(side), height: CGFloat(side))
            let pixels = try #require(Self.renderRGBA(content, side: side))
            let bgc = [bg.red, bg.green, bg.blue]
            var worst = 0.0, worstAt = ""
            for k in 0..<8 {
                let angle = Double(k) * .pi / 4
                for r in stride(from: 58.0, through: 110, by: 2) {
                    let x = Int(origin + r * cos(angle)), y = Int(origin + r * sin(angle))
                    let i = y * side + x
                    let a = blurred[3][i]
                    for c in 0..<3 {
                        let expected = (bgc[c] * (1 - bloom * a) + bloom * blurred[c][i]) * 255
                        let actual = Double(pixels[i * 4 + c])
                        if abs(actual - expected) > worst {
                            worst = abs(actual - expected)
                            worstAt = "angle \(k * 45)° r\(Int(r)) channel \(c) measured \(actual) analytic \(expected)"
                        }
                    }
                }
            }
            // Threshold 2/255: 8-bit quantization inside the layer and two roundings from multiplying the whole layer by bloom each reach up to 0.5-1/255; before the fix (per-circle alpha multiply) the residual was 37-61/255,
            // more than an order of magnitude larger, so discrimination is unaffected.
            #expect(worst <= 2, "\(dark ? "dark" : "light") glow residual \(worst)/255 (\(worstAt))")
        }
    }

    @Test("fog profile: disc ⊛ Gaussian radial values per contract item 5; 41 stops cover [0, R+4σ], last stop 0, interpolation error ≤ 1e-3")
    func fogDiscProfile() {
        let a = [(0.0, 0.899331), (150, 0.403950), (220, 0.115670), (290, 0.015066)]
        for (rho, want) in a {
            let got = VoiceOrbMath.fogDiscIntensity(rho: rho, radius: 150, sigma: 70)
            #expect(close(got, want, 2e-4), "(300,70) ρ\(rho) got \(got) expected \(want)")
        }
        for (rho, want) in [(0.0, 0.813730), (110, 0.386054)] {
            let got = VoiceOrbMath.fogDiscIntensity(rho: rho, radius: 110, sigma: 60)
            #expect(close(got, want, 2e-4), "(220,60) ρ\(rho) got \(got) expected \(want)")
        }
        for (diameter, sigma) in [(300.0, 70.0), (280, 70), (220, 60), (280, 80), (280, 75.5)] {
            let profile = VoiceOrbMath.fogProfile(diameter: diameter, sigma: sigma)
            let radius = diameter / 2
            #expect(profile.stops.count == 41)
            #expect(close(profile.extent, radius + 4 * sigma))
            #expect(profile.stops.last == 0)
            // Max error of linear interpolation against the exact profile, sampled every 0.5 pt.
            var worst = 0.0
            for rho in stride(from: 0.0, through: profile.extent, by: 0.5) {
                let u = rho / profile.extent * 40
                let i = min(39, Int(u))
                let lo: Double = profile.stops[i], hi: Double = profile.stops[i + 1]
                let lerp: Double = lo + (hi - lo) * (u - Double(i))
                let exact: Double = VoiceOrbMath.fogDiscIntensity(rho: rho, radius: radius, sigma: sigma)
                worst = max(worst, abs(lerp - exact))
            }
            #expect(worst <= 1e-3, "(\(diameter),\(sigma)) interpolation error \(worst)")
        }
        // σ is rounded to 0.5 for caching: transitional σ values land in the same bucket.
        #expect(VoiceOrbMath.fogProfile(diameter: 280, sigma: 75.4) == VoiceOrbMath.fogProfile(diameter: 280, sigma: 75.5))
        #expect(close(VoiceOrbMath.fogProfile(diameter: 280, sigma: 75.4).sigma, 75.5))
        // Diameter is rounded to 0.5 as well.
        #expect(VoiceOrbMath.fogProfile(diameter: 289.9, sigma: 70) == VoiceOrbMath.fogProfile(diameter: 290, sigma: 70))
        #expect(close(VoiceOrbMath.fogProfile(diameter: 289.9, sigma: 70).extent, 145 + 4 * 70))
    }

    /// A single fog blob drawn by production code on light and dark backgrounds, compared with the analytic value of "disc, 4×4 subsampled ⊗ Gaussian σ × alpha":
    /// Sampled every 4 pt along 8 directions, r from 0 to R+3σ.
    @Test("single fog blob gradient = disc ⊛ Gaussian × alpha")
    func fogGradientMatchesDiscBlur() throws {
        let side = 760, diameter = 300.0, sigma = 70.0, alpha = 0.4
        let origin = Double(side) / 2, radius = diameter / 2
        let color = VoiceOrbMath.RGB(hex: 0x8B5CF6)
        var disk = [Double](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                var hit = 0.0
                for sy in 0..<4 {
                    for sx in 0..<4 {
                        let dx = Double(x) + (Double(sx) + 0.5) / 4 - origin, dy = Double(y) + (Double(sy) + 0.5) / 4 - origin
                        if dx * dx + dy * dy <= radius * radius { hit += 1 }
                    }
                }
                disk[y * side + x] = hit / 16
            }
        }
        let coverage = Self.gaussian(disk, side: side, sigma: sigma)
        for dark in [false, true] {
            let bg = VoiceOrbMath.RGB(hex: dark ? 0x0B0B12 : 0xF4F5F8)
            let content = Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(.sRGB, red: bg.red, green: bg.green, blue: bg.blue)))
                VoiceOrbPaint.drawFogCircle(
                    in: ctx, center: CGPoint(x: origin, y: origin), color: color, alpha: alpha, diameter: diameter, sigma: sigma
                )
            }
            .frame(width: CGFloat(side), height: CGFloat(side))
            let pixels = try #require(Self.renderRGBA(content, side: side))
            let bgc = [bg.red, bg.green, bg.blue], fg = [color.red, color.green, color.blue]
            var worst = 0.0, worstAt = ""
            for k in 0..<8 {
                let angle = Double(k) * .pi / 4
                for r in stride(from: 0.0, through: radius + 3 * sigma, by: 4) {
                    let x = Int(origin + r * cos(angle)), y = Int(origin + r * sin(angle))
                    let i = y * side + x
                    let a = alpha * coverage[i]
                    for c in 0..<3 {
                        let expected = (bgc[c] * (1 - a) + fg[c] * a) * 255
                        let actual = Double(pixels[i * 4 + c])
                        if abs(actual - expected) > worst {
                            worst = abs(actual - expected)
                            worstAt = "angle \(k * 45)° r\(Int(r)) channel \(c) measured \(actual) analytic \(expected)"
                        }
                    }
                }
            }
            #expect(worst <= 1.5, "\(dark ? "dark" : "light") fog residual \(worst)/255 (\(worstAt))")
        }
    }

    /// Separable Gaussian (kernel ±4σ; out-of-range samples count as 0).
    private static func gaussian(_ plane: [Double], side: Int, sigma: Double) -> [Double] {
        let half = Int((4 * sigma).rounded(.up))
        let kernel = (-half...half).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        let k = kernel.map { $0 / total }
        func pass(_ input: [Double]) -> [Double] {
            // Convolve horizontally then transpose; two passes give the 2-D result.
            var out = [Double](repeating: 0, count: side * side)
            var padded = [Double](repeating: 0, count: side + 2 * half)
            var row = [Double](repeating: 0, count: side)
            for y in 0..<side {
                for x in 0..<side { padded[half + x] = input[y * side + x] }
                vDSP_convD(padded, 1, k, 1, &row, 1, vDSP_Length(side), vDSP_Length(k.count))
                for x in 0..<side { out[x * side + y] = row[x] }
            }
            return out
        }
        return pass(pass(plane))
    }

    /// Renders at 1x into premultiplied RGBA bytes in DeviceRGB.
    private static func renderRGBA(_ content: some View, side: Int) -> [UInt8]? {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let image = renderer.cgImage, image.width == side, image.height == side else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels
    }

    /// Draws a Canvas with a white left half and a transparent right half, applies blur(radius:) to the whole layer, and measures the width over which α falls from 84% to 16% along the middle row; σ = width / 2 (pt).
    private static func measuredSigma(radius: Double) -> Double? {
        let width = 1200.0, height = 800.0, scale = 2.0
        let content = Canvas { ctx, size in
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: CGFloat(radius)))
                layer.fill(
                    Path(CGRect(x: -2000, y: -2000, width: 2000 + Double(size.width) / 2, height: Double(size.height) + 4000)),
                    with: .color(.white)
                )
            }
        }
        .frame(width: width, height: height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let row = h / 2
        let alpha = (0..<w).map { Double(pixels[(row * w + $0) * 4 + 3]) / 255 }
        // Linearly interpolates the x (pixel) where α first drops below level.
        func crossing(_ level: Double) -> Double? {
            for x in 1..<w where alpha[x - 1] >= level && alpha[x] < level {
                return Double(x - 1) + (alpha[x - 1] - level) / (alpha[x - 1] - alpha[x])
            }
            return nil
        }
        guard let hi = crossing(0.84), let lo = crossing(0.16) else { return nil }
        return (lo - hi) / scale / 2
    }
}

