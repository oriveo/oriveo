import SwiftUI
import UniformTypeIdentifiers
import PDFKit

struct SkillEditView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let skillID: UUID?

    private typealias Colors = OriveoTheme.V2.Colors
    private typealias Sp = OriveoTheme.V2.Sp

    @State private var name = ""
    @State private var description = ""
    @State private var icon = "🤖"
    @State private var color = "#6d38ff"
    @State private var systemPrompt = ""
    @State private var suggestedProviderId: String?
    @State private var suggestedModelId: String?
    @State private var modelCapabilityHint = "any"
    @State private var knowledgeFiles: [SkillKnowledgeFile] = []
    @State private var knowledgeBase: SkillKnowledgeBase?
    @State private var originalKnowledgeBase: SkillKnowledgeBase?
    @State private var useMemory = true
    @State private var temperature: Double?
    @State private var reasoningLevel: String?
    @State private var webSearchEnabled: Bool?
    /// Only a record in capability_preference_sync.v1 means confirmed. Legacy Skill fields do not.
    @State private var capabilityPreferencesConfirmed = false
    @State private var initialCapabilityPreferencesConfirmed = false

    @State private var isSaving = false
    @State private var showDiscardAlert = false
    @State private var showIconInput = false
    @State private var iconInput = ""
    @State private var activeFileImportTarget: FileImportTarget?
    @State private var pendingImportTarget: FileImportTarget?
    @State private var errorMessage: String?
    @State private var showAdvanced = false
    @State private var activeTooltip: String?
    @State private var indexingPollTask: Task<Void, Never>?
    @State private var showSkillLimitSheet = false

    private var isEditing: Bool { skillID != nil }


    private var hasChanges: Bool {
        guard let existingSkill else {
            return !name.isEmpty
                || !description.isEmpty
                || icon != "🤖"
                || color != "#6d38ff"
                || !systemPrompt.isEmpty
                || !knowledgeFiles.isEmpty
                || knowledgeBase != nil
                || !useMemory
                || modelCapabilityHint != "any"
        }
        return name != existingSkill.name
            || description != existingSkill.description
            || icon != existingSkill.icon
            || color != existingSkill.color
            || systemPrompt != existingSkill.systemPrompt
            || knowledgeFiles != existingSkill.knowledgeFiles
            || normalizedCurrentKnowledgeBase != normalizedExistingKnowledgeBase
            || useMemory != existingSkill.useMemory
            || modelCapabilityHint != existingSkill.modelCapabilityHint
            || capabilityPreferencesConfirmed != initialCapabilityPreferencesConfirmed
    }

    private var existingSkill: Skill? {
        guard let skillID else { return nil }
        return appState.skillManager.skill(by: skillID)
    }

    private var capabilityPreferenceTarget: (provider: Provider, model: AIModel, skillID: UUID)? {
        guard let skillID,
              let providerID = suggestedProviderId.flatMap(UUID.init(uuidString:)),
              let provider = appState.provider(for: providerID),
              let modelID = suggestedModelId,
              let model = ProviderSelectionSnapshot.currentModel(storedModelID: modelID, in: provider) else {
            return nil
        }
        return (provider, model, skillID)
    }

    private var maxKnowledgeFiles: Int { 5 }
    private var normalizedCurrentKnowledgeBase: SkillKnowledgeBase? {
        SkillKnowledgeEditingSupport.normalizedKnowledgeBaseForComparison(knowledgeBase)
    }

    private var normalizedExistingKnowledgeBase: SkillKnowledgeBase? {
        SkillKnowledgeEditingSupport.normalizedKnowledgeBaseForComparison(originalKnowledgeBase)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && systemPrompt.count <= 4000
            && !isSaving
    }

    private let colorPalette = [
        "#6d38ff", "#4A90D9", "#50C878", "#FF6B6B",
        "#FF9F43", "#A855F7", "#EC4899", "#06B6D4",
        "#84CC16", "#F59E0B", "#6366F1", "#14B8A6"
    ]

    private let capabilityOptions = [
        ("any", "Any"),
        ("reasoning", "Reasoning"),
        ("vision", "Vision"),
        ("fast", "Fast"),
        ("large-context", "Large Context")
    ]

    private let colorColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Sp.s24) {
                navigationBar
                if let errorMessage { errorBanner(errorMessage) }
                heroSection
                instructionsSection
                knowledgeFilesSection
                advancedSection
            }
            .padding(.horizontal, Sp.s20)
            .padding(.top, Sp.s20)
            .padding(.bottom, Sp.s32)
        }
        .oriveoV2ScreenBackground()
        .onChange(of: suggestedProviderId) { _, _ in
            capabilityPreferencesConfirmed = false
        }
        .onChange(of: suggestedModelId) { _, _ in
            capabilityPreferencesConfirmed = false
        }
        .onAppear {
            loadExistingSkill()
        }

        .interactiveDismissDisabled(hasChanges)
        .alert(L10n.tr("Discard Changes?", table: .skills), isPresented: $showDiscardAlert) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Discard"), role: .destructive) {
                Task { await discardChanges() }
            }
        } message: {
            Text(L10n.tr("You have unsaved changes. Are you sure you want to discard them?", table: .skills))
        }
        .alert(L10n.tr("Emoji Icon", table: .skills), isPresented: $showIconInput) {
            TextField("🤖", text: $iconInput)
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("OK")) {
                let trimmed = iconInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if let first = trimmed.first {
                    icon = String(first)
                }
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { activeFileImportTarget != nil },
                set: { if !$0 { activeFileImportTarget = nil } }
            ),
            allowedContentTypes: activeFileImporterContentTypes,
            allowsMultipleSelection: false
        ) { result in
            let target = pendingImportTarget ?? activeFileImportTarget
            pendingImportTarget = nil
            activeFileImportTarget = nil
            handleImportedFile(result, target: target)
        }
        .alert(L10n.tr("Info", table: .skills), isPresented: Binding(
            get: { activeTooltip != nil },
            set: { if !$0 { activeTooltip = nil } }
        )) {
            Button(L10n.tr("OK")) { activeTooltip = nil }
        } message: {
            Text(activeTooltip ?? "")
        }
        .sheet(isPresented: $showSkillLimitSheet) {
            EmptyView()
        }
        .onDisappear { indexingPollTask?.cancel() }
    }

    // MARK: - Navigation Bar

    private var navigationBar: some View {
        HStack {
            Button {
                if hasChanges {
                    showDiscardAlert = true
                } else {
                    appState.pop()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Colors.textPrimary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(isEditing ? L10n.tr("Edit Skill", table: .skills) : L10n.tr("New Skill", table: .skills))
                .font(OriveoTheme.Typography.title2)
                .foregroundStyle(Colors.textPrimary)

            Spacer()

            Button {
                Task { await save() }
            } label: {
                if isSaving {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Text(L10n.tr("Save"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(canSave ? Colors.primary : Colors.textTertiary)
                }
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Sp.s8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Colors.danger)
            Text(message)
                .font(OriveoTheme.V2.Typography.caption)
                .foregroundStyle(Colors.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Sp.s16)
        .padding(.vertical, Sp.s12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Colors.danger.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Colors.danger.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Hero Section

    private var skillColor: Color { Color(hex: color) }

    private var heroSection: some View {
        GroupedCard {
            VStack(spacing: Sp.s20) {
                Button {
                    iconInput = icon
                    showIconInput = true
                } label: {
                    Text(icon)
                        .font(.system(size: 48))
                        .frame(width: 88, height: 88)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            skillColor.opacity(colorScheme == .dark ? 0.22 : 0.14),
                                            skillColor.opacity(colorScheme == .dark ? 0.08 : 0.04)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(skillColor.opacity(colorScheme == .dark ? 0.22 : 0.16), lineWidth: 1)
                        )
                        .shadow(color: skillColor.opacity(0.18), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                VStack(spacing: Sp.s8) {
                    TextField(L10n.tr("Skill Name", table: .skills), text: $name)
                        .font(.system(size: 20, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.sentences)
                        .foregroundStyle(Colors.textPrimary)
                        .onChange(of: name) { _, new in
                            if new.count > 50 { name = String(new.prefix(50)) }
                        }

                    TextField(L10n.tr("Brief description", table: .skills), text: $description)
                        .font(OriveoTheme.V2.Typography.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Colors.textSecondary)
                        .onChange(of: description) { _, new in
                            if new.count > 100 { description = String(new.prefix(100)) }
                        }
                }

                Divider()
                    .foregroundStyle(Colors.borderDefault.opacity(0.5))
                    .padding(.horizontal, Sp.s16)

                LazyVGrid(columns: colorColumns, spacing: Sp.s12) {
                    ForEach(colorPalette, id: \.self) { hex in
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 32, height: 32)
                            .overlay {
                                if hex == color {
                                    Circle()
                                        .stroke(Colors.textPrimary, lineWidth: 2.5)
                                        .frame(width: 38, height: 38)
                                }
                            }
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    color = hex
                                }
                            }
                    }
                }
            }
            .padding(Sp.s20)
        }
    }

    // MARK: - Instructions Section

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: Sp.s8) {
            sectionHeader(L10n.tr("Prompt", table: .skills), tooltip: L10n.tr("Write instructions that define how the AI behaves — its personality, expertise, and response style. Only the AI sees this, users won't.", table: .skills))

            GroupedCard {
                VStack(alignment: .leading, spacing: Sp.s8) {
                    TextEditor(text: $systemPrompt)
                        .font(OriveoTheme.V2.Typography.body)
                        .frame(minHeight: 140, maxHeight: 280)
                        .scrollContentBackground(.hidden)
                        .onChange(of: systemPrompt) { _, new in
                            if new.count > 4000 { systemPrompt = String(new.prefix(4000)) }
                        }

                    HStack {
                        Spacer()
                        Text("\(systemPrompt.count) / 4000")
                            .font(OriveoTheme.V2.Typography.footnote)
                            .foregroundStyle(
                                systemPrompt.count > 4000
                                    ? Colors.danger
                                    : Colors.textTertiary
                            )
                    }
                }
                .padding(Sp.s16)
            }
        }
    }

    // MARK: - Knowledge Files Section

    private var knowledgeFilesSection: some View {
        VStack(alignment: .leading, spacing: Sp.s8) {
            sectionHeader(L10n.tr("Reference Materials", table: .skills), tooltip: L10n.tr("The AI reads these files in full every time it replies — like notes it always has open on its desk. Best for short, essential documents (style guides, glossaries, key rules). Larger files will increase response cost.", table: .skills), trailing: "\(knowledgeFiles.count)/\(maxKnowledgeFiles)")

            GroupedCard {
                VStack(spacing: 0) {
                    if knowledgeFiles.isEmpty {
                        VStack(spacing: Sp.s8) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 24))
                                .foregroundStyle(Colors.textTertiary.opacity(0.72))
                            Text(L10n.tr("No reference materials yet", table: .skills))
                                .font(OriveoTheme.V2.Typography.caption)
                                .foregroundStyle(Colors.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Sp.s16)
                        .padding(.vertical, Sp.s20)

                        cardDivider
                    }

                    ForEach(knowledgeFiles) { file in
                        HStack(spacing: Sp.s12) {
                            Image(systemName: "doc.text.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Colors.primary)
                                .frame(width: 36, height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Colors.primarySubtle)
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .font(OriveoTheme.V2.Typography.body)
                                    .foregroundStyle(Colors.textPrimary)
                                    .lineLimit(1)
                                Text("\(file.charCount) chars")
                                    .font(OriveoTheme.V2.Typography.footnote)
                                    .foregroundStyle(Colors.textTertiary)
                            }

                            Spacer()

                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    knowledgeFiles.removeAll { $0.id == file.id }
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(Colors.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(Sp.s12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Colors.bgInset.opacity(0.6))
                        )
                        .padding(.horizontal, Sp.s12)
                        .padding(.top, index(of: file, in: knowledgeFiles) == 0 ? Sp.s12 : Sp.s4)
                        .padding(.bottom, index(of: file, in: knowledgeFiles) == knowledgeFiles.count - 1 ? Sp.s4 : 0)
                    }

                    if !knowledgeFiles.isEmpty {
                        cardDivider
                            .padding(.top, Sp.s8)
                    }

                    if knowledgeFiles.count < maxKnowledgeFiles {
                        Button {
                            pendingImportTarget = .reference
                            activeFileImportTarget = .reference
                        } label: {
                            HStack(spacing: Sp.s6) {
                                Image(systemName: "plus")
                                    .font(.system(size: 13, weight: .medium))
                                Text(L10n.tr("Add file", table: .skills))
                                    .font(OriveoTheme.V2.Typography.caption)
                            }
                            .foregroundStyle(Colors.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: Sp.s8) {
            sectionHeader(L10n.tr("Advanced"), tooltip: L10n.tr("Configure model preferences and memory injection.", table: .skills))

            GroupedCard {
                VStack(spacing: 0) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            showAdvanced.toggle()
                        }
                    } label: {
                        HStack {
                            Text(L10n.tr("Advanced Settings"))
                                .font(OriveoTheme.V2.Typography.body)
                                .foregroundStyle(Colors.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Colors.textTertiary)
                                .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                        }
                        .padding(.horizontal, Sp.s16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showAdvanced {
                        cardDivider

                        VStack(alignment: .leading, spacing: Sp.s20) {
                            VStack(alignment: .leading, spacing: Sp.s8) {
                                Text(L10n.tr("Model Preference", table: .skills))
                                    .font(OriveoTheme.V2.Typography.caption)
                                    .foregroundStyle(Colors.textSecondary)
                                Picker("", selection: $modelCapabilityHint) {
                                    ForEach(capabilityOptions, id: \.0) { option in
                                        Text(option.1).tag(option.0)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }

                            Toggle(isOn: $useMemory) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L10n.tr("Remember Preferences", table: .skills))
                                        .font(OriveoTheme.V2.Typography.body)
                                        .foregroundStyle(Colors.textPrimary)
                                    Text(L10n.tr("Include your personal preferences in conversations", table: .skills))
                                        .font(OriveoTheme.V2.Typography.footnote)
                                        .foregroundStyle(Colors.textTertiary)
                                }
                            }
                            .tint(Colors.primary)

                            if capabilityPreferenceTarget != nil {
                                Toggle(isOn: $capabilityPreferencesConfirmed) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(L10n.tr("Confirm Model Controls", table: .skills))
                                            .font(OriveoTheme.V2.Typography.body)
                                            .foregroundStyle(Colors.textPrimary)
                                        Text(L10n.tr("Apply this Skill's saved web and reasoning preferences in new Skill chats.", table: .skills))
                                            .font(OriveoTheme.V2.Typography.footnote)
                                            .foregroundStyle(Colors.textTertiary)
                                    }
                                }
                                .tint(Colors.primary)
                                .accessibilityHint(L10n.tr("Requires Save. Unconfirmed legacy Skill preferences inherit the chat defaults.", table: .skills))
                            }

                        }
                        .padding(.horizontal, Sp.s16)
                        .padding(.vertical, Sp.s16)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
    }

    // MARK: - Shared Components

    private func sectionHeader(_ title: String, tooltip: String? = nil, trailing: String? = nil) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Colors.primary.opacity(0.5))
                .frame(width: 3, height: 14)

            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Colors.textTertiary)

            if tooltip != nil {
                Button {
                    activeTooltip = tooltip
                } label: {
                    Text("?")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Colors.textTertiary)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .stroke(Colors.textTertiary.opacity(0.4), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if let trailing {
                Text(trailing)
                    .font(OriveoTheme.V2.Typography.footnote)
                    .foregroundStyle(Colors.textTertiary)
            }
        }
    }

    private func index<T: Identifiable>(of item: T, in collection: [T]) -> Int {
        collection.firstIndex(where: { $0.id == item.id }) ?? 0
    }

    private var cardDivider: some View {
        Divider()
            .foregroundStyle(Colors.borderDefault.opacity(0.5))
            .padding(.horizontal, 16)
    }

    private func inlineActionButton(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(OriveoTheme.V2.Typography.footnote)
                .foregroundStyle(disabled ? Colors.textTertiary : Colors.primary)
                .padding(.horizontal, Sp.s12)
                .padding(.vertical, Sp.s8)
                .background(
                    Capsule(style: .continuous)
                        .fill(disabled ? Colors.bgInset : Colors.primarySubtle)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: - Load

    private func loadExistingSkill() {
        originalKnowledgeBase = nil
        guard let skill = existingSkill else { return }
        name = skill.name
        description = skill.description
        icon = skill.icon
        color = skill.color
        systemPrompt = skill.systemPrompt
        suggestedProviderId = skill.suggestedProviderId
        suggestedModelId = skill.suggestedModelId
        modelCapabilityHint = skill.modelCapabilityHint
        knowledgeFiles = skill.knowledgeFiles
        knowledgeBase = skill.knowledgeBase
        originalKnowledgeBase = skill.knowledgeBase
        useMemory = skill.useMemory
        temperature = skill.temperature
        reasoningLevel = skill.reasoningLevel
        webSearchEnabled = skill.webSearchEnabled
        if let target = capabilityPreferenceTarget {
            let runtimeIdentity = CapabilityPreferenceRuntimeIdentity.make(provider: target.provider, model: target.model)
            capabilityPreferencesConfirmed = GenerationParameterSettingsStore.shared
                .isSkillAgentCapabilityConfirmed(
                    providerID: target.provider.id,
                    modelID: runtimeIdentity?.canonicalModelID ?? "",
                    skillID: target.skillID,
                    transportIdentity: runtimeIdentity?.wireValue ?? ""
                )
        } else {
            capabilityPreferencesConfirmed = false
        }
        initialCapabilityPreferencesConfirmed = capabilityPreferencesConfirmed
    }

    // MARK: - Save

    private func save() async {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }

        do {
            var body = try SkillKnowledgeEditingSupport.buildSaveBody(from: SkillEditDraft(
                name: name,
                description: description,
                icon: icon,
                color: color,
                systemPrompt: systemPrompt,
                suggestedProviderId: suggestedProviderId,
                suggestedModelId: suggestedModelId,
                modelCapabilityHint: modelCapabilityHint,
                starterMessages: [],
                knowledgeFiles: knowledgeFiles,
                knowledgeBase: knowledgeBase,
                useMemory: useMemory,
                temperature: temperature,
                reasoningLevel: reasoningLevel,
                webSearchEnabled: webSearchEnabled
            ))
            if let skillID {
                if SkillKnowledgeEditingSupport.requiresRemoteKnowledgeCleanup(
                    originalKnowledgeBase: originalKnowledgeBase,
                    currentKnowledgeBase: knowledgeBase
                ) {
                    guard let openAIProvider else {
                        errorMessage = localizedKnowledgeError(.openAINotConfigured)
                        return
                    }
                    var cleanupBody: [String: Any] = ["apiKey": openAIProvider.apiKey]
                    if let baseURL = openAIProvider.baseURLText,
                       !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        cleanupBody["baseURL"] = baseURL
                    }
                    body["knowledgeCleanup"] = cleanupBody
                }
                _ = try await appState.skillManager.updateSkill(skillID, body)
                persistConfirmedCapabilityPreferencesIfNeeded()
            } else {
                _ = try await appState.skillManager.createSkill(body)
            }
            appState.pop()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The confirmation is intentionally local typed sync state, not an optimistic undocumented
    /// field in the Skill API body. A missing record remains inherit on every device.
    private func persistConfirmedCapabilityPreferencesIfNeeded() {
        guard let target = capabilityPreferenceTarget else { return }
        guard let runtimeIdentity = CapabilityPreferenceRuntimeIdentity.make(
            provider: target.provider, model: target.model
        ) else { return }
        if capabilityPreferencesConfirmed {
            GenerationParameterSettingsStore.shared.confirmSkillAgentCapabilityPreferences(
                .init(
                    web: webSearchEnabled == true ? .automatic : .off,
                    reasoningIntent: reasoningLevel
                ),
                skillID: target.skillID,
                providerID: target.provider.id,
                modelID: runtimeIdentity.canonicalModelID,
                transportIdentity: runtimeIdentity.wireValue
            )
        } else if initialCapabilityPreferencesConfirmed {
            GenerationParameterSettingsStore.shared.setCapabilityPreferences(
                nil,
                providerID: target.provider.id,
                modelID: runtimeIdentity.canonicalModelID,
                conversationID: nil,
                skillID: target.skillID,
                transportIdentity: runtimeIdentity.wireValue
            )
        }
    }

    private func discardChanges() async {
        appState.pop()
    }

    // MARK: - Knowledge Support

    private struct ImportedFileSource: Sendable {
        let data: Data
        let fileName: String
        let mimeType: String
        let sizeBytes: Int
    }

    private enum FileImportTarget {
        case reference
    }

    private var activeFileImporterContentTypes: [UTType] {
        SkillKnowledgeEditingSupport.referenceFileContentTypes
    }

    private var openAIProvider: Provider? {
        appState.providers.first {
            $0.kind == .openAI && !$0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var hasOpenRouterProvider: Bool {
        appState.providers.contains {
            $0.kind == .openRouter && (
                !$0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !$0.apiKeyPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
    }

    private var hasOpenAIProvider: Bool {
        openAIProvider != nil
    }

    private func localizedKnowledgeError(
        _ code: SkillKnowledgeErrorCode,
        requiredModel: String? = nil
    ) -> String {
        if code == .retrievalModelNotEnabled, let requiredModel, !requiredModel.isEmpty {
            return String(
                format: L10n.tr("Enable %@ in your OpenAI provider to use Knowledge Base.", table: .skills),
                requiredModel
            )
        }
        return L10n.tr(code.rawValue)
    }

    private func resolveKnowledgeErrorCode(from error: Error, fallback: SkillKnowledgeErrorCode) -> SkillKnowledgeErrorCode {
        if let providerError = error as? ProviderServiceError,
           let resolved = decodeKnowledgeErrorCode(from: providerError.technicalDetail) {
            return resolved
        }
        if let resolved = decodeKnowledgeErrorCode(from: error.localizedDescription) {
            return resolved
        }
        return fallback
    }

    private func localizedKnowledgeOperationError(
        _ error: Error,
        fallback: SkillKnowledgeErrorCode
    ) -> String {
        return localizedKnowledgeError(resolveKnowledgeErrorCode(from: error, fallback: fallback))
    }

    private func decodeKnowledgeErrorCode(from detail: String) -> SkillKnowledgeErrorCode? {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = SkillKnowledgeErrorCode(rawValue: trimmed) {
            return direct
        }

        struct ErrorEnvelope: Decodable {
            struct ErrorData: Decodable {
                let error: String?
            }

            let data: ErrorData?
            let error: ErrorData?
        }

        guard let data = trimmed.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) else {
            return nil
        }

        if let nested = envelope.data?.error, let code = SkillKnowledgeErrorCode(rawValue: nested) {
            return code
        }
        if let top = envelope.error?.error, let code = SkillKnowledgeErrorCode(rawValue: top) {
            return code
        }
        return nil
    }

    // MARK: - File Import

    private func handleImportedFile(_ result: Result<[URL], Error>, target: FileImportTarget?) {
        guard target == .reference else { return }
        handleReferenceFileImport(result)
    }

    private func handleReferenceFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            Task.detached(priority: .userInitiated) {
                do {
                    let source = try SecurityScopedFileAccess.withAccess(to: url) {
                        try Self.loadImportedFileSource(
                            from: url,
                            maxBytes: SkillKnowledgeEditingSupport.maxReferenceFileSize
                        )
                    }
                    if let sizeError = SkillKnowledgeEditingSupport.validateReferenceFileSize(source.sizeBytes) {
                        await MainActor.run { errorMessage = localizedKnowledgeError(sizeError) }
                        return
                    }

                    let content: String
                    let sourceType: SkillKnowledgeFileSourceType
                    let ext = url.pathExtension.lowercased()
                    if ext == "pdf" {
                        let document = try SecurityScopedFileAccess.withAccess(to: url) {
                            PDFDocument(url: url)
                        }
                        guard let document else {
                            await MainActor.run { errorMessage = L10n.tr("Unsupported file format") }
                            return
                        }
                        var text = ""
                        for index in 0..<document.pageCount {
                            if let page = document.page(at: index), let pageText = page.string {
                                if !text.isEmpty { text += "\n" }
                                text += pageText
                            }
                        }
                        content = text
                        sourceType = .pdfText
                    } else if OfficeTextExtractor.isOfficeFile(extension: ext) {
                        guard let officeText = try OfficeTextExtractor.extractText(from: source.data, fileExtension: ext) else {
                            await MainActor.run { errorMessage = L10n.tr("Unsupported file format") }
                            return
                        }
                        content = officeText
                        sourceType = .text
                    } else {
                        guard let text = String(data: source.data, encoding: .utf8) else {
                            await MainActor.run { errorMessage = L10n.tr("Unsupported file format") }
                            return
                        }
                        content = text
                        sourceType = .text
                    }

                    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        await MainActor.run { errorMessage = L10n.tr("File is empty", table: .skills) }
                        return
                    }

                    let file = SkillKnowledgeEditingSupport.buildReferenceKnowledgeFile(
                        name: source.fileName,
                        mimeType: source.mimeType,
                        sourceType: sourceType,
                        content: content
                    )

                    await MainActor.run {
                        errorMessage = nil
                        knowledgeFiles.append(file)
                    }
                } catch BoundedFileReadError.tooLarge {
                    await MainActor.run {
                        errorMessage = localizedKnowledgeError(.referenceFileTooLarge)
                    }
                } catch is BoundedFileReadError {
                    await MainActor.run { errorMessage = L10n.tr("Unsupported file format") }
                } catch {
                    await MainActor.run { errorMessage = error.localizedDescription }
                }
            }
        case .failure(let error):
            if (error as? CocoaError)?.code != .userCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func loadImportedFileSource(from url: URL, maxBytes: Int) throws -> ImportedFileSource {
        let resourceValues = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        let data = try BoundedFileReader.data(at: url, maxBytes: maxBytes)
        let mimeType = resourceValues.contentType?.preferredMIMEType
            ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"

        return ImportedFileSource(
            data: data,
            fileName: url.lastPathComponent,
            mimeType: mimeType,
            sizeBytes: resourceValues.fileSize ?? data.count
        )
    }
}
