import Foundation

/// How a message's attachments are finally delivered: which go as provider-native file parts, which are
/// extracted to text and appended to the body, and which are skipped for exceeding the model's text limit.
///
/// Request building and the "can this message be sent" check must consume the same result. If each computed
/// its own with slightly different inputs (one with the model, one without), the UI could say a message is
/// sendable while the request is missing files.
struct AttachmentDeliveryPlan {
    /// Attachments sent as provider-native file parts (in the order given).
    let native: [Attachment]
    /// The remaining attachments: files are extracted to text, images and videos are handled by each builder.
    let textPayload: [Attachment]
    /// Files over the text limit that did not make it into `injectedText`.
    let skipped: [(attachment: Attachment, reason: AttachmentInjector.SkipReason)]
    /// The user's text, each file's text block, and the image / video placeholders (plus [D]).
    let injectedText: String
}

enum AttachmentDelivery {

    /// - Parameters:
    ///   - transport: The outbound route's declaration: native file blocks or not, wrapper format, native threshold owner, image placeholder.
    ///   - model: Used to resolve the text limits (`FileExtractionLimits.resolve`) and the native allow-list; with nil the default limits apply and everything goes as text.
    ///   - fileInput: The file_input projection of an official connection; when its outbound is not native_part, every file goes through text injection.
    static func plan(
        userText: String,
        attachments: [Attachment],
        transport: AttachmentTransportProfile,
        model: AIModel?,
        fileInput: CapabilityEvidenceFacade.InputCapabilityProjection? = nil,
        dynamicText: String? = nil
    ) -> AttachmentDeliveryPlan {
        let (native, textPayload) = partition(
            attachments,
            provider: transport.provider,
            mode: NativeFileFallback.effectiveMode(of: transport),
            model: model,
            fileInput: fileInput
        )
        let (injectedText, skipped) = inject(
            userText: userText,
            attachments: textPayload,
            wrapper: transport.wrapper,
            model: model,
            imagePlaceholderText: transport.imagePlaceholderText,
            videoPlaceholderText: transport.videoPlaceholderText,
            dynamicText: dynamicText
        )
        return AttachmentDeliveryPlan(
            native: native,
            textPayload: textPayload,
            skipped: skipped,
            injectedText: injectedText
        )
    }

    /// Entry point for request building: same inputs and same result as `plan`. If a file in the message being
    /// sent cannot fit the text limit, the send is stopped here instead of going out with a body that is missing files.
    /// Skipped files in earlier messages are not blocked: they were not delivered in their own turn, and blocking
    /// now would make the whole conversation unsendable.
    static func deliver(
        isOutgoingTurn: Bool,
        userText: String,
        attachments: [Attachment],
        transport: AttachmentTransport,
        model: AIModel?,
        dynamicText: String? = nil
    ) throws -> AttachmentDeliveryPlan {
        #if DEBUG
        AttachmentDeliveryObservation.onDeliver?(transport)
        #endif
        let plan = plan(
            userText: userText,
            attachments: attachments,
            transport: transport.profile,
            model: model,
            dynamicText: dynamicText ?? AttachmentDynamicTurn.current
        )
        if isOutgoingTurn, let error = overLimitError(for: plan, model: model) {
            throw error
        }
        // Fallback-capable route: record the native files this request carries, to decide whether to resend as text if the upstream rejects it.
        if !plan.native.isEmpty, transport.profile.effectiveNativeFiles == .alwaysWithTextFallback {
            NativeFileFallback.currentAttempt?.recordNativeFiles(plan.native)
        }
        return plan
    }

