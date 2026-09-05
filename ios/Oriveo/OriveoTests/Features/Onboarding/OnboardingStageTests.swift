import Foundation
import Testing
@testable import Oriveo

@Suite("OnboardingStage")
@MainActor
struct OnboardingStageTests {
    private let width: Double = 390

    private func values(at progress: Double) -> OnboardingStageValues {
        OnboardingStageValues(progress: progress, width: width)
    }

    private func isClose(_ lhs: Double, _ rhs: Double, tolerance: Double = 1e-9) -> Bool {
        abs(lhs - rhs) <= tolerance
    }


    @Test("Triangle Weight")
    func triangleWeight() {
        #expect(OnboardingMath.tri(1, 1, 1) == 1)
        #expect(OnboardingMath.tri(1.5, 1, 1) == 0.5)
        #expect(OnboardingMath.tri(2, 1, 1) == 0)
        #expect(OnboardingMath.tri(9, 1, 1) == 0)
    }

    @Test("Smoothstep Endpoints")
    func smoothstepEndpoints() {
        #expect(OnboardingMath.smoothstep(0) == 0)
        #expect(OnboardingMath.smoothstep(1) == 1)
        #expect(OnboardingMath.smoothstep(0.5) == 0.5)
        #expect(OnboardingMath.smoothstep(-3) == 0)
        #expect(OnboardingMath.smoothstep(4) == 1)
    }


    @Test("Progress Is Clamped")
    func progressIsClamped() {
        #expect(values(at: -5).progress == -0.35)
        #expect(values(at: 99).progress == 3.35)
    }


    @Test("Aurora Matches Palette")
    func auroraMatchesPalette() {
        for (index, entry) in OnboardingStageValues.auroraPalette.enumerated() {
            let value = values(at: Double(index))
            #expect(value.auroraTop == entry.top)
            #expect(value.auroraBottom == entry.bottom)
        }

        let midway = values(at: 0.5)
        let expected = OnboardingRGB.lerp(
            OnboardingStageValues.auroraPalette[0].top,
            OnboardingStageValues.auroraPalette[1].top,
            0.5
        )
        #expect(midway.auroraTop == expected)
    }


    @Test("Centerpieces Cross Fade")
    func centerpiecesCrossFade() {
        let brand = values(at: 0)
        #expect(brand.nucleusOpacity == 1)
        #expect(brand.byokOpacity == 0)

        let byok = values(at: 2)
        #expect(byok.byokOpacity == 1)
        #expect(byok.nucleusOpacity == 0)

        let start = values(at: 3)
        #expect(start.byokOpacity == 0)
        #expect(start.nucleusOpacity == 0)
    }

    @Test("Orbiters Peak On Second Act")
    func orbitersPeakOnSecondAct() {
        #expect(values(at: 1).orbitersOpacity == 1)
        #expect(values(at: 0).orbitersOpacity == 0)
        #expect(values(at: 2).orbitersOpacity == 0)
        #expect(values(at: 1).orbitersOffsetX == 0)
        #expect(values(at: 0).orbitersOffsetX > 0)
    }

    @Test("Centerpiece Parallax Is Slower Than Copy")
    func centerpieceParallaxIsSlowerThanCopy() {
        #expect(values(at: 2).byokOffsetX == 0)
        #expect(values(at: 1).byokOffsetX == width * 0.25)
    }

    @Test("Copy Opacity Peaks On Its Own Act")
    func copyOpacityPeaksOnItsOwnAct() {
        for act in OnboardingAct.allCases {
            let value = values(at: Double(act.rawValue))
            #expect(value.copyOpacity(for: act) == 1)
            for other in OnboardingAct.allCases where other != act {
                #expect(value.copyOpacity(for: other) == 0)
            }
        }
    }


    @Test("Pill Morphs Only On Final Stretch")
    func pillMorphsOnlyOnFinalStretch() {
        #expect(values(at: 2.2).ctaMorph == 0)
        #expect(isClose(values(at: 3).ctaMorph, 1))
        #expect(isClose(values(at: 2.6).ctaMorph, 0.5))
        #expect(values(at: 2).ctaMorph == 0)

        #expect(values(at: 2.2).pillWidth == OnboardingStageValues.dotsBarWidth)
        #expect(isClose(values(at: 3).pillWidth, width - 72))
    }

    @Test("Final Act Hands Over Controls")
    func finalActHandsOverControls() {
        let final = values(at: 3)
        #expect(final.dotsOpacity == 0)
        #expect(final.skipOpacity == 0)
        #expect(isClose(final.ctaLabelOpacity, 1))
        #expect(isClose(final.loginOpacity, 1))
        #expect(isClose(final.loginOffsetY, 0))
    }

    @Test("Hit Testing Gates Are Mutually Exclusive")
    func hitTestingGatesAreMutuallyExclusive() {
        #expect(values(at: 2.5).isCTAInteractive == false)
        #expect(values(at: 3).isCTAInteractive == true)

        #expect(values(at: 2.6).isSkipInteractive == true)
        #expect(values(at: 2.7).isSkipInteractive == false)

        #expect(values(at: 3).areDotsInteractive == false)
        #expect(values(at: 0).areDotsInteractive == true)
    }
}


