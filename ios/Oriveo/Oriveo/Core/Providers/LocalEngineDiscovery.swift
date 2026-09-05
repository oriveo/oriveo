import Foundation
import Network
import Observation

nonisolated struct LocalEngineDiscoveryResult: Equatable, Sendable {
    let endpoint: String
    let source: String
}

nonisolated enum LocalEngineDiscoveryState: Equatable, Sendable {
    case noService
    case permissionDenied
    case unavailable
}

/// Monotonic identity for the currently usable network path.
/// A Local verification is valid only on the path that produced it. The monitor intentionally
/// does not expose addresses or interface names: consumers need an invalidation boundary, not
/// network details that could leak into UI or telemetry.
@MainActor
@Observable
final class LocalNetworkRevisionMonitor {
    private(set) var revision: UInt = 0
    private var monitor: NWPathMonitor?

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.revision &+= 1
            }
        }
        self.monitor = monitor
        monitor.start(queue: DispatchQueue(label: "com.oriveo.local-network-revision", qos: .utility))
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    /// Tests and lifecycle adapters use the same production mutation as NWPathMonitor.
    func recordPathChange() {
        revision &+= 1
    }
}

nonisolated private final class DiscoveryContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let connection: NWConnection
    private let continuation: CheckedContinuation<LocalEngineDiscoveryResult?, Never>

    init(connection: NWConnection, continuation: CheckedContinuation<LocalEngineDiscoveryResult?, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ value: LocalEngineDiscoveryResult?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        connection.cancel()
        continuation.resume(returning: value)
    }
}

/// User-triggered, cancellable LAN discovery. Results remain in memory and are never uploaded.
final class LocalEngineDiscoverySession: @unchecked Sendable {
    static let uploadsResults = false
    private let lock = NSLock()
    private var browsers: [NWBrowser] = []
    private var connections: [NWConnection] = []
    private var scanTask: Task<Void, Never>?

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !browsers.isEmpty || scanTask != nil
    }

    func start(
        knownHosts: [String] = [],
        onResult: @escaping @Sendable (LocalEngineDiscoveryResult) -> Void,
        onState: @escaping @Sendable (LocalEngineDiscoveryState) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {
        cancel()
        let types = ["_http._tcp", "_ollama._tcp", "_llamacpp._tcp", "_lmstudio._tcp", "_open-webui._tcp"]
        let created = types.map { type -> NWBrowser in
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            browser.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    onState(Self.discoveryState(for: error))
                case .waiting(let error):
                    if Self.discoveryState(for: error) == .permissionDenied {
                        onState(.permissionDenied)
                    }
                default:
                    break
                }
            }
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case .service = result.endpoint else { continue }
                    let connection = NWConnection(to: result.endpoint, using: .tcp)
                    connection.stateUpdateHandler = { [weak connection] state in
                        guard state == .ready,
                              case .hostPort(let host, let port)? = connection?.currentPath?.remoteEndpoint else { return }
                        onResult(.init(endpoint: "http://\(host):\(port.rawValue)", source: "mdns"))
                        connection?.cancel()
                    }
                    self.lock.lock()
                    self.connections.append(connection)
                    self.lock.unlock()
                    connection.start(queue: .global(qos: .utility))
                }
            }
            browser.start(queue: .global(qos: .utility))
            return browser
        }
        lock.lock()
        browsers = created
        scanTask = Task {
            async let portScan: Void = Self.scanKnownPorts(hosts: knownHosts, onResult: onResult)
            try? await Task.sleep(for: .seconds(6))
            _ = await portScan
            guard !Task.isCancelled else { return }
            onState(.noService)
            onComplete()
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let currentBrowsers = browsers
        browsers = []
        let currentConnections = connections
        connections = []
        let task = scanTask
        scanTask = nil
        lock.unlock()
        currentBrowsers.forEach { $0.cancel() }
        currentConnections.forEach { $0.cancel() }
        task?.cancel()
    }

    deinit { cancel() }

    nonisolated static func discoveryState(for error: NWError) -> LocalEngineDiscoveryState {
        if case .posix(let code) = error, code == .EPERM || code == .EACCES {
            return .permissionDenied
        }
        let diagnostic = String(describing: error).lowercased()
        if diagnostic.contains("policy") || diagnostic.contains("permission") || diagnostic.contains("denied") {
            return .permissionDenied
        }
        return .unavailable
    }

    private static func scanKnownPorts(
        hosts: [String],
        onResult: @escaping @Sendable (LocalEngineDiscoveryResult) -> Void
    ) async {
        let candidates = hosts.flatMap { host in [8080, 11434, 1234, 8000, 3000].map { (host, $0) } }
        await withTaskGroup(of: LocalEngineDiscoveryResult?.self) { group in
            for (host, port) in candidates {
                group.addTask {
                    guard !Task.isCancelled, let url = URL(string: "http://\(host):\(port)") else { return nil }
                    let connection = NWConnection(host: NWEndpoint.Host(url.host!), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
                    return await withTaskCancellationHandler {
                        await withCheckedContinuation { continuation in
                            let gate = DiscoveryContinuationGate(connection: connection, continuation: continuation)
                            connection.stateUpdateHandler = { state in
                                switch state {
                                case .ready: gate.finish(.init(endpoint: url.absoluteString, source: "known_port"))
                                case .failed, .cancelled: gate.finish(nil)
                                default: break
                                }
                            }
                            connection.start(queue: .global(qos: .utility))
                            DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { gate.finish(nil) }
                        }
                    } onCancel: { connection.cancel() }
                }
            }
            for await result in group {
                if let result { onResult(result) }
            }
        }
    }
}
