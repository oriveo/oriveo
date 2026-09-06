import QuartzCore
import SwiftUI

/// Throttling buffer for streamed chunks. It is deliberately not `@State`, so appending to it
/// does not re-render anything; only the caller writing `resultText` after the 30fps gate does.
private final class CrosscheckChunkBuffer {
    var rawText: String = ""
    private var lastFlushTime: CFTimeInterval = 0
    private let flushInterval: CFTimeInterval = 1.0 / 30.0

    /// Appends a chunk and returns the full text when at least one frame has passed since the last
    /// flush, otherwise nil.
    func appendAndTryFlush(_ chunk: String) -> String? {
        rawText += chunk
        let now = CACurrentMediaTime()
        guard now - lastFlushTime >= flushInterval else { return nil }
        lastFlushTime = now
        return rawText
    }

    func reset() {
        rawText = ""
        lastFlushTime = 0
    }
}

/// Where a cross-check was started from.
enum CrosscheckOrigin {
    /// A delivered assistant message in a conversation, plus the question that produced it.
    case chatMessage(conversationID: UUID, message: ChatMessage, prompt: String?)
    /// A saved note. The answer comes from `bodySnapshot` (or `body`) and the question from
    /// `sourcePrompt`.
    case note(Note)
}

@MainActor
enum CrosscheckStreamTask {
    static func make(
        stream: AsyncThrowingStream<String, Error>,
        onChunk: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (Error) -> Void,
        onFinished: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            defer {
                if !Task.isCancelled {
                    onFinished()
                }
            }

            do {
                for try await chunk in stream {
                    try Task.checkCancellation()
                    onChunk(chunk)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                onError(error)
            }
        }
    }
}

enum CrosscheckSheetPresentation {
    enum ResultState: Equatable {
        case empty
        case running
        case streamingResult
        case result
    }

    nonisolated static func canRun(isRunning: Bool, hasSelectedModel: Bool) -> Bool {
        !isRunning && hasSelectedModel
    }

