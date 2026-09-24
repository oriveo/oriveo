import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// In the notes list the whole card is a Button and the tag chips sit in its label (NotesView → NoteCard). When the
/// chip attached `onTapGesture` whether or not it had a tap action, the child's tap gesture won over the outer Button,
/// so a tap on a tag was taken by an empty gesture and the note did not open.
///
/// These tests put the view in a real window and tap it with a synthesized touch (the same hit testing and gesture
/// arbitration path as a finger) to see who takes the tap.
@Suite("NoteTagChip hit testing", .serialized)
@MainActor
struct NoteTagChipHitTests {
    @Observable
    final class Counter {
        var card = 0
        var chip = 0
    }

    /// Same shape as the notes list: `Button { open the note } label: { … chip … }.buttonStyle(.plain)`.
    /// Pinned to the window's top left: the button is 320×120 and the chip sits at the 40pt leading inset, vertically
    /// centered.
    private struct CardHarness: View {
        let counter: Counter
        let chipHasTap: Bool

        var body: some View {
            Button {
                counter.card += 1
            } label: {
                HStack(spacing: 0) {
                    chip
                    Spacer(minLength: 0)
                }
                .padding(40)
                .frame(width: 320, height: 120)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
        }

        @ViewBuilder
        private var chip: some View {
            if chipHasTap {
                NoteTagChip(
                    tag: "Tag",
                    brand: .purple,
                    hasSource: false,
                    onTap: { counter.chip += 1 }
                )
            } else {
                NoteTagChip(tag: "Tag", brand: .purple, hasSource: false)
            }
        }
    }

    /// On the chip's leading icon (the chip starts at x 40, is about 27pt tall and centered on y 60).
    private let onChip = CGPoint(x: 52, y: 60)
    /// Empty space on the right of the card, away from the chip.
    private let offChip = CGPoint(x: 290, y: 60)

    @Test("Self check: a synthesized tap on empty card space reaches the outer Button")
    func syntheticTouchReachesTheCardButton() async throws {
        let counter = Counter()
        let window = try await present(CardHarness(counter: counter, chipHasTap: false))
        defer { dismiss(window) }

        try await SyntheticTouch.tap(at: offChip, in: window)
        try await settle()
        #expect(counter.card == 1, "the synthesized touch did not trigger a plain SwiftUI Button; the other tests cannot be trusted")
    }

    @Test("A chip without a tap action does not swallow the tap: tapping the tag opens the note")
    func chipWithoutTapLetsTheCardReceiveTheTap() async throws {
        let counter = Counter()
        let window = try await present(CardHarness(counter: counter, chipHasTap: false))
        defer { dismiss(window) }

        try await SyntheticTouch.tap(at: onChip, in: window)
        try await settle()
        #expect(counter.card == 1, "tapping a read-only tag did not reach the outer card")
    }

    @Test("A chip with a tap action handles the tap itself and does not trigger the outer card")
    func chipWithTapHandlesItsOwnTap() async throws {
        let counter = Counter()
        let window = try await present(CardHarness(counter: counter, chipHasTap: true))
        defer { dismiss(window) }

        try await SyntheticTouch.tap(at: onChip, in: window)
        try await settle()
        #expect(counter.chip == 1)
        #expect(counter.card == 0)
    }

    // MARK: - Helpers

    private func present<V: View>(_ view: V) async throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has no window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(600))
        return window
    }

    private func dismiss(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(400))
    }
}
