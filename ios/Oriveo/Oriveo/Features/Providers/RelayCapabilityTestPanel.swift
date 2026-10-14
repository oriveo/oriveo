import SwiftUI

// MARK: - Capability test bottom panel (two states on the board: running and finished)
//
// What the panel shows is the pure function `RelayCapabilityTestPanel.make`; the three clients run same-named cases `RD4-PANEL-<caseId>` from the shared fixture (panelCases).
// Copy ids use the Android resource names (as in the fixture); `Copy.key` maps them to the English keys in this client's Providers table.

enum RelayCapabilityTestPanel {
    enum Item: String, CaseIterable, Sendable {
        case text, image, toolCall, web

        init(_ kind: RelayCapabilityTest.Kind) {
            switch kind {
            case .text: self = .text
            case .image: self = .image
            case .tool: self = .toolCall
            case .web: self = .web
            }
        }

        var titleKey: String {
            switch self {
            case .text: "Text chat"
            case .image: "Image input"
            case .toolCall: "Tool calls"
            case .web: "Web search"
            }
        }

        var runningCopy: Copy {
            switch self {
            case .text: .runningText
            case .image: .runningImage
            case .toolCall: .runningTool
            case .web: .runningWeb
            }
        }
    }

    enum Phase: String, Sendable {
        case running, completed, stopped
    }

    struct Running: Equatable, Sendable {
        let item: Item
        let elapsedMs: Int
    }

    struct Input: Equatable, Sendable {
        let transport: RelayTransport
        let items: [Item]
        /// With 2 or more keys, the name of the key the test is bound to; nil with a single key (no key chip is shown).
        let keyName: String?
        var phase: Phase
        var results: [Item: RelayCapabilityTest.ItemResult]
        var running: Running?
        var written: Bool
        var stopReason: RelayCapabilityTest.StopReason?
    }

    enum Header: Equatable, Sendable {
        case progress(current: Int, total: Int)
        case done
        case stopped
    }

    enum Icon: String, Sendable {
        case waiting, running, accepted, rejected, undetermined, notRun
    }

    /// Panel copy; rawValue is the Android resource name (the fixture's string id).
    enum Copy: String, Sendable {
        case runningText = "relay_cap_test_running_text"
        case runningImage = "relay_cap_test_running_image"
        case runningTool = "relay_cap_test_running_tool"
        case runningWeb = "relay_cap_test_running_web"
        case webSearchConfirmed = "model_options_relay_web_search_confirmed"
        case webNoSearch = "model_options_relay_web_no_search_in_test"
        case webRejected = "model_options_relay_web_rejected"
        case textOk = "relay_cap_test_text_ok"
        case supportedSaved = "relay_cap_test_supported_saved"
        case imageRejected = "relay_cap_test_image_rejected"
        case toolRejected = "relay_cap_test_tool_rejected"
        case imageNotObserved = "relay_cap_test_image_not_observed"
        case toolNotObserved = "relay_cap_test_tool_not_observed"
        case textNotFound = "relay_cap_test_text_not_found"
        case textRejected = "relay_cap_test_text_rejected"
        case undetermined = "relay_cap_test_undetermined"
        case reasonUnauthorized = "relay_cap_test_reason_unauthorized"
        case reasonForbidden = "relay_cap_test_reason_forbidden"
        case reasonRateLimited = "relay_cap_test_reason_rate_limited"
        case reasonHtml = "relay_cap_test_reason_html"
        case reasonServer = "relay_cap_test_reason_server"
        case reasonTimeout = "relay_cap_test_reason_timeout"
        case reasonNetwork = "relay_cap_test_reason_network"
        case reasonHttp = "relay_cap_test_reason_http"
        case notRun = "relay_cap_test_not_run"
        case notTested = "relay_cap_test_not_tested"
        case supported = "relay_capability_test_supported"
        case unsupported = "relay_capability_test_unsupported"
        case infoNamedKey = "relay_cap_test_info_named_key"
        case info = "relay_cap_test_info"
        case infoWebNamedKey = "relay_cap_test_info_web_named_key"
        case infoWeb = "relay_cap_test_info_web"
        case footerSaved = "relay_cap_test_footer_saved"
        case footerNothing = "relay_cap_test_footer_nothing"
        case stopped = "relay_cap_test_stopped"
        case stopCancelled = "relay_cap_test_stop_cancelled"
        case stopConnection = "relay_cap_test_stop_connection"
        case stopProtocol = "relay_cap_test_stop_protocol"
        case stopUnavailable = "relay_cap_test_stop_unavailable"