    /// The error for a plan in which some files cannot go into the request, or nil if none.
    /// The failure card at send time and the pre-send notice in the composer use the same check, so the wording is identical.
    static func overLimitError(for plan: AttachmentDeliveryPlan, model: AIModel?) -> ProviderServiceError? {
        guard !plan.skipped.isEmpty else { return nil }
        // The two reasons are reported separately: the text line names only the files that do not fit the total, and a file-count overflow gets its own "at most N" line.
        let overTextBudget = plan.skipped.filter { $0.reason == .totalCapExceeded }.map(\.attachment.fileName)
        let overFileCount = plan.skipped.contains { $0.reason == .tooManyFiles }
        return .attachmentTextOverLimit(
            fileNames: overTextBudget,
            fileCountLimit: overFileCount ? FileExtractionLimits.resolve(model: model).maxFiles : nil
        )
    }

    /// Text budget gate when adding files: a file that would push the message's text total over the limit is
    /// not added, and the caller shows a notice.
    ///
    /// The limit comes from the same function as at send time (`FileExtractionLimits.resolve`). The route used at
    /// send time is not known yet, so only files that arrive as text on every route are counted: files on the
    /// model's allow-list that may go as native file blocks neither take budget nor get rejected and are judged
    /// at send time against the actual route. A file rejected here would certainly not fit at send time either.
    static func admitWithinTextBudget(
        existing: [Attachment],
        incoming: [Attachment],
        provider: ProviderKind?,
        model: AIModel?
    ) -> (accepted: [Attachment], rejected: [Attachment]) {
        let totalCap = FileExtractionLimits.resolve(model: model).totalCap
        func textBytes(_ attachment: Attachment) -> Int? {
            guard attachment.kind == .file else { return nil }
            if let provider, let model,
               AttachmentRouter.decide(attachment: attachment, provider: provider, model: model) == .native {
                return nil
            }
            // A file whose extraction failed is delivered as an error note and does not count against the body quota; an OCR-recognized scan counts as body text.
            guard attachment.hasUsableExtractedText else { return 0 }
            return decodeAttachmentText(attachment.resolvedBase64Data)?.utf8.count ?? 0
        }
        var consumed = existing.reduce(0) { $0 + (textBytes($1) ?? 0) }
        var accepted: [Attachment] = []
        var rejected: [Attachment] = []
        for attachment in incoming {
            guard let bytes = textBytes(attachment) else {
                accepted.append(attachment)
                continue
            }
            if consumed + bytes > totalCap {
                rejected.append(attachment)
            } else {
                consumed += bytes
                accepted.append(attachment)
            }
        }
        return (accepted, rejected)
    }

    /// "The message being sent" is the last user message (the same rule as `OutboundAttachmentBudget`).
    /// A non-chat send (a call without an evidence model, such as title generation) has none and returns nil.
    static func outgoingTurnIndex(in messages: [ChatMessage], isChatSend: Bool) -> Int? {
        guard isChatSend else { return nil }
        return messages.lastIndex(where: { $0.role == .user })
    }

    /// Builds request messages one by one and tells the builder which one is the message being sent.
    /// dynamicText ([D]) is appended only to the end of the last user message: while that message is built it is
    /// visible to `deliver`, and file text is injected before it.
    static func mapTurns<T>(
        _ messages: [ChatMessage],
        isChatSend: Bool,
        dynamicText: String? = nil,
        _ build: (_ message: ChatMessage, _ isOutgoingTurn: Bool) throws -> T
    ) rethrows -> [T] {
        let outgoing = outgoingTurnIndex(in: messages, isChatSend: isChatSend)
        let dynamicIndex = dynamicText?.isEmpty == false ? messages.lastIndex(where: { $0.role == .user }) : nil
        return try messages.enumerated().map { offset, message in
            guard offset == dynamicIndex else { return try build(message, offset == outgoing) }
            return try AttachmentDynamicTurn.$current.withValue(dynamicText) { try build(message, offset == outgoing) }
        }
    }

    /// Splits attachments into native and text groups via `AttachmentRouter`; with the route mode off or a nil model everything goes as text.
    private static func partition(
        _ attachments: [Attachment],
        provider: ProviderKind,
        mode: NativeFileMode,
        model: AIModel?,
        fileInput: CapabilityEvidenceFacade.InputCapabilityProjection?
    ) -> (native: [Attachment], text: [Attachment]) {
        guard mode != .off, let model = model else { return ([], attachments) }
        var native: [Attachment] = []
        var text: [Attachment] = []
        for att in attachments {
            switch AttachmentRouter.decide(attachment: att, provider: provider, model: model, mode: mode, fileInput: fileInput) {
            case .native: native.append(att)
            case .clientExtract: text.append(att)
            }
        }
        return (native, text)
    }

