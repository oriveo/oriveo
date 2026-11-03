import Combine
import CoreFoundation
import Foundation
import QuartzCore
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Fake voice seam that can write five samples: the level is rewritten by the test at 15 Hz, going through production VoiceConversationBar → ObservedVoiceConversationBar.
private final class PerfFakeSurface: VoiceConversationSurface {
    let objectWillChange = ObservableObjectPublisher()
    var statusKey: VoiceConversationLogic.StatusKey? = .listening { willSet { objectWillChange.send() } }
    var displayState: VoiceConversationLogic.DisplayState? = .listening { willSet { objectWillChange.send() } }
    var level: Double = 0 { willSet { objectWillChange.send() } }
    func tapOrb() {}
    func toggleMute() {}
}

/// Frame time is recorded from the difference between adjacent CADisplayLink timestamps.
@MainActor
private final class FrameRecorder: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private(set) var deltas: [CFTimeInterval] = []
    private(set) var durations: [CFTimeInterval] = []

    func start() {
        last = nil
        deltas = []
        durations = []
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        if let last {
            deltas.append(link.timestamp - last)
            durations.append(link.duration)
        }
        last = link.timestamp
    }
}

/// Main-thread busy time: cumulative time from afterWaiting to beforeWaiting in a CFRunLoopObserver.
@MainActor
private final class MainThreadBusyMeter {
    private var observer: CFRunLoopObserver?
    private var wokeAt: CFTimeInterval?
    private(set) var busy: CFTimeInterval = 0