        /// This client's key (the English source text) and its table.
        var key: String {
            switch self {
            case .runningText: "Sending “Hi”"
            case .runningImage: "Uploading a tiny 8×8 image"
            case .runningTool: "Sending one tool definition"
            case .runningWeb: "Sending one request with your web search settings"
            case .webSearchConfirmed: "Search confirmed"
            case .webNoSearch: "Didn’t search when tested"
            case .webRejected: "This model rejects the web search settings"
            case .textOk: "Streaming reply works"
            case .supportedSaved: "Supported · Saved as “Tested”"
            case .imageRejected: "Upstream rejected the image · Saved"
            case .toolRejected: "Upstream rejected the tools parameter · Saved"
            case .imageNotObserved: "Replied, but not about the image"
            case .toolNotObserved: "Replied without calling the tool"
            case .textNotFound: "Model not found. The address and key work, so check the model name."
            case .textRejected: "Upstream rejected the request (%lld)"
            case .undetermined: "Couldn’t tell: %@ · Not saved"
            case .reasonUnauthorized: "the key is invalid or expired (401)"
            case .reasonForbidden: "this key has no access to the model (403)"
            case .reasonRateLimited: "rate-limited or out of credit (429)"
            case .reasonHtml: "got a web page instead of an API reply, so check the address"
            case .reasonServer: "upstream error (%lld)"
            case .reasonTimeout: "no reply within 30 seconds"
            case .reasonNetwork: "network error"
            case .reasonHttp: "HTTP %lld"
            case .notRun: "Not tested: the text check didn’t pass"
            case .notTested: "Not tested"
            case .supported: "Supported"
            case .unsupported: "Not supported"
            case .infoNamedKey: "Sends up to %1$lld tiny requests with the “%2$@” key, the same way chat does. Up to 30 seconds each."
            case .info: "Sends up to %lld tiny requests with your key, the same way chat does. Up to 30 seconds each."
            case .infoWebNamedKey:
                "Sends up to %1$lld tiny requests with the “%2$@” key, the same way chat does. One of them searches the web, which may be billed as a search. Up to 30 seconds each."
            case .infoWeb:
                "Sends up to %lld tiny requests with your key, the same way chat does. One of them searches the web, which may be billed as a search. Up to 30 seconds each."
            case .footerSaved: "Results are saved to this model’s capabilities. You can override them in Advanced."
            case .footerNothing: "Nothing was saved."
            case .stopped: "Test stopped: %@. Requests already sent won’t be saved."
            case .stopCancelled: "you cancelled it"
            case .stopConnection: "the connection changed"
            case .stopProtocol: "the protocol changed"
            case .stopUnavailable: "this model can no longer be tested"
            }
        }

        /// "Supported" has always lived in the main table; the three web-search result sentences reuse the Chat table; everything else is in the Providers table.
        var localized: String {
            switch self {
            case .supported: L10n.tr(key)
            case .webSearchConfirmed, .webNoSearch, .webRejected: L10n.tr(key, table: .chat)
            default: L10n.tr(key, table: .providers)
            }
        }
    }

    /// Arguments (%@ / %lld) of the subtitle.
    enum Arg: Equatable, Sendable {
        case copy(Copy)
        case code(Int)
        /// Copy that carries its own status code (server / http).
        case copyWithCode(Copy, Int)

        /// Follows the fixture's `subtitleArg` format.
        var fixtureValue: String {
            switch self {
            case let .copy(copy): copy.rawValue
            case let .code(code): String(code)
            case let .copyWithCode(copy, code): "\(copy.rawValue):\(code)"
            }
        }
    }

    enum Trailing: Equatable, Sendable {
        case waiting
        /// Elapsed time of a finished item, in tenths of a second (rounded).
        case elapsed(tenths: Int)
        case running(tenths: Int)

        /// Follows the fixture's `trailing` format ("elapsed:1.2").
        var fixtureValue: String {
            switch self {
            case .waiting: "waiting"
            case let .elapsed(tenths): "elapsed:\(tenths / 10).\(tenths % 10)"
            case let .running(tenths): "running:\(tenths / 10).\(tenths % 10)"
            }
        }
    }

    struct Row: Equatable, Sendable {
        let item: Item
        let icon: Icon
        let subtitle: Copy?
        let subtitleArg: Arg?
        let trailing: Trailing?
    }