    nonisolated static func canSave(resultText: String, isRunning: Bool) -> Bool {
        !isRunning && !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static func resultState(resultText: String, isRunning: Bool) -> ResultState {
        let hasResult = hasResultText(resultText)
        if isRunning && hasResult {
            return .streamingResult
        }
        if isRunning {
            return .running
        }
        if hasResult {
            return .result
        }
        return .empty
    }

    nonisolated static func showsAnswerCanvas(resultText: String, isRunning: Bool) -> Bool {
        switch resultState(resultText: resultText, isRunning: isRunning) {
        case .streamingResult, .result:
            return true
        case .empty, .running:
            return false
        }
    }

    nonisolated static func usesStableStreamingMarkdownLayout(resultText: String, isRunning: Bool) -> Bool {
        showsAnswerCanvas(resultText: resultText, isRunning: isRunning)
    }

    nonisolated static func hasResultText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Freezes only the models this cross-check may use. Grouping, collapsing and search stay with the
/// shared model picker.
@MainActor
struct CrosscheckModelPickerPresentation: Identifiable {
    let id = UUID()
    let picker: ModelPickerPresentationSnapshot
    let optionsByRowID: [ModelPickerRowID: CrosscheckModelOption]

    init(
        providers: [Provider],
        providersVersion: UInt,
        options: [CrosscheckModelOption],
        selectedOption: CrosscheckModelOption?
    ) {
        let pickerProviders = NoteCrosscheckModels.pickerProviders(from: providers, options: options)
        picker = ModelPickerPresentationSnapshot(
            context: .crosscheck,
            providers: pickerProviders,
            providersVersion: providersVersion,
            currentProviderID: selectedOption?.providerID,
            currentModel: selectedOption?.model
        )
        optionsByRowID = Dictionary(
            options.map {
                (ModelPickerRowID(providerID: $0.providerID, modelID: $0.modelID), $0)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

/// Sends one answer to a second model for review and offers to keep both together as a note.
struct CrosscheckSheet: View {
    let origin: CrosscheckOrigin
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedModel: CrosscheckModelOption?
    @State private var executedModel: CrosscheckModelOption?
    @State private var resultText = ""
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var runTask: Task<Void, Never>?
    @State private var showOriginalAnswer = false
    @State private var modelPickerPresentation: CrosscheckModelPickerPresentation?
    @State private var chunkBuffer = CrosscheckChunkBuffer()

    private var resultState: CrosscheckSheetPresentation.ResultState {
        CrosscheckSheetPresentation.resultState(resultText: resultText, isRunning: isRunning)
    }

    private var showsAnswerCanvas: Bool {
        CrosscheckSheetPresentation.showsAnswerCanvas(resultText: resultText, isRunning: isRunning)
    }

    private var usesStableStreamingMarkdownLayout: Bool {
        CrosscheckSheetPresentation.usesStableStreamingMarkdownLayout(resultText: resultText, isRunning: isRunning)
    }

    private var canRun: Bool {
        CrosscheckSheetPresentation.canRun(isRunning: isRunning, hasSelectedModel: selectedModel != nil)
    }

    private var canSave: Bool {
        CrosscheckSheetPresentation.canSave(resultText: resultText, isRunning: isRunning)
            && executedModel != nil
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        crosscheckTopHeader
                        if let errorMessage {
                            errorBanner(errorMessage)
                        }
                        secondOpinionStage
                        originalSourceStrip
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 22)
                    .padding(.bottom, 124)
                }

                closeButton
                    .padding(.top, 12)
                    .padding(.trailing, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(crosscheckBackground.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                commandDock
            }
            .onAppear(perform: setupDefaultModel)
            .onDisappear(perform: cancelRun)
            .sheet(item: $modelPickerPresentation) { presentation in
                ModelPickerSheet(
                    context: .crosscheck,
                    presentation: presentation.picker,
                    onSelect: { selection in
                        let rowID = ModelPickerRowID(
                            providerID: selection.providerID,
                            modelID: selection.modelID
                        )
                        guard let option = presentation.optionsByRowID[rowID] else { return }
                        selectModel(option)
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .environment(appState)
            }
        }
    }

    private var crosscheckBackground: some View {
        ZStack {
            NotesChrome.background

            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.025 : 0.30),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .center
            )
        }
    }

    private var crosscheckTopHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            crosscheckHeaderCopy
            modelComparisonRail
        }
        .padding(.horizontal, 2)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    private var crosscheckHeaderCopy: some View {
        HStack(alignment: .top, spacing: 12) {
            crosscheckHeroIcon

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("Cross-check answer", table: .notes))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: false, vertical: true)

                Text(L10n.tr("Use another model once, then save both sources as a note.", table: .notes))
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 350, alignment: .leading)
        .padding(.trailing, 52)
    }

    private var crosscheckHeroIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.18 : 0.11))
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(OriveoTheme.Palette.primary)
        }
        .frame(width: 42, height: 42)
        .accessibilityHidden(true)
    }

    private var closeButton: some View {
        Button {
            cancelRun()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("Close", table: .notes))
    }

    private var modelComparisonRail: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 10
            let arrowWidth: CGFloat = 18
            let columnWidth = max(CGFloat.zero, (proxy.size.width - arrowWidth - spacing * 2) / 2)

            HStack(alignment: .center, spacing: spacing) {
                sourceModelBlock
                    .frame(width: columnWidth, alignment: .leading)

                routeArrow
                    .frame(width: arrowWidth, height: 18)

                modelSpotlightPicker
                    .frame(width: columnWidth, alignment: .leading)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
        }
        .frame(height: 74)
        .overlay(modelComparisonRailLine, alignment: .top)
        .overlay(modelComparisonRailLine, alignment: .bottom)
    }

    private var sourceModelBlock: some View {
        HStack(alignment: .center, spacing: 9) {
            sourceModelLogo

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("Source model", table: .notes))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .lineLimit(1)

                Text(originalModelName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.80)
                    .truncationMode(.middle)
            }
        }
        .frame(minHeight: 46, alignment: .center)
    }

    private var routeArrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(OriveoTheme.Palette.textTertiary.opacity(colorScheme == .dark ? 0.70 : 0.58))
            .frame(width: 18, height: 18)
    }

    private var modelComparisonRailLine: some View {
        Rectangle()
            .fill(OriveoTheme.Palette.border.opacity(colorScheme == .dark ? 0.24 : 0.14))
            .frame(height: 0.7)
    }

    @ViewBuilder
    private var modelSpotlightPicker: some View {
        if availableModels.isEmpty {
            unavailableModelCard
        } else {
            Button {
                presentModelPicker()
            } label: {
                modelSpotlightLabel
            }
            .buttonStyle(.plain)
            .disabled(isRunning)
            .accessibilityLabel(L10n.tr("Second model", table: .notes))
            .accessibilityValue(selectedModel?.label ?? "")
        }
    }

    private var modelSpotlightLabel: some View {
        HStack(alignment: .center, spacing: 9) {
            selectedModelLogo

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("Second model", table: .notes))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .lineLimit(1)

                Text(selectedModel?.modelName ?? "—")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
        }
        .frame(minHeight: 46, alignment: .center)
        .contentShape(Rectangle())
        .opacity(isRunning ? 0.76 : 1)
    }

    @ViewBuilder
    private var selectedModelLogo: some View {
        if let selectedModel {
            ProviderBadgeIcon(kind: selectedModel.logoProviderKind, size: 24, relayKind: selectedModel.relayKind)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "questionmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var sourceModelLogo: some View {
        if let originalProviderKind {
            ProviderBadgeIcon(kind: originalProviderKind, size: 24, relayKind: originalRelayKind)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "doc.text")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
    }

    private var unavailableModelCard: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.warning)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("No eligible second model is available.", table: .notes))
                    .font(OriveoTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    cancelRun()
                    dismiss()
                    appState.selectedTab = .providers
                    appState.openProviderSetup(from: .providers)
                } label: {
                    Label(L10n.tr("Add Provider"), systemImage: "plus")
                        .font(OriveoTheme.Typography.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(OriveoTheme.Palette.primary)
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var secondOpinionStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                secondOpinionTitle
                Spacer(minLength: OriveoTheme.Spacing.sm)
                if let executedModel {
                    modelMicroChip(executedModel)
                }
            }

            ZStack {
                resultCanvasBackground
                resultCanvasInnerTexture
                resultContent
                    .padding(showsAnswerCanvas ? 21 : 0)
            }
            .frame(maxWidth: .infinity, minHeight: resultState == .empty ? 264 : 188, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .shadow(color: activeBrandColor.opacity(colorScheme == .dark ? 0.16 : 0.050), radius: 16, y: 10)
        }
    }

    private var secondOpinionTitle: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(activeBrandColor.opacity(colorScheme == .dark ? 0.18 : 0.11))
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(activeBrandColor)
            }
            .frame(width: 28, height: 28)

            Text(L10n.tr("Second opinion", table: .notes))
                .font(OriveoTheme.Typography.title3)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var resultContent: some View {
        switch resultState {
        case .empty:
            emptyResultContent
        case .running:
            runningResultContent
        case .streamingResult:
            resultAnswerContent(resultText, showsCursor: true)
        case .result:
            resultAnswerContent(resultText, showsCursor: false)
        }
    }

    @ViewBuilder
    private var emptyResultContent: some View {
        VStack(spacing: 18) {
            if let selectedModel {
                providerLogoMark(
                    kind: selectedModel.logoProviderKind,
                    relayKind: selectedModel.relayKind,
                    size: 70
                )
            } else {
                Image(systemName: "key.horizontal")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .frame(width: 70, height: 70)
                    .background(
                        Circle()
                            .fill(OriveoTheme.Palette.surface.opacity(colorScheme == .dark ? 0.82 : 0.96))
                    )
            }

            Text(L10n.tr("Run the check to see the second model response.", table: .notes))
                .font(OriveoTheme.Typography.caption.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, minHeight: 264, alignment: .center)
    }

    private var runningResultContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                    .tint(activeBrandColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("Checking...", table: .notes))
                        .font(OriveoTheme.Typography.caption.weight(.bold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    if let modelName = selectedModel?.modelName {
                        Text(modelName)
                            .font(OriveoTheme.Typography.footnote.weight(.medium))
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
        }
        .padding(21)
        .frame(maxWidth: .infinity, minHeight: 188, alignment: .topLeading)
    }

    private func resultAnswerContent(_ text: String, showsCursor: Bool = false) -> some View {
        MarkdownMessageView(
            text: text,
            isStreaming: usesStableStreamingMarkdownLayout,
            showsStreamingCursor: showsCursor,
            typography: .notes
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { transaction in
            transaction.disablesAnimations = true
            transaction.animation = nil
        }
    }

    private var originalSourceStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.86)) {
                    showOriginalAnswer.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    if let originalProviderKind {
                        ProviderBadgeIcon(kind: originalProviderKind, size: 28, relayKind: originalRelayKind)
                            .frame(width: 34, height: 34)
                    } else {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(OriveoTheme.Palette.surfaceElevated.opacity(0.80)))
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.tr("Original answer", table: .notes))
                            .font(OriveoTheme.Typography.footnote.weight(.bold))
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)

                        Text(originalAnswerPreview)
                            .font(OriveoTheme.Typography.footnote.weight(.medium))
                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 10)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .rotationEffect(.degrees(showOriginalAnswer ? 180 : 0))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(sourceStripDivider, alignment: .top)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("Original answer", table: .notes))
            .accessibilityValue(originalAnswerPreview)

            if showOriginalAnswer {
                MarkdownMessageView(text: originalAnswer, typography: .notes)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(OriveoTheme.Palette.surfaceElevated.opacity(colorScheme == .dark ? 0.70 : 0.64))
                    )
            }
        }
    }

    private var commandDock: some View {
        HStack(spacing: 10) {
            if canSave {
                Button {
                    runCheck()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(CrosscheckDockIconButtonStyle())
                .disabled(!canRun)
                .accessibilityLabel(L10n.tr("Run check", table: .notes))

                Button {
                    saveAsNote()
                } label: {
                    dockHeroLabel(title: L10n.tr("Save as Note", table: .notes), icon: "note.text.badge.plus")
                }
                .buttonStyle(CrosscheckHeroButtonStyle())
            } else {
                Button {
                    runCheck()
                } label: {
                    dockHeroLabel(
                        title: isRunning ? L10n.tr("Checking...", table: .notes) : L10n.tr("Run check", table: .notes),
                        icon: isRunning ? "hourglass" : "checkmark.seal"
                    )
                }
                .buttonStyle(CrosscheckHeroButtonStyle())
                .disabled(!canRun)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: OriveoTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(OriveoTheme.Palette.danger)
            Text(message)
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(OriveoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: OriveoTheme.Radius.inset, style: .continuous)
                .fill(OriveoTheme.Palette.dangerSoft)
        )
    }

    private var resultCanvasBackground: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        OriveoTheme.Palette.surfaceElevated.opacity(colorScheme == .dark ? 0.92 : 0.98),
                        activeBrandColor.opacity(colorScheme == .dark ? 0.045 : 0.024),
                        OriveoTheme.Palette.surface.opacity(colorScheme == .dark ? 0.88 : 0.96)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(OriveoTheme.Palette.border.opacity(showsAnswerCanvas ? 0.10 : 0.16), lineWidth: 0.6)
            )
    }

    private var resultCanvasInnerTexture: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(colorScheme == .dark ? 0.04 : 0.42))
                .frame(height: 1)

            LinearGradient(
                colors: [
                    activeBrandColor.opacity(colorScheme == .dark ? 0.035 : 0.018),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .allowsHitTesting(false)
    }

    private var sourceStripDivider: some View {
        Rectangle()
            .fill(OriveoTheme.Palette.border.opacity(colorScheme == .dark ? 0.24 : 0.14))
            .frame(height: 0.7)
    }

    private func providerLogoMark(
        kind: ProviderKind,
        relayKind: RelayKind?,
        size: CGFloat
    ) -> some View {
        ProviderBadgeIcon(kind: kind, size: size * 0.70, relayKind: relayKind)
            .frame(width: size, height: size)
    }

    private func modelMicroChip(_ model: CrosscheckModelOption) -> some View {
        Text(model.modelName)
            .lineLimit(1)
            .truncationMode(.middle)
            .font(OriveoTheme.Typography.footnote.weight(.bold))
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(model.logoProviderKind.brandBackground.opacity(colorScheme == .dark ? 0.72 : 0.92))
            )
    }

    private func dockHeroLabel(title: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(OriveoTheme.Typography.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.80)
            Spacer(minLength: 8)
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
        }
    }

    // MARK: Logic

    private var availableModels: [CrosscheckModelOption] {
        NoteCrosscheckModels.availableOptions(from: appState, excluding: originalModelIdentity)
    }

    private var activeBrandColor: Color {
        guard let selectedModel else { return OriveoTheme.Palette.primary }
        return ProviderTints.tint(
            for: selectedModel.logoProviderKind.rawValue,
            fallbackId: selectedModel.providerID.uuidString
        )
    }

    private var originalModelName: String {
        switch origin {
        case .chatMessage(_, let message, _):
            return !message.modelName.isEmpty
                ? message.modelName
                : (message.modelID ?? originalProviderKind?.displayName ?? "—")
        case .note(let note):
            guard let sourceModelName = note.sourceModelName, !sourceModelName.isEmpty else {
                return note.sourceModelID ?? note.sourceProviderKind?.displayName ?? "—"
            }
            return sourceModelName
        }
    }

    private var originalAnswer: String {
        switch origin {
        case .chatMessage(_, let message, _):
            return message.text
        case .note(let note):
            return note.bodySnapshot ?? note.body
        }
    }

    private var originalAnswerPreview: String {
        let collapsed = originalAnswer
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > 220 else { return collapsed }
        return String(collapsed.prefix(220)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private var originalPrompt: String? {
        switch origin {
        case .chatMessage(_, _, let prompt):
            return prompt
        case .note(let note):
            return note.sourcePrompt
        }
    }

    private var originalProviderKind: ProviderKind? {
        switch origin {
        case .chatMessage(_, let message, _):
            if let providerID = message.providerID,
               let provider = appState.provider(for: providerID) {
                return ProviderLogoResolver.logoKind(for: provider)
            }
            return message.providerKind
        case .note(let note):
            return note.sourceProviderKind
        }
    }

    private var originalRelayKind: RelayKind? {
        switch origin {
        case .chatMessage(_, let message, _):
            guard let providerID = message.providerID,
                  let provider = appState.provider(for: providerID),
                  provider.kind == .relay,
                  ProviderLogoResolver.logoKind(for: provider) == .relay else {
                return nil
            }
            return provider.relayKind
        case .note:
            return nil
        }
    }

    private var originalModelIdentity: CrosscheckModelIdentity? {
        switch origin {
        case .chatMessage(_, let message, _):
            guard let modelID = message.modelID else { return nil }
            return CrosscheckModelIdentity(
                providerID: message.providerID,
                providerKind: message.providerKind,
                modelID: modelID
            )
        case .note(let note):
            guard let providerKind = note.sourceProviderKind,
                  let modelID = note.sourceModelID else { return nil }
            return CrosscheckModelIdentity(providerKind: providerKind, modelID: modelID)
        }
    }

    private func setupDefaultModel() {
        guard selectedModel == nil else { return }
        selectedModel = availableModels.first
    }

    private func presentModelPicker() {
        let options = availableModels
        guard !options.isEmpty else { return }
        modelPickerPresentation = CrosscheckModelPickerPresentation(
            providers: appState.providers,
            providersVersion: appState.providersVersion,
            options: options,
            selectedOption: selectedModel
        )
    }

    private func selectModel(_ option: CrosscheckModelOption) {
        guard !isRunning else { return }
        guard selectedModel != option else { return }
        selectedModel = option
        executedModel = nil
        resultText = ""
        chunkBuffer.reset()
        errorMessage = nil
    }

    private func runCheck() {
        guard let model = selectedModel else { return }
        startCheck(using: model)
    }

    private func startCheck(using model: CrosscheckModelOption) {
        cancelRun()
        isRunning = true
        errorMessage = nil
        resultText = ""
        chunkBuffer.reset()
        executedModel = model
        do {
            let stream = try appState.noteAIManager.crosscheck(
                prompt: originalPrompt,
                answer: originalAnswer,
                model: model
            )
            runTask = CrosscheckStreamTask.make(
                stream: stream,
                onChunk: { chunk in
                    // Chunks land in the buffer; only a flush past the frame gate updates the view.
                    guard let flushed = chunkBuffer.appendAndTryFlush(chunk) else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        resultText = flushed
                    }
                },
                onError: { error in
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                },
                onFinished: {
                    // The last few chunks may have been throttled away, so publish the buffer once
                    // more unconditionally.
                    let finalText = chunkBuffer.rawText
                    chunkBuffer.reset()
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        resultText = finalText
                    }
                    isRunning = false
                    runTask = nil
                }
            )
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isRunning = false
            runTask = nil
        }
    }

    private func cancelRun() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
    }

    private func saveAsNote() {
        guard let model = executedModel, !resultText.isEmpty else { return }
        if let note = appState.noteManager.createNoteFromCrosscheck(
            origin: origin,
            crosscheckModel: model,
            crosscheckText: resultText
        ) {
            dismiss()
            ToastManager.shared.show(
                NoteText.displayTitle(note.title),
                style: .success,
                duration: 4,
                actionTitle: L10n.tr("View", table: .notes)
            ) {
                appState.openNoteDetail(noteID: note.id)
            }
        }
    }
}