    /// Injects file attachments after the user's text according to the wrapper and limits.
    private static func inject(
        userText: String,
        attachments: [Attachment],
        wrapper: AttachmentWrapperVersion,
        model: AIModel?,
        imagePlaceholderText: String?,
        videoPlaceholderText: String?,
        dynamicText: String?
    ) -> (text: String, skipped: [(attachment: Attachment, reason: AttachmentInjector.SkipReason)]) {
        let limits = FileExtractionLimits.resolve(model: model)
        // [D] is always the last segment: file text and image placeholders are both inserted before it.
        let (body, dynamic) = AttachmentInjector.splitDynamic(userText, dynamicText: dynamicText)

        // 1. Inject file attachments by wrapper and limits
        let files = attachments.filter { $0.kind == .file }
        let fileAttachments: [(fileName: String, mimeType: String, sizeBytes: Int, extracted: ExtractedText?, errorCode: ExtractionErrorCode?)] = files.map { att in
            // Failed attachments (an OCR-recognized scan is still recorded as scanned_pdf but has body text, so it is injected as a success)
            if !att.hasUsableExtractedText,
               let codeStr = att.extractionErrorCode,
               let code = ExtractionErrorCode(rawValue: codeStr) {
                return (att.fileName, att.mimeType, att.extractedSizeBytes ?? 0, nil, code)
            }

            // Successful attachment: decode the extracted text from base64Data
            let content = decodeAttachmentText(att.resolvedBase64Data) ?? ""
            let extracted = ExtractedText(
                content: content,
                totalLines: att.extractedTotalLines ?? content.components(separatedBy: "\n").count,
                truncated: att.extractedTruncated ?? false,
                truncationReason: nil,
                sizeBytes: att.extractedSizeBytes ?? Data(content.utf8).count
            )
            return (att.fileName, att.mimeType, extracted.sizeBytes, extracted, nil)
        }

        let result = AttachmentInjector.injectAllIndexed(
            intoUserText: body,
            fileAttachments: fileAttachments,
            limits: limits,
            wrapper: wrapper
        )

        // 2. Image placeholders: only images that reach here are written (a route whose image projection says outbound=placeholder has the
        //    builder hand them over; when images are sent natively the builder does not hand them here); order: body, file blocks, placeholders.
        var text = result.text
        // 3. Video placeholders: a route that declares a placeholder cannot send video, so each video gets one line (without the file name),
        //    after the image placeholders; only written into the outbound text, the local message is unchanged.
        for (kind, placeholder) in [(AttachmentKind.image, imagePlaceholderText), (.video, videoPlaceholderText)] {
            guard let placeholder else { continue }
            let count = attachments.filter { $0.kind == kind }.count
            if count > 0 {
                text = ([text] + Array(repeating: placeholder, count: count))
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
            }
        }
        return (
            AttachmentInjector.appendDynamic(dynamic, to: text),
            result.skipped.map { (files[$0.index], $0.reason) }
        )
    }

    private static func decodeAttachmentText(_ base64: String?) -> String? {
        guard let base64 = base64, !base64.isEmpty,
              let d = Data(base64Encoded: base64) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

/// The dynamicText of the user message with [D] that is currently being built; bound by `AttachmentDelivery.mapTurns` and read by `deliver`.
enum AttachmentDynamicTurn {
    @TaskLocal static var current: String?
}

#if DEBUG
/// For tests: records the route an outbound builder actually reports to `deliver`, to compare route by route with `AttachmentTransportResolver`.
enum AttachmentDeliveryObservation {
    @TaskLocal static var onDeliver: (@Sendable (AttachmentTransport) -> Void)?
}
#endif