    enum Footer: Equatable, Sendable {
        /// `web` means the list contains the web-search item, so use the description that mentions web search.
        case info(count: Int, keyName: String?, web: Bool)
        case saved
        case nothing
        case stopped(RelayCapabilityTest.StopReason)
    }

    enum Button: String, Sendable {
        case cancel, done
    }

    struct State: Equatable, Sendable {
        let header: Header
        /// Progress bar: finished items / total items.
        let finished: Int
        let total: Int
        let transport: RelayTransport
        let keyName: String?
        let rows: [Row]
        let footer: Footer
        let button: Button
        /// Can be swiped away or dismissed by tapping outside (everything except the running state).
        let dismissible: Bool
    }

    // MARK: Pure functions

    static func make(_ input: Input) -> State {
        let total = input.items.count
        let finished = input.items.filter { input.results[$0] != nil }.count
        let header: Header
        switch input.phase {
        case .running:
            let current = input.running.flatMap { running in input.items.firstIndex(of: running.item) }.map { $0 + 1 }
                ?? min(finished + 1, total)
            header = .progress(current: current, total: total)
        case .completed: header = .done
        case .stopped: header = .stopped
        }
        let textFailed = input.results[.text].map { $0.verdict != .accepted } ?? false
        let rows = input.items.map { item in
            row(item, input: input, textFailed: textFailed)
        }
        let footer: Footer = switch input.phase {
        case .running: .info(count: total, keyName: input.keyName, web: input.items.contains(.web))
        case .completed: input.written ? .saved : .nothing
        case .stopped: .stopped(input.stopReason ?? .cancelled)
        }
        return State(
            header: header,
            finished: input.phase == .completed ? total : finished,
            total: total,
            transport: input.transport,
            keyName: input.keyName,
            rows: rows,
            footer: footer,
            button: input.phase == .running ? .cancel : .done,
            dismissible: input.phase != .running
        )
    }

    private static func row(_ item: Item, input: Input, textFailed: Bool) -> Row {
        if let result = input.results[item] {
            let (subtitle, arg) = subtitle(item, result: result, written: input.phase == .completed && input.written)
            return Row(item: item, icon: icon(result.verdict), subtitle: subtitle, subtitleArg: arg, trailing: .elapsed(tenths: tenths(result.elapsedMs)))
        }
        if input.phase == .running, let running = input.running, running.item == item {
            return Row(item: item, icon: .running, subtitle: item.runningCopy, subtitleArg: nil, trailing: .running(tenths: tenths(running.elapsedMs)))
        }
        switch input.phase {
        case .running:
            return Row(item: item, icon: .waiting, subtitle: nil, subtitleArg: nil, trailing: .waiting)
        case .completed:
            return Row(item: item, icon: .notRun, subtitle: textFailed ? .notRun : .notTested, subtitleArg: nil, trailing: nil)
        case .stopped:
            return Row(item: item, icon: .notRun, subtitle: .notTested, subtitleArg: nil, trailing: nil)
        }
    }

    private static func subtitle(_ item: Item, result: RelayCapabilityTest.ItemResult, written: Bool) -> (Copy, Arg?) {
        if result.verdict == .undetermined {
            return (.undetermined, reasonArg(result))
        }
        // Web-search item: give the same sentence as the Chat table based on the probe result, whether or not anything was written.
        if item == .web {
            switch result.verdict {
            case .searched, .accepted: return (.webSearchConfirmed, nil)
            case .silent, .notObserved: return (.webNoSearch, nil)
            case .rejected: return (.webRejected, nil)
            case .undetermined: return (.undetermined, reasonArg(result))
            }
        }
        // The reply came back without evidence of image recognition or tool calling: not confirmed and nothing written.
        if result.verdict == .notObserved {
            return (item == .toolCall ? .toolNotObserved : .imageNotObserved, nil)
        }
        switch (item, result.verdict) {
        case (.text, .accepted):
            return (.textOk, nil)
        case (.text, _):
            return result.reason == .notFound ? (.textNotFound, nil) : (.textRejected, .code(result.status ?? 0))
        case (_, .accepted):
            return (written ? .supportedSaved : .supported, nil)
        default:
            if written { return (item == .image ? .imageRejected : .toolRejected, nil) }
            return (.unsupported, nil)
        }
    }