@Suite("OnboardingOrbit")
@MainActor
struct OnboardingOrbitTests {
    @Test("Orbiters Stay On Their Ellipse")
    func orbitersStayOnTheirEllipse() {
        for orbiter in OnboardingOrbitCatalog.orbiters {
            let ring = OnboardingOrbitCatalog.rings[orbiter.ringIndex]
            let tilt = ring.tiltDegrees * .pi / 180

            for time in stride(from: 0.0, through: 90.0, by: 7.5) {
                let point = OnboardingOrbitCatalog.position(for: orbiter, time: time)
                let localX = point.x * cos(-tilt) - point.y * sin(-tilt)
                let localY = point.x * sin(-tilt) + point.y * cos(-tilt)
                let residual = pow(localX / ring.radiusX, 2) + pow(localY / ring.radiusY, 2)
                #expect(abs(residual - 1) < 0.0001)
            }
        }
    }

    @Test("Depth Drives Front Back Crossing")
    func depthDrivesFrontBackCrossing() {
        let ring0 = OnboardingOrbiter(assetName: "Probe", size: 32, ringIndex: 0, phase: 0.25)
        #expect(abs(OnboardingOrbitCatalog.position(for: ring0, time: 0).depth - 1) < 0.0001)

        let ring0Back = OnboardingOrbiter(assetName: "Probe", size: 32, ringIndex: 0, phase: 0.75)
        #expect(abs(OnboardingOrbitCatalog.position(for: ring0Back, time: 0).depth + 1) < 0.0001)
    }

    @Test("Second Ring Runs Backwards")
    func secondRingRunsBackwards() {
        let forward = OnboardingOrbiter(assetName: "Probe", size: 32, ringIndex: 0, phase: 0)
        let backward = OnboardingOrbiter(assetName: "Probe", size: 32, ringIndex: 1, phase: 0)

        #expect(OnboardingOrbitCatalog.position(for: forward, time: 4).depth > 0)
        #expect(OnboardingOrbitCatalog.position(for: backward, time: 4).depth < 0)
    }

    @Test("Orbiter Assets Are Distinct")
    func orbiterAssetsAreDistinct() {
        let names = OnboardingOrbitCatalog.orbiters.map(\.assetName)
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { $0.hasPrefix("Provider") })
    }

    @Test("Decorative Ring Spins Once")
    func decorativeRingSpinsOnce() {
        let ring = OnboardingOrbitCatalog.rings[2]
        #expect(OnboardingOrbitCatalog.decorativeSpinDegrees(time: 0) == ring.tiltDegrees)
        #expect(
            abs(OnboardingOrbitCatalog.decorativeSpinDegrees(time: ring.periodSeconds)
                - (ring.tiltDegrees + 360)) < 0.0001
        )
    }
}


@Suite("OnboardingCopyMarkup")
@MainActor
struct OnboardingCopyMarkupTests {
    @Test("Parses Highlight Segments")
    func parsesHighlightSegments() {
        let segments = OnboardingCopyMarkup.parse("All Your Models, {One App}")
        #expect(segments == [
            .init(text: "All Your Models, ", isHighlighted: false),
            .init(text: "One App", isHighlighted: true)
        ])
    }

    @Test("Highlight Can Lead The Sentence")
    func highlightCanLeadTheSentence() {
        let segments = OnboardingCopyMarkup.parse("{いま}はじめる")
        #expect(segments.first == .init(text: "いま", isHighlighted: true))
        #expect(segments.last == .init(text: "はじめる", isHighlighted: false))
    }

    @Test("Plain String Stays Plain")
    func plainStringStaysPlain() {
        #expect(OnboardingCopyMarkup.parse("Start Now") == [.init(text: "Start Now", isHighlighted: false)])
    }

    @Test("Unbalanced Brace Falls Back Without Losing Text")
    func unbalancedBraceFallsBackWithoutLosingText() {
        let raw = "Start {Now"
        #expect(OnboardingCopyMarkup.parse(raw).allSatisfy { !$0.isHighlighted })
        #expect(OnboardingCopyMarkup.plainText(raw) == raw)
    }

    @Test("Plain Text Strips Markup")
    func plainTextStripsMarkup() {
        #expect(OnboardingCopyMarkup.plainText("Your Keys, {Your Bill}") == "Your Keys, Your Bill")
    }
}


@Suite("Onboarding acts and motion")
@MainActor
struct OnboardingActContractTests {
    @Test("Step Names Keep Funnel Contract")
    func stepNamesKeepFunnelContract() {
        #expect(OnboardingAct.brand.stepName == "welcome")
        #expect(OnboardingAct.models.stepName == "models")
        #expect(OnboardingAct.byok.stepName == "byok")
        #expect(OnboardingAct.start.stepName == "start")
    }

    @Test("Orbit Clock Pauses When It Should")
    func orbitClockPausesWhenItShould() {
        #expect(OnboardingMotionPolicy.isOrbitClockPaused(reduceMotion: false, isStageActive: true) == false)
        #expect(OnboardingMotionPolicy.isOrbitClockPaused(reduceMotion: true, isStageActive: true) == true)
        #expect(OnboardingMotionPolicy.isOrbitClockPaused(reduceMotion: false, isStageActive: false) == true)
    }
}