    func start() {
        busy = 0
        wokeAt = CACurrentMediaTime()
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.handle(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func stop() {
        if let wokeAt { busy += CACurrentMediaTime() - wokeAt }
        wokeAt = nil
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }

    private func handle(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        if activity == .afterWaiting {
            wokeAt = now
        } else if activity == .beforeWaiting, let wokeAt {
            busy += now - wokeAt
            self.wokeAt = nil
        }
    }
}

/// Measurement result for one state.
private struct StagePerfSample: Encodable {
    let state: String
    let seconds: Double
    let frames: Int
    let fps: Double
    let refreshMs: Double
    let p50Ms: Double
    let p95Ms: Double
    let maxMs: Double
    let overBudgetFrames: Int
    let overBudgetRatio: Double
    let mainThreadMsPerFrame: Double
}

/// Render-cost proxy for a representative state (ms, median of 20 runs, no gate).
private struct StageRenderProxy: Encodable {
    let state: String
    let scale: Double
    let width: Double
    let height: Double
    let stageClock: Double
    /// Old approach: drawLayer per blob plus live blur.
    let fogBlurReferenceMs: Double
    /// Current approach: precomputed radial profile gradient (production VoiceOrbPaint.drawFogCircle).
    let fogGradientMs: Double
    /// Production VoiceOrbPaint.drawOrb.
    let orbMs: Double
}

private struct StagePerfReport: Encodable {
    let mode: String
    let secondsPerState: Double
    let levelFeedHz: Double
    let states: [StagePerfSample]
    let renderProxy: StageRenderProxy
}

/// Voice stage six-state frame time and main-thread per-frame cost (contract item 7): the production stage bar is mounted in a real window,
/// speaking and AI speaking loop the item 3 ladder at 15 Hz; over budget = adjacent frame difference > 1.5 × refresh interval (drops at least 1 frame).
@MainActor
@Suite("Voice stage six-state frame time", .serialized, .sharedProcessState)
struct VoiceStagePerfTests {
    private struct Stage {
        let name: String
        let status: VoiceConversationLogic.StatusKey
        let display: VoiceConversationLogic.DisplayState
        let feedsLevel: Bool
    }

    private static let stages: [Stage] = [
        Stage(name: "listening", status: .listening, display: .listening, feedsLevel: false),
        Stage(name: "userSpeaking", status: .caption, display: .userSpeaking, feedsLevel: true),
        Stage(name: "thinking", status: .thinking, display: .thinking, feedsLevel: false),
        Stage(name: "speaking", status: .speaking, display: .speaking, feedsLevel: true),
        Stage(name: "sayAgain", status: .sayAgain, display: .sayAgain, feedsLevel: false),
        Stage(name: "muted", status: .muted, display: .muted, feedsLevel: false),
    ]

    /// Contract item 3 ladder.
    private static let staircase: [Double] = [0.2, 0.6, 0.3, 0.8, 0.5, 0.9, 0.4, 0.7, 0.2, 0, 0.5, 1, 0.6, 0.1]
    private static let feedHz = 15.0

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))
        return sorted[index]
    }

    private static func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    /// Render-cost proxy (measured only on the representative "AI speaking" state): an ImageRenderer with a 390 × 366 Canvas at scale 3,
    /// calls production VoiceOrbPaint fog and orb drawing directly, using the frame of that state frozen at 1.3 s; a new renderer each time, median of 20 runs, recorded but not gated.
    /// Also draws the old approach (drawLayer per blob plus live blur) as a control. Each run asserts an image was produced and that the fog and orb center pixels differ from the background.
    /// Note: CADisplayLink can only measure main-thread callbacks; render server and GPU cost needs a real device with Instruments, already in the post-wake checklist.
    private static func renderProxy() throws -> StageRenderProxy {
        let mode = VoiceOrbMode.ai, level = 0.6, time = 1.3, scale = 3.0
        let panel = CGSize(width: 390, height: Double(VoiceConversationBarContent.stageContentHeight))
        let fog = VoiceOrbMath.fogFrame(panelSize: panel, bottomInset: 34)
        let energy = VoiceOrbMath.stageEnergy(mode: mode, level: level, time: time)
        let drift = VoiceOrbMath.fogDrift(time: time, reduceMotion: false)
        let circles = VoiceOrbMath.fogCircles(mode: mode, energy: energy, dark: false, notice: false)
        let fogPanelWidth = Double(fog.width) - 2 * VoiceOrbMath.fogBleed
        let centers: [CGPoint] = circles.indices.map { i in
            let c = VoiceOrbMath.fogCenter(index: i, panelWidth: fogPanelWidth, drift: drift)
            return CGPoint(
                x: Double(fog.minX) + VoiceOrbMath.fogBleed + Double(c.x),
                y: Double(fog.minY) + Double(c.y)
            )
        }
        let bg = VoiceOrbMath.RGB(hex: 0xF4F5F8)
        let bgColor = Color(.sRGB, red: bg.red, green: bg.green, blue: bg.blue)

        func canvas(_ body: @escaping (inout GraphicsContext, CGSize) -> Void) -> some View {
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(bgColor))
                body(&ctx, size)
            }
            .frame(width: panel.width, height: panel.height)
        }
        let blurFog = canvas { ctx, _ in
            for (i, c) in circles.enumerated() {
                let d = c.diameter, p = centers[i], rgb = VoiceOrbMath.RGB(hex: c.color)
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: VoiceOrbMath.blurRadius(sigma: c.blur)))
                    layer.fill(
                        Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)),
                        with: .color(Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: c.alpha))
                    )
                }
            }
        }
        let gradientFog = canvas { ctx, _ in
            for (i, c) in circles.enumerated() {
                VoiceOrbPaint.drawFogCircle(
                    in: ctx, center: centers[i], color: VoiceOrbMath.RGB(hex: c.color), alpha: c.alpha,
                    diameter: c.diameter, sigma: c.blur
                )
            }
        }
        let frame = VoiceOrbAnimator.stageFrame(time: time, mode: mode, level: level)
        let unit = VoiceOrbMath.unit(size: Double(VoiceConversationBarContent.orbSize))
        let orb = canvas { ctx, size in
            VoiceOrbPaint.drawOrb(
                in: &ctx, canvasSize: size, unit: unit, frame: frame, palette: (from: true, mix: 1), mode: mode, dark: false
            )
        }

        /// Times one render; after the image is produced (untimed), checks that the probe point pixel differs from the background.
        func median(_ name: String, _ view: some View, probe: CGPoint) throws -> Double {
            func once() throws -> Double {
                let renderer = ImageRenderer(content: view)
                renderer.scale = scale
                // cgImage may rasterize lazily (first pixel access actually draws it); timing includes forcing the full bitmap data out.
                let begin = CACurrentMediaTime()
                let rendered = renderer.cgImage
                let bytes = rendered?.dataProvider?.data.map { CFDataGetLength($0) } ?? 0
                let ms = (CACurrentMediaTime() - begin) * 1000
                let image = try #require(rendered, "\(name) produced no image")
                #expect(bytes >= image.bytesPerRow * image.height, "\(name) bitmap data \(bytes) bytes")
                #expect(image.width == Int(panel.width * scale) && image.height == Int(panel.height * scale), "\(name) size \(image.width)×\(image.height)")
                let pixel = try #require(Self.pixel(image, x: Int(probe.x * scale), y: Int(probe.y * scale)), "\(name) could not read pixel")
                let diff = zip(pixel, [bg.red, bg.green, bg.blue]).map { abs($0 - $1 * 255) }.max() ?? 0
                #expect(diff > 3, "\(name) at (\(probe.x), \(probe.y)) is almost the same as the background: \(pixel)")
                return ms
            }
            _ = try once()
            let times = try (0..<20).map { _ in try once() }.sorted()
            return (times[9] + times[10]) / 2
        }
        let orbCenter = CGPoint(x: panel.width / 2, y: panel.height / 2)
        return StageRenderProxy(
            state: "speaking", scale: scale, width: Double(panel.width), height: Double(panel.height), stageClock: time,
            fogBlurReferenceMs: round3(try median("blurFog", blurFog, probe: centers[0])),
            fogGradientMs: round3(try median("gradientFog", gradientFog, probe: centers[0])),
            orbMs: round3(try median("orb", orb, probe: orbCenter))
        )
    }

    /// RGB of one pixel (0-255, opaque over a non-premultiplied background).
    private static func pixel(_ image: CGImage, x: Int, y: Int) -> [Double]? {
        guard let one = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes.prefix(3).map(Double.init)
    }

    private func yieldMainActor(for seconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Mounts in a window and measures per state; returns the result for each state.
    private func measure(secondsPerState: TimeInterval) async throws -> [StagePerfSample] {
        let surface = PerfFakeSurface()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: VoiceConversationBar(surface: surface, page: .chat, onEnd: {}))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: scene.screen.bounds.size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await yieldMainActor(for: 1.0)

        var samples: [StagePerfSample] = []
        for stage in Self.stages {
            surface.statusKey = stage.status
            surface.displayState = stage.display
            surface.level = 0
            // The state transition (200 ms easing) is excluded from the steady state.
            try await yieldMainActor(for: 0.5)

            let frames = FrameRecorder()
            let meter = MainThreadBusyMeter()
            frames.start()
            meter.start()
            let begin = CACurrentMediaTime()
            let end = begin + secondsPerState
            var step = 0
            while CACurrentMediaTime() < end {
                if stage.feedsLevel {
                    surface.level = Self.staircase[step % Self.staircase.count]
                    step += 1
                    let next = begin + Double(step) / Self.feedHz
                    let wait = max(0, next - CACurrentMediaTime())
                    try await Task.sleep(for: .milliseconds(Int((wait * 1000).rounded())))
                } else {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            let elapsed = CACurrentMediaTime() - begin
            meter.stop()
            frames.stop()

            let deltas = frames.deltas
            let refresh = frames.durations.sorted().dropFirst(frames.durations.count / 2).first ?? (1.0 / 60)
            let over = zip(deltas, frames.durations).filter { $0 > 1.5 * $1 }.count
            let sortedMs = deltas.map { $0 * 1000 }.sorted()
            let frameCount = deltas.count
            samples.append(StagePerfSample(
                state: stage.name,
                seconds: Self.round3(elapsed),
                frames: frameCount,
                fps: Self.round3(Double(frameCount) / elapsed),
                refreshMs: Self.round3(refresh * 1000),
                p50Ms: Self.round3(Self.percentile(sortedMs, 0.5)),
                p95Ms: Self.round3(Self.percentile(sortedMs, 0.95)),
                maxMs: Self.round3(sortedMs.last ?? 0),
                overBudgetFrames: over,
                overBudgetRatio: frameCount == 0 ? 0 : Self.round3(Double(over) / Double(frameCount)),
                mainThreadMsPerFrame: frameCount == 0 ? 0 : Self.round3(meter.busy * 1000 / Double(frameCount))
            ))
        }
        return samples
    }

    private func report(_ samples: [StagePerfSample], mode: String, seconds: Double) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let proxy = try Self.renderProxy()
        let data = try encoder.encode(StagePerfReport(
            mode: mode, secondsPerState: seconds, levelFeedHz: Self.feedHz, states: samples, renderProxy: proxy
        ))
        print("VOICE_STAGE_PERF \(String(decoding: data, as: UTF8.self))")
        return data
    }

    @Test("Each of six states for 30 s: over-budget frames ≤ 1% per state, results written to voice-stage-perf.json")
    func sixStatesThirtySeconds() async throws {
        let samples = try await measure(secondsPerState: 30)
        let data = try report(samples, mode: "sixStatesThirtySeconds", seconds: 30)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voice-stage-perf.json")
        try data.write(to: url)
        print("VOICE_STAGE_PERF_FILE \(url.path)")
        #expect(samples.map(\.state) == Self.stages.map(\.name))
        for sample in samples {
            #expect(sample.frames > 0, "\(sample.state) has no frames")
            #expect(sample.overBudgetRatio <= 0.01, "\(sample.state) over budget \(sample.overBudgetFrames)/\(sample.frames)")
        }
    }

    @Test("Each of six states for 2 s: each state has frames (daily regression)")
    func sixStatesQuick() async throws {
        let samples = try await measure(secondsPerState: 2)
        _ = try report(samples, mode: "sixStatesQuick", seconds: 2)
        #expect(samples.map(\.state) == Self.stages.map(\.name))
        for sample in samples {
            #expect(sample.frames > 0, "\(sample.state) has no frames")
        }
    }
}