    private static func reasonArg(_ result: RelayCapabilityTest.ItemResult) -> Arg {
        switch result.reason {
        case .unauthorized: .copy(.reasonUnauthorized)
        case .forbidden: .copy(.reasonForbidden)
        case .rateLimited: .copy(.reasonRateLimited)
        case .html: .copy(.reasonHtml)
        case .timeout: .copy(.reasonTimeout)
        case .network: .copy(.reasonNetwork)
        case .server: .copyWithCode(.reasonServer, result.status ?? 0)
        case .ok, .upstreamRejected, .notFound, .http, .notObserved: .copyWithCode(.reasonHttp, result.status ?? 0)
        }
    }

    private static func icon(_ verdict: RelayCapabilityTest.Verdict) -> Icon {
        switch verdict {
        case .accepted, .searched: .accepted
        case .rejected: .rejected
        case .undetermined, .notObserved, .silent: .undetermined
        }
    }

    /// Milliseconds to tenths of a second, rounded.
    static func tenths(_ ms: Int) -> Int {
        (max(ms, 0) + 50) / 100
    }

    // MARK: Localized text

    static func text(_ copy: Copy, arg: Arg?) -> String {
        switch arg {
        case nil: copy.localized
        case let .code(code): String(format: copy.localized, Int64(code))
        case let .copy(inner): String(format: copy.localized, inner.localized)
        case let .copyWithCode(inner, code): String(format: copy.localized, String(format: inner.localized, Int64(code)))
        }
    }

    static func footerText(_ footer: Footer) -> String {
        switch footer {
        case let .info(count, keyName?, web):
            L10n.format((web ? Copy.infoWebNamedKey : .infoNamedKey).localized, Int64(count), keyName)
        case let .info(count, nil, web):
            L10n.format((web ? Copy.infoWeb : .info).localized, Int64(count))
        case .saved: Copy.footerSaved.localized
        case .nothing: Copy.footerNothing.localized
        case let .stopped(reason): String(format: Copy.stopped.localized, stopCopy(reason).localized)
        }
    }

    static func stopCopy(_ reason: RelayCapabilityTest.StopReason) -> Copy {
        switch reason {
        case .cancelled: .stopCancelled
        case .connection: .stopConnection
        case .protocolChanged: .stopProtocol
        case .unavailable: .stopUnavailable
        }
    }

    /// Seconds with one decimal place, using the number format of the current UI language.
    static func seconds(_ tenths: Int) -> String {
        (Double(tenths) / 10).formatted(.number.precision(.fractionLength(1)).locale(AppLocalization.currentLocale))
    }

    static func trailingText(_ trailing: Trailing) -> String {
        switch trailing {
        case .waiting: L10n.tr("Waiting", table: .providers)
        case let .elapsed(tenths): String(format: L10n.tr("%@s", table: .providers), seconds(tenths))
        case let .running(tenths): String(format: L10n.tr("%@s…", table: .providers), seconds(tenths))
        }
    }
}

// MARK: - Panel state (host)

/// Tapping "Test capabilities" opens the panel and starts the run; while running only "Cancel" is possible, and "Done" closes it afterwards.
@Observable
final class RelayCapabilityTestController {
    private(set) var input: RelayCapabilityTestPanel.Input?
    private(set) var modelName = ""
    /// Start time of the item currently running; the panel refreshes the elapsed time from it every 0.1 seconds.
    private(set) var runningSince: Date?
    private var task: Task<Void, Never>?

    var isPresented: Bool { input != nil }

