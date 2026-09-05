import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Builds `URLSession`s with an explicit redirect policy.
///
/// By default `URLSession` follows a 30x and replays the original headers, which would hand a
/// user's `Authorization` header to whatever host the redirect names. Provider and metadata
/// requests carry API keys, so redirects are either refused outright or confined to the same
/// origin; the decision is never left to Foundation's default.
public enum ProviderURLSessionFactory {
    public enum RedirectPolicy: Sendable {
        case rejectAll
        case sameOriginOnly
    }

    public static func make(
        policy: RedirectPolicy,
        configuration: URLSessionConfiguration = .default
    ) -> URLSession {
        URLSession(
            configuration: configuration,
            delegate: RedirectDelegate(policy: policy),
            delegateQueue: nil
        )
    }

    public static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = origin(lhs), let right = origin(rhs) else { return false }
        return left == right
    }

    private static func origin(_ url: URL) -> Origin? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : (scheme == "http" ? 80 : -1))
        return Origin(scheme: scheme, host: host, port: port)
    }

    private struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int
    }

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let policy: RedirectPolicy

        init(policy: RedirectPolicy) { self.policy = policy }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            switch policy {
            case .rejectAll:
                completionHandler(nil)
            case .sameOriginOnly:
                guard let original = task.originalRequest?.url,
                      let redirected = request.url,
                      ProviderURLSessionFactory.isSameOrigin(original, redirected) else {
                    completionHandler(nil)
                    return
                }
                completionHandler(request)
            }
        }
    }
}
