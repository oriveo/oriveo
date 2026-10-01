import SwiftUI
import Testing
import UIKit

@testable import Oriveo

/// Locks every branch of the pure function that decides how waiting feedback is presented.
@Suite("Stream activity status line: presentation")
struct StreamActivityPresentationTests {

    @Test("Not generating: hidden for every input")
    func notGeneratingIsAlwaysHidden() {
        for hasBody in [false, true] {
            for typing in [false, true] {
                for activity in [StreamActivity?.none, .webSearch] {
                    for quiet in [false, true] {
                        #expect(StreamActivityPresentation.resolve(
                            isGenerating: false,
                            hasBodyText: hasBody,
                            typingIndicatorVisible: typing,
                            activity: activity,
                            quiet: quiet
                        ) == .hidden)
                    }
                }
            }
        }
    }

    @Test("Activity with the typing indicator visible: the indicator carries the label, no status line on top")
    func activityWithTypingIndicatorOverridesCaptionOnly() {
        for quiet in [false, true] {
            for hasBody in [false, true] {
                #expect(StreamActivityPresentation.resolve(
                    isGenerating: true,
                    hasBodyText: hasBody,
                    typingIndicatorVisible: true,
                    activity: .webSearch,
                    quiet: quiet
                ) == .typingCaption(.webSearch))
            }
        }
    }

    @Test("Activity without the typing indicator: the status line shows the activity label (body text exists, or the reasoning block replaced the indicator)")
    func activityWithoutTypingIndicatorShowsStatusLine() {
        for quiet in [false, true] {
            for hasBody in [false, true] {
                #expect(StreamActivityPresentation.resolve(
                    isGenerating: true,
                    hasBodyText: hasBody,
                    typingIndicatorVisible: false,
                    activity: .webSearch,
                    quiet: quiet
                ) == .statusLine(.activity(.webSearch)))
            }
        }
    }

    @Test("No activity, quiet, body text present: the status line shows the neutral label")
    func quietWithBodyShowsNeutralStatusLine() {
        #expect(StreamActivityPresentation.resolve(
            isGenerating: true,
            hasBodyText: true,
            typingIndicatorVisible: false,
            activity: nil,
            quiet: true
        ) == .statusLine(.neutral))
    }

    @Test("Everything else is hidden: a pause with an empty body, and no pause at all")
    func remainingCasesAreHidden() {
        // A pause with an empty body: the typing indicator or the reasoning block is already
        // moving, so there is no status line.
        for typing in [false, true] {
            #expect(StreamActivityPresentation.resolve(
                isGenerating: true,
                hasBodyText: false,
                typingIndicatorVisible: typing,
                activity: nil,
                quiet: true
            ) == .hidden)
        }
        // Text is still appearing (no pause).
        for hasBody in [false, true] {
            #expect(StreamActivityPresentation.resolve(
                isGenerating: true,
                hasBodyText: hasBody,
                typingIndicatorVisible: !hasBody,
                activity: nil,
                quiet: false
            ) == .hidden)
        }
    }

    @Test("Label keys: neutral reuses Generating, web search comes from the Chat table")
    @MainActor
    func captionsResolveToLocalizedKeys() {
        #expect(StreamActivityCaption.neutral.localizedText == L10n.tr("Generating"))
        #expect(
            StreamActivityCaption.activity(.webSearch).localizedText
                == L10n.tr("Searching the web", table: .chat)
        )
        // The label itself does not end in an ellipsis.
        #expect(!StreamActivityCaption.activity(.webSearch).localizedText.hasSuffix("…"))
    }
}

/// The pause is measured from the last change to visible content.
@MainActor
@Suite("Stream activity status line: pause detection")
struct StreamQuietTimerTests {

    @Test("The default threshold is 1500 ms")
    func defaultThresholdMatchesContract() {
        #expect(StreamQuietTimer.defaultThreshold == 1.5)
    }

    @Test("Quiet only after a full threshold without a visible change; a change in between pushes the clock back")
    func quietOnlyAfterFullThresholdSinceLastVisibleChange() async throws {
        // Threshold and intervals leave headroom: Task.sleep overshoots on a loaded machine, and a
        // 0.5 s interval against a 0.9 s threshold leaves 0.4 s of tolerance.
        let timer = StreamQuietTimer(threshold: 0.9)
        var flips: [Bool] = []
        timer.onQuietChanged = { flips.append(timer.isQuiet) }

        timer.noteVisibleChange()
        #expect(!timer.isQuiet)
        #expect(timer.isArmed)

        // More text appears at 0.5 s: the starting point moves, so the original 0.9 s deadline
        // must not report quiet.
        try await Task.sleep(nanoseconds: 500_000_000)
        timer.noteVisibleChange()
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(!timer.isQuiet, "only about 0.5 s since the last visible change, so this is not a pause (about 1.0 s since the timer first started)")
        #expect(flips.isEmpty)

        let deadline = ContinuousClock.now + .seconds(5)
        while !timer.isQuiet, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(timer.isQuiet)
        #expect(flips == [true])
        #expect(!timer.isArmed, "no timer is left running once quiet")

        // The next visible change leaves quiet immediately and restarts the timer.
        timer.noteVisibleChange()
        #expect(!timer.isQuiet)
        #expect(flips == [true, false])
        #expect(timer.isArmed)
        timer.cancel()
    }