    func start(appState: AppState, providerID: UUID, modelID: String) {
        guard input == nil,
              let provider = appState.provider(for: providerID),
              let model = provider.models.first(where: { $0.id == modelID }) else { return }
        // On the first frame, list the web-search item and the web-search description according to whether the first protocol has a saved web fragment (the same decision the run uses).
        let items = RelayCapabilityTest.plannedKinds(
            provider: provider, model: model, fragments: appState.providerManager.relayWebProbeAutoContext.fragments
        ).map(RelayCapabilityTestPanel.Item.init)
        modelName = model.name
        input = RelayCapabilityTestPanel.Input(
            transport: RelayCapabilityTest.transport(provider: provider, model: model),
            items: items,
            keyName: RelayModelAdvancedBoard.keySection(provider: provider, modelID: modelID, readOnly: false)?.current.title,
            phase: .running,
            results: [:],
            running: .init(item: .text, elapsedMs: 0),
            written: false,
            stopReason: nil
        )
        runningSince = Date()
        let manager = appState.providerManager
        task = Task { [weak self] in
            let result = await manager.runRelayCapabilityTest(providerID: providerID, modelID: modelID) { event in
                self?.apply(event)
            }
            self?.finish(result)
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// The panel can be dismissed only after the run has finished.
    func dismiss() {
        guard input?.phase != .running else { return }
        input = nil
        task = nil
    }

    /// For tests: wait until this run finishes.
    func waitUntilFinished() async {
        await task?.value
    }

    /// The display at a given moment; the running item's elapsed time is computed from `now`.
    func state(at now: Date) -> RelayCapabilityTestPanel.State? {
        guard var input else { return nil }
        if let running = input.running, let runningSince {
            input.running = .init(item: running.item, elapsedMs: Int(now.timeIntervalSince(runningSince) * 1000))
        }
        return RelayCapabilityTestPanel.make(input)
    }

    private func apply(_ event: RelayCapabilityTest.Event) {
        switch event {
        case let .started(kind):
            input?.running = .init(item: .init(kind), elapsedMs: 0)
            runningSince = Date()
        case let .finished(kind, result):
            input?.results[.init(kind)] = result
            input?.running = nil
            runningSince = nil
        }
    }

    private func finish(_ result: RelayCapabilityTest.Result?) {
        guard var input else { return }
        input.running = nil
        runningSince = nil
        guard let result else {
            input.phase = .stopped
            input.stopReason = .unavailable
            self.input = input
            return
        }
        if let text = result.text { input.results[.text] = text }
        for (key, item) in result.itemResults {
            switch key {
            case .image: input.results[.image] = item
            case .toolCall: input.results[.toolCall] = item
            case .web: input.results[.web] = item
            default: continue
            }
        }
        switch result.outcome {
        case .completed, .textFailed:
            input.phase = .completed
            input.written = result.written
        case .stopped:
            input.phase = .stopped
            input.stopReason = result.stopReason
        }
        self.input = input
    }
}

#if DEBUG
// Preview shots only: the three properties are private(set), so a "running" panel can only be set up inside this file.
extension RelayCapabilityTestController {
    convenience init(debugInput: RelayCapabilityTestPanel.Input, modelName: String, runningSince: Date) {
        self.init()
        input = debugInput
        self.modelName = modelName
        self.runningSince = runningSince
    }
}
#endif

// MARK: - Panel views

struct RelayCapabilityTestSheet: View {
    let controller: RelayCapabilityTestController

    @State private var measuredHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                if let state = controller.state(at: context.date) {
                    content(state)
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: RelayCapabilityTestHeightKey.self, value: proxy.size.height)
                }
            }
            Spacer(minLength: 0)
        }
        .onPreferenceChange(RelayCapabilityTestHeightKey.self) { measuredHeight = $0 }
        .interactiveDismissDisabled(controller.input?.phase == .running)
        .presentationDetents([.height(measuredHeight > 0 ? min(measuredHeight, 640) : 460)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(OriveoTheme.Palette.surface)
    }

    private func content(_ state: RelayCapabilityTestPanel.State) -> some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
            header(state)
            progressBar(state)
            rows(state)
            HStack(alignment: .firstTextBaseline, spacing: OriveoTheme.Spacing.sm) {
                PhosphorIcon.info.image(.regular)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(RelayCapabilityTestPanel.footerText(state.footer))
                    .font(OriveoTheme.Typography.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            button(state.button)
        }
        .padding(.horizontal, OriveoTheme.Spacing.xl)
        .padding(.top, OriveoTheme.Spacing.xl)
        .padding(.bottom, OriveoTheme.Spacing.lg)
    }

    /// Capability test header: title + protocol / key chips on the left; progress / Done / Stopped on the right, vertically centered on the whole row so it is not pinned to the first line when the title wraps to two lines.
    private func header(_ state: RelayCapabilityTestPanel.State) -> some View {
        HStack(alignment: .center, spacing: OriveoTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                Text(String(format: L10n.tr("Test %@", table: .providers), controller.modelName))
                    .font(OriveoTheme.Typography.title2)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: OriveoTheme.Spacing.sm) {
                    chip(Text(verbatim: RelayProtocolMix.legendName(state.transport)), systemImage: nil)
                    if let keyName = state.keyName {
                        chip(Text(verbatim: keyName), systemImage: "key")
                    }
                }
            }
            Spacer(minLength: 0)
            switch state.header {
            case let .progress(current, total):
                Text(String(format: L10n.tr("%1$lld / %2$lld", table: .providers), Int64(current), Int64(total)))
                    .font(OriveoTheme.Typography.title3.monospacedDigit())
                    .foregroundStyle(OriveoTheme.Palette.primary)
            case .done:
                Label(L10n.tr("Completed", table: .providers), systemImage: "checkmark")
                    .font(OriveoTheme.Typography.body.weight(.medium))
                    .foregroundStyle(OriveoTheme.Palette.success)
            case .stopped:
                Text(L10n.tr("Stopped", table: .providers))
                    .font(OriveoTheme.Typography.body.weight(.medium))
                    .foregroundStyle(OriveoTheme.Palette.warningText)
            }
        }
    }

    private func chip(_ text: Text, systemImage: String?) -> some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).accessibilityHidden(true)
            }
            text.lineLimit(1)
        }
        .font(OriveoTheme.Typography.footnote)
        .foregroundStyle(OriveoTheme.Palette.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(OriveoTheme.Palette.surfaceInset))
    }

    private func progressBar(_ state: RelayCapabilityTestPanel.State) -> some View {
        let fraction = state.total > 0 ? CGFloat(state.finished) / CGFloat(state.total) : 0
        let tint = state.header == .done ? OriveoTheme.Palette.success : OriveoTheme.Palette.primary
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(OriveoTheme.Palette.border)
                Capsule().fill(tint).frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private func rows(_ state: RelayCapabilityTestPanel.State) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(state.rows.enumerated()), id: \.offset) { index, row in
                rowView(row)
                if index < state.rows.count - 1 {
                    Rectangle().fill(OriveoTheme.Palette.border).frame(height: 0.5)
                }
            }
        }
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: OriveoTheme.Radius.inset, style: .continuous)
                .fill(OriveoTheme.Palette.surfaceElevated)
        )
    }

    private func rowView(_ row: RelayCapabilityTestPanel.Row) -> some View {
        HStack(spacing: OriveoTheme.Spacing.md) {
            iconView(row.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr(row.item.titleKey, table: .providers))
                    .font(OriveoTheme.Typography.body.weight(.medium))
                    .foregroundStyle(row.icon == .waiting || row.icon == .notRun
                        ? OriveoTheme.Palette.textTertiary : OriveoTheme.Palette.textPrimary)
                if let subtitle = row.subtitle {
                    Text(RelayCapabilityTestPanel.text(subtitle, arg: row.subtitleArg))
                        .font(OriveoTheme.Typography.caption)
                        .foregroundStyle(row.icon == .rejected ? OriveoTheme.Palette.danger : OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let trailing = row.trailing {
                Text(RelayCapabilityTestPanel.trailingText(trailing))
                    .font(OriveoTheme.Typography.caption.monospacedDigit())
                    .foregroundStyle(row.icon == .running ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textTertiary)
            }
        }
        .padding(.vertical, OriveoTheme.Spacing.md)
        .accessibilityElement(children: .combine)
    }

    /// The whole status column uses Phosphor icons, written the same way as the status column of the detection steps, so one column never mixes two icon sets.
    private func statusGlyph(_ icon: PhosphorIcon) -> some View {
        icon.image(.regular)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: 22, height: 22)
    }

    @ViewBuilder
    private func iconView(_ icon: RelayCapabilityTestPanel.Icon) -> some View {
        Group {
            switch icon {
            case .accepted:
                statusGlyph(.checkCircle).foregroundStyle(OriveoTheme.Palette.success)
            case .rejected:
                statusGlyph(.xCircle).foregroundStyle(OriveoTheme.Palette.danger)
            case .undetermined:
                statusGlyph(.warningCircle).foregroundStyle(OriveoTheme.Palette.warning)
            case .running:
                ProgressView().tint(OriveoTheme.Palette.primary)
            case .waiting, .notRun:
                statusGlyph(.circle).foregroundStyle(OriveoTheme.Palette.textTertiary)
            }
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }

    private func button(_ kind: RelayCapabilityTestPanel.Button) -> some View {
        Button {
            if kind == .cancel { controller.cancel() } else { controller.dismiss() }
        } label: {
            Text(L10n.tr(kind == .cancel ? "Cancel" : "Done"))
                .font(OriveoTheme.Typography.body.weight(.semibold))
                .foregroundStyle(kind == .cancel ? OriveoTheme.Palette.textPrimary : OriveoTheme.Palette.onPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background {
                    if kind == .cancel {
                        RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
                            .fill(OriveoTheme.Palette.surfaceElevated)
                    } else {
                        RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
                            .fill(OriveoTheme.Palette.primaryGradient)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RelayCapabilityTestHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
