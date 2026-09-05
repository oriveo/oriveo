import Foundation
import Network
import Observation

/// Watches the device network path so the UI can tell "you are offline" apart from
/// "the provider rejected the request".
@Observable
@MainActor
final class ServiceReachabilityMonitor {
    static let shared = ServiceReachabilityMonitor()

    enum State: Equatable {
        case online
        case noNetwork
    }

    private(set) var state: State = .online

    /// Mirrors `state` but returns to `.online` once the user dismisses the banner,
    /// so a single outage cannot keep re-showing it.
    private(set) var bannerState: State = .online

    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private let pathQueue = DispatchQueue(
        label: "com.oriveo.reachability.path",
        qos: .utility
    )
    @ObservationIgnored private var pathSatisfied = true
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var currentStateInstance: UInt64 = 0
    @ObservationIgnored private var dismissedStateInstance: UInt64?

    private init() {}

    #if DEBUG
    static func makeForTesting() -> ServiceReachabilityMonitor {
        ServiceReachabilityMonitor()
    }

    func applyPathSatisfiedForTesting(_ satisfied: Bool) {
        applyPathSatisfied(satisfied)
    }
    #endif

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let monitor = self else { return }
            let satisfied = path.status == .satisfied
            Task { @MainActor [monitor] in
                monitor.applyPathSatisfied(satisfied)
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    func dismissCurrentBanner() {
        dismissedStateInstance = currentStateInstance
        bannerState = .online
    }

    private func applyPathSatisfied(_ satisfied: Bool) {
        pathSatisfied = satisfied
        let next: State = satisfied ? .online : .noNetwork
        guard next != state else { return }
        state = next
        currentStateInstance &+= 1
        bannerState = nextBannerState(for: next)
    }

    private func nextBannerState(for state: State) -> State {
        guard state == .noNetwork else { return .online }
        return dismissedStateInstance == currentStateInstance ? .online : state
    }
}