    @Test("cancel stops and resets the timer; a late deadline no longer reports quiet")
    func cancelStopsTimer() async throws {
        let timer = StreamQuietTimer(threshold: 0.1)
        var fired = 0
        timer.onQuietChanged = { fired += 1 }
        timer.noteVisibleChange()
        timer.cancel()
        #expect(!timer.isArmed)
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(!timer.isQuiet)
        #expect(fired == 0)
    }
}

/// Static and animated properties of the status line view.
@MainActor
@Suite("Stream activity status line: view")
struct UIKitStreamActivityLineTests {

    @Test("The whole line is one accessibility element whose label is the text; it stops presenting once dismissed")
    func accessibilityAndLifecycle() {
        let line = UIKitStreamActivityLine()
        #expect(!line.isPresenting)

        line.present(text: "Searching the web")
        #expect(line.isPresenting)
        #expect(line.text == "Searching the web")
        #expect(line.isAccessibilityElement)
        #expect(line.accessibilityLabel == "Searching the web")

        // Swapping the text in place (the activity cleared and the label turned neutral) does not
        // replay the entrance.
        line.present(text: "Generating")
        #expect(line.text == "Generating")
        #expect(line.accessibilityLabel == "Generating")

        line.dismiss()
        #expect(!line.isPresenting)
        #expect(!line._testIsSweeping)
        #expect(line.alpha == 1)
    }

    @Test("Presented in a window it sweeps: 1.8 s linear, repeating forever, a band about 30% of the text width, in the reading direction; it stops on leaving the window")
    func sweepAnimationMatchesContract() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let host = UIView(frame: window.bounds)
        window.addSubview(host)
        window.isHidden = false
        defer { window.isHidden = true }

        func makeLine(rtl: Bool) -> UIKitStreamActivityLine {
            let line = UIKitStreamActivityLine()
            line.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            line.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                line.topAnchor.constraint(equalTo: host.topAnchor),
                line.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor),
            ])
            line.present(text: "Searching the web")
            host.layoutIfNeeded()
            return line
        }

        let line = makeLine(rtl: false)
        if UIAccessibility.isReduceMotionEnabled {
            // Reduce Motion: no sweep, static textSecondary.
            #expect(!line._testIsSweeping)
            #expect(line._testHighlightHidden)
            #expect(line._testBaseTextColor == UIColor(OriveoTheme.Palette.textSecondary))
            return
        }

        let sweep = try #require(line._testSweepAnimation, "presented in a window with a non-zero width, the line must be sweeping")
        #expect(sweep.duration == 1.8)
        #expect(sweep.repeatCount == .infinity)
        // Linear: control points (0,0) and (1,1).
        let timing = try #require(sweep.timingFunction)
        var c1: [Float] = [-1, -1]
        var c2: [Float] = [-1, -1]
        timing.getControlPoint(at: 1, values: &c1)
        timing.getControlPoint(at: 2, values: &c2)
        #expect(c1 == [0, 0])
        #expect(c2 == [1, 1])
        let width = line._testHighlightLabelWidth
        #expect(width > 0)
        #expect(abs(line._testHighlightBandWidth - width * 0.3) < 0.5)
        let from = try #require(sweep.fromValue as? CGFloat)
        let to = try #require(sweep.toValue as? CGFloat)
        #expect(from < to, "LTR: from the start of the line to its end")
        #expect(line._testBaseTextColor == UIColor(OriveoTheme.Palette.textTertiary))
        #expect(!line._testHighlightHidden)

        let rtlLine = makeLine(rtl: true)
        let rtlSweep = try #require(rtlLine._testSweepAnimation)
        let rtlFrom = try #require(rtlSweep.fromValue as? CGFloat)
        let rtlTo = try #require(rtlSweep.toValue as? CGFloat)
        #expect(rtlFrom > rtlTo, "RTL: mirrored")

        // Leaving the window (the cell scrolled off screen) stops the sweep.
        line.removeFromSuperview()
        #expect(!line._testIsSweeping)
        // Dismissing stops it.
        rtlLine.dismiss()
        #expect(!rtlLine._testIsSweeping)
    }
}
