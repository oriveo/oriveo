import SwiftUI

struct SkillsListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""
    @State private var skillToDelete: Skill?
    @State private var isLoading = false
    @State private var activeCategory = "__all__"
    @State private var hasAppeared = false
    @FocusState private var isSearchFocused: Bool

    private typealias Colors = OriveoTheme.V2.Colors
    private typealias Sp = OriveoTheme.V2.Sp

    private var skillManager: SkillManager { appState.skillManager }

    private var showSearchBar: Bool {
        skillManager.totalSkillCount > 15
    }

    private var openAIProviderForKnowledgeCleanup: Provider? {
        appState.providers.first {
            $0.kind == .openAI && !$0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func localizedDeleteErrorMessage(_ detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = SkillKnowledgeErrorCode(rawValue: trimmed) {
            return L10n.tr(code.rawValue)
        }

        let knownCodes = [
            SkillKnowledgeErrorCode.openAINotConfigured,
            .openAIEndpointNotOfficial,
            .knowledgeCleanupFailed,
        ]
        if let matched = knownCodes.first(where: { trimmed.contains($0.rawValue) }) {
            return L10n.tr(matched.rawValue)
        }
        return detail
    }

    private var filteredUserSkills: [Skill] {
        guard !searchText.isEmpty else { return skillManager.userSkills }
        let query = searchText.lowercased()
        return skillManager.userSkills.filter {
            $0.name.lowercased().contains(query) || $0.description.lowercased().contains(query)
        }
    }

    private var filteredCatalogByCategory: [(category: SkillCategory, skills: [Skill])] {
        guard !searchText.isEmpty else { return skillManager.catalogByCategory }
        let query = searchText.lowercased()
        return skillManager.catalogByCategory.compactMap { item in
            let filtered = item.skills.filter {
                $0.name.lowercased().contains(query) || $0.description.lowercased().contains(query)
            }
            guard !filtered.isEmpty else { return nil }
            return (category: item.category, skills: filtered)
        }
    }

    private var visibleCatalogSkills: [Skill] {
        if activeCategory == "__all__" {
            return filteredCatalogByCategory.flatMap(\.skills)
        }
        return filteredCatalogByCategory.first { $0.category.id == activeCategory }?.skills ?? []
    }

    private let cardColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Sp.s24) {
                navigationBar

                if showSearchBar {
                    searchBar
                }

                mySkillsSection

                if !filteredCatalogByCategory.isEmpty {
                    builtInSkillsSection
                }
            }
            .padding(.horizontal, Sp.s20)
            .padding(.top, Sp.s20)
            .padding(.bottom, Sp.s32)
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 8)
        }
        .oriveoV2ScreenBackground()
        .onAppear {
            guard !hasAppeared else { return }
            withAnimation(.easeOut(duration: 0.45)) {
                hasAppeared = true
            }
        }
        .alert(
            L10n.tr("Delete Skill?", table: .skills),
            isPresented: Binding(
                get: { skillToDelete != nil },
                set: { if !$0 { skillToDelete = nil } }
            )
        ) {
            Button(L10n.tr("Cancel"), role: .cancel) { skillToDelete = nil }
            Button(L10n.tr("Delete"), role: .destructive) {
                if let skill = skillToDelete {
                    Task {
                        do {
                            try await skillManager.deleteSkill(skill.id)
                        } catch {
                            ToastManager.shared.show(localizedDeleteErrorMessage(error.localizedDescription))
                        }
                    }
                    skillToDelete = nil
                }
            }
        } message: {
            Text(L10n.tr("This Skill will be permanently deleted.", table: .skills))
        }
    }

    // MARK: - Navigation Bar

    private var navigationBar: some View {
        HStack(spacing: 0) {
            navToneButton(systemName: "chevron.left", tint: Colors.textPrimary) {
                appState.pop()
            }

            Spacer()

            Text(L10n.tr("Skills"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Colors.textPrimary)

            Spacer()

            navToneButton(systemName: "plus", tint: Colors.primary) {
                appState.openSkillEdit()
            }
        }
    }

    private func navToneButton(systemName: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Colors.bgInset)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Colors.borderSubtle, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isSearchFocused ? Colors.primary : Colors.textTertiary)
            TextField(L10n.tr("Search Skills", table: .skills), text: $searchText)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(Colors.textPrimary)
                .focused($isSearchFocused)
            if !searchText.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { searchText = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Colors.textTertiary.opacity(0.8))
                        .contentShape(Rectangle())
                        .padding(.leading, 4)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSearchFocused ? Colors.surfaceDefault : Colors.bgInset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSearchFocused ? Colors.primary.opacity(0.55) : Colors.borderDefault,
                    lineWidth: isSearchFocused ? 1.5 : 1
                )
        )
        .shadow(
            color: isSearchFocused ? Colors.primary.opacity(0.18) : .clear,
            radius: 12,
            y: 4
        )
        .animation(.easeOut(duration: 0.18), value: isSearchFocused)
        .animation(.easeOut(duration: 0.15), value: searchText.isEmpty)
    }

    // MARK: - My Skills Section

    private var mySkillsSection: some View {
        VStack(alignment: .leading, spacing: Sp.s12) {
            sectionHeader(L10n.tr("My Skills", table: .skills))

            if filteredUserSkills.isEmpty {
                emptyStateCard
            } else {
                LazyVGrid(columns: cardColumns, spacing: 12) {
                    ForEach(Array(filteredUserSkills.enumerated()), id: \.element.id) { index, skill in
                        SkillCardView(skill: skill, colorScheme: colorScheme, index: index) {
                            appState.startConversationWithSkill(skill)
                        }
                        .contextMenu { skillContextMenu(skill) }
                    }
                }
            }
        }
    }

    private var emptyStateCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Colors.primary.opacity(colorScheme == .dark ? 0.18 : 0.10))
                    .frame(width: 64, height: 64)
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Colors.primary)
            }

            Text(L10n.tr("No custom Skills yet", table: .skills))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Colors.textPrimary)

            Button {
                appState.openSkillEdit()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                    Text(L10n.tr("Create your first Skill", table: .skills))
                        .font(.system(size: 13.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(LinearGradient(
                            colors: [Colors.primary, Colors.primary.opacity(0.88)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                )
                .shadow(color: Colors.primary.opacity(colorScheme == .dark ? 0.35 : 0.28), radius: 12, y: 6)
            }
            .buttonStyle(PressableCardStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 20)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Colors.surfaceDefault)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(LinearGradient(
                            colors: [
                                Colors.primary.opacity(colorScheme == .dark ? 0.09 : 0.05),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .center
                        ))
                }
                .overlay {
                    RadialGradient(
                        colors: [
                            Colors.primary.opacity(colorScheme == .dark ? 0.18 : 0.10),
                            .clear
                        ],
                        center: UnitPoint(x: 0.9, y: 0.0),
                        startRadius: 0,
                        endRadius: 180
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Colors.borderDefault, lineWidth: 1)
        }
        .cardShine(cornerRadius: 20)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.05), radius: 10, y: 4)
    }

    // MARK: - Built-in Skills Section

    private var builtInSkillsSection: some View {
        VStack(alignment: .leading, spacing: Sp.s12) {
            sectionHeader(L10n.tr("Built-in Skills", table: .skills))

            if filteredCatalogByCategory.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Sp.s8) {
                        filterPill(
                            label: L10n.tr("All"),
                            icon: nil,
                            count: filteredCatalogByCategory.reduce(0) { $0 + $1.skills.count },
                            isActive: activeCategory == "__all__"
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                activeCategory = "__all__"
                            }
                        }

                        ForEach(filteredCatalogByCategory, id: \.category.id) { item in
                            filterPill(
                                label: item.category.localizedName,
                                icon: item.category.icon,
                                count: item.skills.count,
                                isActive: activeCategory == item.category.id
                            ) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    activeCategory = item.category.id
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            LazyVGrid(columns: cardColumns, spacing: 12) {
                ForEach(Array(visibleCatalogSkills.enumerated()), id: \.element.id) { index, skill in
                    SkillCardView(skill: skill, colorScheme: colorScheme, index: index) {
                        appState.startConversationWithSkill(skill)
                    }
                    .contextMenu { skillContextMenu(skill) }
                }
            }
        }
    }

    // MARK: - Filter Pill

    private func filterPill(label: String, icon: String?, count: Int, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Text(icon)
                        .font(.system(size: 13))
                }
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 11.5, weight: .medium))
                    .opacity(isActive ? 0.75 : 0.55)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(isActive ? .white : Colors.textSecondary)
            .background(
                Capsule(style: .continuous)
                    .fill(isActive
                        ? AnyShapeStyle(LinearGradient(
                            colors: [Colors.primary, Colors.primary.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        : AnyShapeStyle(Colors.surfaceDefault))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(isActive ? Color.clear : Colors.borderDefault, lineWidth: 1)
            )
        }
        .buttonStyle(PressableCardStyle())
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func skillContextMenu(_ skill: Skill) -> some View {
        Button {
            appState.startConversationWithSkill(skill)
        } label: {
            Label(L10n.tr("Use this Skill", table: .skills), systemImage: "play")
        }

        Button {
            _ = skillManager.togglePin(skill.id)
        } label: {
            Label(
                skill.isPinned ? L10n.tr("Unpin", table: .skills) : L10n.tr("Pin to Home", table: .skills),
                systemImage: skill.isPinned ? "pin.slash" : "pin"
            )
        }

        if skill.isEditable {
            Button {
                appState.openSkillEdit(skillID: skill.id)
            } label: {
                Label(L10n.tr("Edit"), systemImage: "pencil")
            }
        }

        Button {
            Task {

                if let forked = try? await skillManager.forkSkill(skill.id) {
                    appState.openSkillEdit(skillID: forked.id)
                }
            }
        } label: {
            Label(L10n.tr("Fork as My Skill", table: .skills), systemImage: "doc.on.doc")
        }

        if skill.isEditable {
            Divider()
            Button(role: .destructive) {
                skillToDelete = skill
            } label: {
                Label(L10n.tr("Delete"), systemImage: "trash")
            }
        }
    }

    // MARK: - Shared Components

    private func sectionHeader(_ title: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Colors.primary)
                .frame(width: 3, height: 14)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Colors.textPrimary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Pressable Card Style

private struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Skill Card View

private struct SkillCardView: View {
    let skill: Skill
    let colorScheme: ColorScheme
    let index: Int
    let onUse: () -> Void

    private typealias Colors = OriveoTheme.V2.Colors

    private var skillColor: Color { Color(hex: skill.color) }

    private var iconBackgroundOpacity: Double {
        colorScheme == .dark ? 0.28 : 0.16
    }

    private var iconStrokeOpacity: Double {
        colorScheme == .dark ? 0.42 : 0.30
    }

    private var ctaBackgroundOpacity: Double {
        colorScheme == .dark ? 0.18 : 0.10
    }

    private var washTopOpacity: Double {
        colorScheme == .dark ? 0.10 : 0.06
    }

    private var washBottomOpacity: Double {
        colorScheme == .dark ? 0.02 : 0.012
    }

    var body: some View {
        Button(action: onUse) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 0) {
                    iconBlock

                    Spacer(minLength: 0)

                    if skill.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Colors.primary)
                            .frame(width: 24, height: 24)
                            .background(
                                Circle().fill(Colors.primarySubtle)
                            )
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.localizedName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Colors.textPrimary)
                        .lineLimit(1)

                    if !skill.localizedDescription.isEmpty {
                        Text(skill.localizedDescription)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Colors.textSecondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 5) {
                    Text(L10n.tr("Use this Skill", table: .skills))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Colors.textPrimary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(skillColor)
                        .opacity(0.9)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(skillColor.opacity(ctaBackgroundOpacity))
                )
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Colors.surfaceDefault)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(LinearGradient(
                                colors: [
                                    skillColor.opacity(washTopOpacity),
                                    skillColor.opacity(washBottomOpacity)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Colors.borderDefault, lineWidth: 1)
            )
            .cardShine(cornerRadius: 18)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.05), radius: 10, y: 4)
        }
        .buttonStyle(PressableCardStyle())
    }

    private var iconBlock: some View {
        Text(skill.icon)
            .font(.system(size: 28))
            .frame(width: 52, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(skillColor.opacity(iconBackgroundOpacity))
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(colorScheme == .dark ? 0.10 : 0.60),
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .center
                                ),
                                lineWidth: 1
                            )
                    }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(skillColor.opacity(iconStrokeOpacity), lineWidth: 1)
            )
    }
}
