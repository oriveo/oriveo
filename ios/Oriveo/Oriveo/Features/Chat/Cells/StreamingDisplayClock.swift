import UIKit

@MainActor
final class StreamingDisplayClock {
    typealias SubscriberToken = UUID
    typealias Tick = (CFTimeInterval) -> Void

    private var displayLink: CADisplayLink?
    private var subscribers: [SubscriberToken: Tick] = [:]

    var isRunning: Bool { displayLink != nil }

    func addSubscriber(_ tick: @escaping Tick) -> SubscriberToken {
        let token = SubscriberToken()
        subscribers[token] = tick
        return token
    }

    func removeSubscriber(_ token: SubscriberToken) {
        subscribers.removeValue(forKey: token)
        if subscribers.isEmpty {
            pause()
        }
    }

    func resume() {
        guard displayLink == nil, !subscribers.isEmpty else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func pause() {
        displayLink?.invalidate()
        displayLink = nil
    }

    nonisolated deinit {}

    @objc private func tick(_ link: CADisplayLink) {
        let ts = link.timestamp
        for tick in Array(subscribers.values) {
            tick(ts)
        }
    }
}