private struct CrosscheckHeroButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OriveoTheme.Typography.caption.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.80)
            .foregroundStyle(isEnabled ? Color.white : OriveoTheme.Palette.textTertiary)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(heroBackground)
            .overlay(heroHighlight)
            .clipShape(Capsule())
            .shadow(
                color: isEnabled ? OriveoTheme.Palette.primary.opacity(0.18) : Color.clear,
                radius: 12,
                y: 6
            )
            .opacity(configuration.isPressed ? 0.90 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: configuration.isPressed)
    }

    private var heroBackground: some View {
        Capsule()
            .fill(isEnabled ? refinedPrimaryGradient : disabledGradient)
    }

    private var refinedPrimaryGradient: LinearGradient {
        LinearGradient(
            colors: [
                OriveoTheme.Palette.primary,
                OriveoTheme.Palette.primaryPressed
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var disabledGradient: LinearGradient {
        LinearGradient(
            colors: [
                OriveoTheme.Palette.surfaceInset,
                OriveoTheme.Palette.surfaceElevated
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var heroHighlight: some View {
        Capsule()
            .strokeBorder(Color.white.opacity(isEnabled ? 0.12 : 0.06), lineWidth: 0.7)
    }
}

private struct CrosscheckDockIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textTertiary)
            .frame(width: 52, height: 52)
            .background(
                Circle()
                    .fill(OriveoTheme.Palette.surfaceElevated.opacity(isEnabled ? 0.96 : 0.58))
            )
            .overlay(
                Circle()
                    .strokeBorder(OriveoTheme.Palette.border.opacity(0.18), lineWidth: 0.7)
            )
            .shadow(
                color: OriveoTheme.Palette.shadow.opacity(isEnabled ? 0.14 : 0.06),
                radius: 8,
                y: 4
            )
            .opacity(configuration.isPressed ? 0.88 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.80), value: configuration.isPressed)
    }
}
