import Foundation

/// Production BYOK transport over `StudioBackgroundTransfer`: each attempt is uploaded through the
/// background session under its job id, awaited until the job settles, then read and its job
/// directory removed. A deadline under the session's 180 s resource cap cancels the job and replies
/// timed out; cancelling the calling task cancels the job and replies cancelled. URL images are
/// downloaded into the job directory and rechecked against the same 30 MB cap and 60 s
/// whole-download timeout as `StudioImageFetcher`. File IO and enqueueing run off the main actor.
nonisolated struct StudioBackgroundByokTransport: StudioByokTransport {
    let transfer: StudioBackgroundTransfer
    let maxImageBytes: Int
    /// Whole-download deadline of one URL image.
    let imageTimeoutSeconds: TimeInterval

    init(
        transfer: StudioBackgroundTransfer,
        maxImageBytes: Int = StudioImageFetcher.Policy.maxBytes,
        imageTimeoutSeconds: TimeInterval = StudioImageFetcher.Policy.timeoutSeconds
    ) {
        self.transfer = transfer
        self.maxImageBytes = maxImageBytes
        self.imageTimeoutSeconds = imageTimeoutSeconds
    }

    /// Reply code when the attempt never left the device (enqueue or encoding failed): a
    /// pre_connect code of `StudioByokTasks.transportPhase`.
    static let notSentCode = URLError.Code.cannotConnectToHost.rawValue

    private static let cancelledCode = URLError.Code.cancelled.rawValue
    private static let timedOutCode = URLError.Code.timedOut.rawValue

    // MARK: Encoding

    /// The built request as a `URLRequest` plus the body to upload from a file. A multipart body
    /// is encoded here and its boundary set in Content-Type. Nil when the URL or a JSON value is
    /// not encodable.
    static func encode(
        _ request: ImageRequestBuilder.Request,
        boundary: String = "oriveo-\(UUID().uuidString)"
    ) -> (request: URLRequest, body: Data)? {
        guard let url = URL(string: request.url), url.scheme != nil else { return nil }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let body: Data
        switch request.body {
        case .json(let object):
            let value = object.mapValues(foundationValue)
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            else { return nil }
            body = data
        case .multipart(let fields, let files):
            body = multipartBody(fields: fields, files: files, boundary: boundary)
            urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        }
        return (urlRequest, body)
    }

    private static func foundationValue(_ value: ImageRequestBuilder.JSONValue) -> Any {
        switch value {
        case .string(let string): return string
        case .number(let number): return number
        case .bool(let bool): return bool
        case .object(let object): return object.mapValues(foundationValue)
        case .array(let array): return array.map(foundationValue)
        case .null: return NSNull()
        }
    }

    private static func multipartBody(
        fields: [ImageRequestBuilder.MultipartField],
        files: [ImageRequestBuilder.MultipartFile],
        boundary: String
    ) -> Data {
        var data = Data()
        for field in fields {
            data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(quoted(field.name))\"\r\n\r\n".utf8))
            data.append(Data(field.value.utf8))
            data.append(Data("\r\n".utf8))
        }
        for file in files {
            data.append(Data((
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(quoted(file.name))\"; "
                    + "filename=\"\(quoted(file.filename))\"\r\nContent-Type: \(quoted(file.mime))\r\n\r\n"
            ).utf8))
            data.append(file.data)
            data.append(Data("\r\n".utf8))
        }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }

    /// Header parameter text: no line breaks, double quotes percent-encoded.
    private static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\"", with: "%22")
    }

    // MARK: Transport

    /// received → (status, response.body), or oversized when response.body is larger than
    /// `maxResponseBytes` (checked by file size, never read); failed(code) → failure(code); the
    /// deadline → timed out; task cancellation → cancelled. The job directory is removed after the
    /// reply is read, and also when the upload cannot be enqueued.
    @concurrent
    func send(
        _ request: ImageRequestBuilder.Request, jobId: String, timeoutSeconds: Int, maxResponseBytes: Int = .max
    ) async -> StudioByokReply {
        if Task.isCancelled { return .failure(urlErrorCode: Self.cancelledCode) }
        guard let encoded = Self.encode(request) else { return .failure(urlErrorCode: Self.notSentCode) }
        guard transfer.enqueueUpload(jobId: jobId, request: encoded.request, body: encoded.body) else {
            // A failed enqueue may leave a partly prepared job directory behind.
            transfer.removeJob(jobId: jobId)
            return .failure(urlErrorCode: Self.notSentCode)
        }

        let deadline = Flag()
        let timer: Task<Void, Never>? = timeoutSeconds < Int(StudioBackgroundTransfer.resourceTimeout)
            ? Task { [transfer] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard !Task.isCancelled else { return }
                deadline.set()
                transfer.cancel(jobId: jobId)
            }
            : nil
        let record = await withTaskCancellationHandler {
            await transfer.waitForTerminal(jobId: jobId)
        } onCancel: { [transfer] in
            transfer.cancel(jobId: jobId)
        }
        timer?.cancel()
        defer { transfer.removeJob(jobId: jobId) }

        if Task.isCancelled { return .failure(urlErrorCode: Self.cancelledCode) }
        if record?.state == .received {
            guard let status = record?.httpStatus else {
                return .failure(urlErrorCode: URLError.Code.badServerResponse.rawValue)
            }
            let bodyURL = transfer.store.responseBodyURL(jobId: jobId)
            if let size = (try? FileManager.default.attributesOfItem(atPath: bodyURL.path))?[.size] as? NSNumber,
               size.intValue > maxResponseBytes {
                return .oversized(status: status, byteCount: size.intValue)
            }
            let body = (try? Data(contentsOf: bodyURL)) ?? Data()
            return .response(status: status, body: body)
        }
        if deadline.isSet { return .failure(urlErrorCode: Self.timedOutCode) }
        if case .failed(let code)? = record?.state { return .failure(urlErrorCode: code) }
        // Interrupted or no record: the outcome is unknown, so the attempt counts as sent.
        return .failure(urlErrorCode: URLError.Code.unknown.rawValue)
    }

    /// http / https only (else decode_failed, as the foreground fetcher). The download lands in
    /// `downloads/<index>`; over `maxImageBytes` → decode_failed; otherwise decoded for mime and
    /// size. Not finished within `imageTimeoutSeconds` → the job is cancelled and the reply is
    /// timeout, as is a download the session timed out; any other failure → network. The job
    /// directory is removed after the image is read.
    @concurrent
    func fetchImage(_ url: URL, jobId: String, index: Int) async -> Result<StudioImageResponse.Materialized, StudioImageResponse.Failure> {
        guard let scheme = url.scheme?.lowercased(), StudioImageFetcher.Policy.schemes.contains(scheme) else {
            return .failure(.decodeFailed)
        }
        if Task.isCancelled { return .failure(.network) }
        guard transfer.enqueueDownload(jobId: jobId, url: url, index: index) else { return .failure(.network) }
        let deadline = Flag()
        let timer = Task { [transfer, imageTimeoutSeconds] in
            try? await Task.sleep(for: .seconds(imageTimeoutSeconds))
            guard !Task.isCancelled else { return }
            deadline.set()
            transfer.cancel(jobId: jobId)
        }
        let record = await withTaskCancellationHandler {
            await transfer.waitForTerminal(jobId: jobId)
        } onCancel: { [transfer] in
            transfer.cancel(jobId: jobId)
        }
        timer.cancel()
        defer { transfer.removeJob(jobId: jobId) }

        if Task.isCancelled { return .failure(.network) }
        switch record?.state {
        case .received?:
            return Self.readImage(at: transfer.store.downloadURL(jobId: jobId, index: index), maxBytes: maxImageBytes)
        case _ where deadline.isSet:
            return .failure(.timeout)
        case .failed(let code)? where code == Self.timedOutCode:
            return .failure(.timeout)
        default:
            return .failure(.network)
        }
    }

    private static func readImage(at url: URL, maxBytes: Int) -> Result<StudioImageResponse.Materialized, StudioImageResponse.Failure> {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
            return .failure(.network)
        }
        guard size.intValue <= maxBytes else { return .failure(.decodeFailed) }
        guard let bytes = try? Data(contentsOf: url) else { return .failure(.network) }
        return StudioImageResponse.materialized(bytes)
    }

    /// One-way flag shared with the deadline timer.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}
