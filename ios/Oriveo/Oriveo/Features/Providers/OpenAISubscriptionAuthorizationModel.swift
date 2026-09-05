import Foundation

@MainActor
@Observable
final class OpenAISubscriptionAuthorizationModel {
    enum Phase: Equatable {
        case idle
        case requesting
        case awaitingAuthorization(OpenAIDeviceAuthorization)
        case succeeded(OpenAISubscriptionTokens)
        case failed(OpenAISubscriptionError)
    }

    private(set) var phase: Phase = .idle
    private(set) var didOpenVerificationPage = false

    private var pollTask: Task<Void, Never>?
    private let client: OpenAISubscriptionOAuthClient

    init(client: OpenAISubscriptionOAuthClient = OpenAISubscriptionOAuthClient()) {
        self.client = client
    }

    var deviceAuthorization: OpenAIDeviceAuthorization? {
        if case let .awaitingAuthorization(authorization) = phase { return authorization }
        return nil
    }

    var isBusy: Bool {
        switch phase {
        case .requesting, .awaitingAuthorization: return true
        case .idle, .succeeded, .failed: return false
        }
    }

    func markVerificationPageOpened() {
        didOpenVerificationPage = true
    }

    func start(config: OpenAISubscriptionAuthConfig) {
        pollTask?.cancel()
        didOpenVerificationPage = false
        phase = .requesting

        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let authorization = try await client.requestDeviceAuthorization(config: config)
                if Task.isCancelled { return }
                phase = .awaitingAuthorization(authorization)
                await poll(config: config, authorization: authorization)
            } catch let error as OpenAISubscriptionError {
                if Task.isCancelled { return }
                phase = .failed(error)
            } catch {
                if Task.isCancelled { return }
                phase = .failed(.transport(error.localizedDescription))
            }
        }
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        phase = .idle
        didOpenVerificationPage = false
    }

    private func poll(config: OpenAISubscriptionAuthConfig, authorization: OpenAIDeviceAuthorization) async {
        var interval = max(1, authorization.interval)
        let deadline = Date().addingTimeInterval(
            TimeInterval(min(authorization.expiresIn, config.pollTimeoutSeconds))
        )

        while !Task.isCancelled {
            if Date() >= deadline {
                phase = .failed(.codeExpired)
                return
            }
            try? await Task.sleep(for: .seconds(interval))
            if Task.isCancelled { return }

            do {
                let tokens = try await client.pollToken(
                    config: config,
                    deviceAuthID: authorization.deviceAuthID,
                    userCode: authorization.userCode
                )
                phase = .succeeded(tokens)
                return
            } catch OpenAISubscriptionError.authorizationPending {
                continue
            } catch OpenAISubscriptionError.slowDown {
                interval += 5
                continue
            } catch let error as OpenAISubscriptionError {
                if case .transport = error { continue }
                phase = .failed(error)
                return
            } catch {
                continue
            }
        }
    }
}
