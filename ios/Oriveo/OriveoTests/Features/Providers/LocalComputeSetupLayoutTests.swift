import SwiftUI
import Testing
import UIKit
@testable import Oriveo

@MainActor
@Suite("Local compute release layout", .serialized)
struct LocalComputeSetupLayoutTests {
    private static var retainedWindows: [UIWindow] = []

    private struct Scenario {
        let name: String
        let size: CGSize
        let language: LanguageOption
        let dynamicTypeSize: DynamicTypeSize
        let layoutDirection: LayoutDirection
        let colorScheme: ColorScheme
        let reduceMotion: Bool
    }

    private struct ScrollMetric {
        let contentSize: CGSize
        let boundsSize: CGSize
        let frame: CGRect
    }

    @Test("small phone, AX5, RTL, dark mode, and keyboard-height layouts do not overflow horizontally")
    func representativeReleaseLayouts() {
        let scenarios = [
            Scenario(
                name: "small-phone-zh",
                size: CGSize(width: 320, height: 568),
                language: .chineseSimplified,
                dynamicTypeSize: .large,
                layoutDirection: .leftToRight,
                colorScheme: .light,
                reduceMotion: false
            ),
            Scenario(
                name: "pro-max-de-ax5-dark-reduce-motion",
                size: CGSize(width: 440, height: 956),
                language: .german,
                dynamicTypeSize: .accessibility5,
                layoutDirection: .leftToRight,
                colorScheme: .dark,
                reduceMotion: true
            ),
            Scenario(
                name: "split-view-ar-rtl-ax5",
                size: CGSize(width: 375, height: 1024),
                language: .arabic,
                dynamicTypeSize: .accessibility5,
                layoutDirection: .rightToLeft,
                colorScheme: .light,
                reduceMotion: true
            ),
            Scenario(
                name: "keyboard-visible-en",
                size: CGSize(width: 393, height: 420),
                language: .english,
                dynamicTypeSize: .large,
                layoutDirection: .leftToRight,
                colorScheme: .light,
                reduceMotion: false
            ),
        ]

        for scenario in scenarios {
            let metrics = render(scenario)
            #expect(!metrics.isEmpty, "\(scenario.name): no UIScrollView was rendered")
            #expect(
                metrics.contains { $0.contentSize.height > $0.boundsSize.height + 40 },
                "\(scenario.name): the setup form is not vertically reachable: \(describe(metrics))"
            )
            for metric in metrics {
                #expect(
                    metric.contentSize.width <= metric.boundsSize.width + 0.5,
                    "\(scenario.name): horizontal overflow: \(describe(metrics))"
                )
                #expect(
                    metric.frame.minX >= -0.5 && metric.frame.maxX <= scenario.size.width + 0.5,
                    "\(scenario.name): scroll container escaped the viewport: \(describe(metrics))"
                )
            }
        }
    }

    private func render(_ scenario: Scenario) -> [ScrollMetric] {
        var preferences = AppPreferencesStore.load()
        let originalLanguage = preferences.language
        preferences.language = scenario.language
        AppPreferencesStore.save(preferences)
        L10n.invalidateCache()
        defer {
            var restored = AppPreferencesStore.load()
            restored.language = originalLanguage
            AppPreferencesStore.save(restored)
            L10n.invalidateCache()
        }

        let root = NavigationStack {
            RelaySetupView(entryPoint: .providers, initialMethod: .local)
        }
        .environment(AppState.preview)
        .environment(\.dynamicTypeSize, scenario.dynamicTypeSize)
        .environment(\.layoutDirection, scenario.layoutDirection)
        .environment(\.colorScheme, scenario.colorScheme)
        .transaction { transaction in
            if scenario.reduceMotion {
                transaction.disablesAnimations = true
            }
        }

        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(origin: .zero, size: scenario.size))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds

        for _ in 0..<8 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }

        var metrics: [ScrollMetric] = []
        collectScrollViews(host.view, relativeTo: window, into: &metrics)
        window.isHidden = true
        Self.retainedWindows.append(window)
        return metrics
    }

    private func collectScrollViews(
        _ view: UIView,
        relativeTo window: UIWindow,
        into metrics: inout [ScrollMetric]
    ) {
        if let scrollView = view as? UIScrollView {
            metrics.append(ScrollMetric(
                contentSize: scrollView.contentSize,
                boundsSize: scrollView.bounds.size,
                frame: scrollView.convert(scrollView.bounds, to: window)
            ))
        }
        for subview in view.subviews {
            collectScrollViews(subview, relativeTo: window, into: &metrics)
        }
    }

    private func describe(_ metrics: [ScrollMetric]) -> String {
        metrics.map {
            "content=\($0.contentSize), bounds=\($0.boundsSize), frame=\($0.frame)"
        }.joined(separator: "; ")
    }
}
