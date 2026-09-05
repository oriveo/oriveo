package ai.oriveo.community.feature.skills

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.ui.semantics.Role
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.data.repository.KnowledgeCleanupInput
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.SkillCategory
import ai.oriveo.community.core.util.SkillL10n
import ai.oriveo.community.core.util.localizedDescription
import ai.oriveo.community.core.util.localizedName
import ai.oriveo.community.ui.theme.OriveoScreenBackground
import ai.oriveo.community.ui.theme.OriveoTheme
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.koin.androidx.compose.koinViewModel

private fun parseColor(hex: String): Color {
    val clean = hex.removePrefix("#")
    return try {
        Color(android.graphics.Color.parseColor("#$clean"))
    } catch (_: Exception) {
        Color(0xFF6D38FF)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SkillsListScreen(
    onBack: () -> Unit,
    onNavigateToChat: (String) -> Unit,
    onNavigateToEdit: (String?) -> Unit,
    onNavigateToProviderSetup: () -> Unit,
    viewModel: SkillViewModel = koinViewModel(),
) {
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing
    val layout = OriveoTheme.layout
    val typography = OriveoTheme.typography
    val isDark = OriveoTheme.isDark

    val catalogSkills by viewModel.catalogSkills.collectAsState()
    val userSkills by viewModel.userSkills.collectAsState()
    val categories by viewModel.categories.collectAsState()
    val openAIProvider by viewModel.openAIKnowledgeProvider.collectAsState()

    var deleteErrorMessage by remember { mutableStateOf<String?>(null) }
    var searchText by rememberSaveable { mutableStateOf("") }
    var activeCategory by rememberSaveable { mutableStateOf("__all__") }
    var hasAppeared by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { hasAppeared = true }
    val pageAlpha by animateFloatAsState(
        targetValue = if (hasAppeared) 1f else 0f,
        animationSpec = tween(450, easing = FastOutSlowInEasing),
        label = "skills_page_alpha",
    )
    val pageTranslate by animateFloatAsState(
        targetValue = if (hasAppeared) 0f else 24f,
        animationSpec = tween(450, easing = FastOutSlowInEasing),
        label = "skills_page_translate",
    )
    val knowledgeOpenAIError = stringResource(R.string.skills_knowledgeErrorOpenAI)
    val knowledgeEndpointError = stringResource(R.string.skills_knowledgeErrorEndpoint)
    val knowledgeCleanupError = stringResource(R.string.skills_knowledgeErrorCleanupFailed)

    fun localizeDeleteError(message: String): String = when (message.trim()) {
        "openai_not_configured" -> knowledgeOpenAIError
        "openai_endpoint_not_official" -> knowledgeEndpointError
        "knowledge_cleanup_failed" -> knowledgeCleanupError
        else -> message
    }

    val showSearchBar = remember(catalogSkills, userSkills) {
        catalogSkills.size + userSkills.size > 15
    }

    // Search filtering: hoist name/description.lowercase() into remember(userSkills/catalogSkills)
    // so it's computed once; when searchText changes we just reuse that precomputed lower table
    // plus a single q.lowercase(), avoiding two lowercase() passes over every Skill per keystroke.
    val userSkillSearchIndex = remember(userSkills) {
        userSkills.map { skill ->
            skill to (skill.name.lowercase() + "\u0000" + skill.description.lowercase())
        }
    }
    val filteredUserSkills by remember(userSkillSearchIndex, searchText) {
        derivedStateOf {
            if (searchText.isBlank()) userSkillSearchIndex.map { it.first }
            else {
                val q = searchText.lowercase()
                userSkillSearchIndex.mapNotNull { (skill, haystack) ->
                    skill.takeIf { haystack.contains(q) }
                }
            }
        }
    }

    val sortedCategoriesById = remember(categories) {
        categories.sortedBy { it.sortOrder }.associateBy { it.id }
    }
    val catalogSearchIndex = remember(catalogSkills) {
        catalogSkills.map { skill ->
            skill to (skill.name.lowercase() + "\u0000" + skill.description.lowercase())
        }
    }
    val catalogByCategory by remember(catalogSearchIndex, sortedCategoriesById, searchText) {
        derivedStateOf {
            val filtered = if (searchText.isBlank()) catalogSearchIndex.map { it.first }
            else {
                val q = searchText.lowercase()
                catalogSearchIndex.mapNotNull { (skill, haystack) ->
                    skill.takeIf { haystack.contains(q) }
                }
            }
            filtered
                .groupBy { it.category ?: "other" }
                .entries
                .sortedBy { sortedCategoriesById[it.key]?.sortOrder ?: 999 }
                .map { (catId, skills) -> sortedCategoriesById[catId] to skills }
                .filter { it.second.isNotEmpty() }
        }
    }

    val visibleCatalogSkills by remember(catalogByCategory, activeCategory) {
        derivedStateOf {
            if (activeCategory == "__all__") catalogByCategory.flatMap { it.second }
            else catalogByCategory.firstOrNull { it.first?.id == activeCategory }?.second ?: emptyList()
        }
    }

    val handleUseSkill: (Skill) -> Unit = { skill ->
        viewModel.startConversationWithSkill(
            skill = skill,
            onCreated = onNavigateToChat,
        )
    }

    Box(modifier = Modifier.fillMaxSize()) {
        OriveoScreenBackground()

        Scaffold(
            containerColor = Color.Transparent,
            topBar = {
                TopAppBar(
                    title = {
                        Text(
                            text = stringResource(R.string.skills_title),
                            fontSize = 17.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = colors.textPrimary,
                        )
                    },
                    navigationIcon = {
                        Spacer(Modifier.width(8.dp))
                        NavToneButton(
                            icon = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.back),
                            tint = colors.textPrimary,
                            onClick = onBack,
                        )
                    },
                    actions = {
                        NavToneButton(
                            icon = Icons.Default.Add,
                            contentDescription = stringResource(R.string.skills_newSkill),
                            tint = colors.primary,
                            onClick = { onNavigateToEdit(null) },
                        )
                        Spacer(Modifier.width(8.dp))
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
                )
            },
        ) { padding ->
            LazyVerticalGrid(
                columns = GridCells.Fixed(2),
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .graphicsLayer {
                        alpha = pageAlpha
                        translationY = pageTranslate
                    },
                contentPadding = PaddingValues(
                    start = layout.screenH,
                    end = layout.screenH,
                    bottom = spacing.xxl,
                ),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                // ── Search Bar ──
                if (showSearchBar) {
                    item(span = { GridItemSpan(2) }) {
                        SearchBar(
                            value = searchText,
                            onValueChange = { searchText = it },
                        )
                    }
                }

                // ── My Skills Section ──
                item(span = { GridItemSpan(2) }) {
                    SectionLabel(
                        text = stringResource(R.string.skills_mySkills),
                    )
                }

                if (filteredUserSkills.isEmpty()) {
                    item(span = { GridItemSpan(2) }) {
                        EmptyUserSkills(onCreateFirst = {
                            onNavigateToEdit(null)
                        })
                    }
                } else {
                    items(
                        items = filteredUserSkills,
                        key = { "user_${it.id}" },
                        contentType = { "skill_card" },
                    ) { skill ->
                        SkillCardView(
                            skill = skill,
                            isDark = isDark,
                            onUse = { handleUseSkill(skill) },
                            onEdit = { onNavigateToEdit(skill.id) },
                            onDelete = { viewModel.skillToDelete = skill },
                            onTogglePin = { viewModel.togglePin(skill) },
                            onFork = null,
                        )
                    }
                }

                // ── Built-in Skills Section ──
                if (catalogByCategory.isNotEmpty()) {
                    item(span = { GridItemSpan(2) }) {
                        Spacer(Modifier.height(spacing.md))
                        SectionLabel(stringResource(R.string.skills_builtinSkills))
                    }

                    // Filter pills (Android follows Material's standard, pills clip naturally;
                    // no fade edge mask -- BlendMode.DstOut in Compose leaves a faint purple
                    // ghost on the leading pill's edge)
                    if (catalogByCategory.size > 1) {
                        item(span = { GridItemSpan(2) }) {
                            LazyRow(
                                horizontalArrangement = Arrangement.spacedBy(spacing.sm),
                                contentPadding = PaddingValues(vertical = 2.dp),
                            ) {
                                // "All" pill
                                item(key = "filter_all") {
                                    FilterPill(
                                        label = stringResource(R.string.skills_all),
                                        icon = null,
                                        count = catalogByCategory.sumOf { it.second.size },
                                        isActive = activeCategory == "__all__",
                                        onClick = { activeCategory = "__all__" },
                                    )
                                }
                                items(
                                    items = catalogByCategory,
                                    key = { "filter_${it.first?.id ?: "other"}" },
                                ) { (cat, skills) ->
                                    val catId = cat?.id ?: "other"
                                    val nameResId = SkillL10n.categoryNameRes(catId)
                                    val localizedName = if (nameResId != null) {
                                        stringResource(nameResId)
                                    } else {
                                        cat?.name ?: catId
                                    }
                                    FilterPill(
                                        label = localizedName,
                                        icon = cat?.icon,
                                        count = skills.size,
                                        isActive = activeCategory == catId,
                                        onClick = { activeCategory = catId },
                                    )
                                }
                            }
                        }
                    }

                    // Card grid
                    items(
                        items = visibleCatalogSkills,
                        key = { "builtin_${it.id}" },
                        contentType = { "skill_card" },
                    ) { skill ->
                        SkillCardView(
                            skill = skill,
                            isDark = isDark,
                            onUse = { handleUseSkill(skill) },
                            onEdit = null,
                            onDelete = null,
                            onTogglePin = { viewModel.togglePin(skill) },
                            onFork = {
                                viewModel.forkSkill(
                                    skill.id,
                                    onSuccess = { forked -> onNavigateToEdit(forked.id) },
                                    onError = {},
                                )
                            },
                        )
                    }
                }
            }
        }

        // ── Delete Dialog ──
        viewModel.skillToDelete?.let { skill ->
            AlertDialog(
                onDismissRequest = { viewModel.skillToDelete = null },
                title = {
                    Text(stringResource(R.string.skills_deleteConfirmTitle, skill.localizedName()))
                },
                text = {
                    Text(stringResource(R.string.skills_deleteConfirm))
                },
                confirmButton = {
                    TextButton(onClick = {
                        val requiresKnowledgeCleanup = skill.knowledgeBase?.let { knowledgeBase ->
                            knowledgeBase.vectorStoreId.isNotBlank() || knowledgeBase.files.any {
                                !it.openAIFileId.isNullOrBlank()
                            }
                        } == true
                        val cleanup = if (requiresKnowledgeCleanup) {
                            val provider = openAIProvider
                            if (provider == null) {
                                deleteErrorMessage = knowledgeOpenAIError
                                viewModel.skillToDelete = null
                                return@TextButton
                            }
                            KnowledgeCleanupInput(
                                apiKey = provider.apiKey,
                                baseURL = provider.baseUrlText?.takeIf(String::isNotBlank),
                            )
                        } else {
                            null
                        }

                        viewModel.deleteSkill(
                            id = skill.id,
                            knowledgeCleanup = cleanup,
                            onError = { deleteErrorMessage = localizeDeleteError(it) },
                        )
                    }) {
                        Text(
                            stringResource(R.string.delete),
                            color = MaterialTheme.colorScheme.error,
                        )
                    }
                },
                dismissButton = {
                    TextButton(onClick = { viewModel.skillToDelete = null }) {
                        Text(stringResource(R.string.cancel))
                    }
                },
            )
        }

        deleteErrorMessage?.let { message ->
            AlertDialog(
                onDismissRequest = { deleteErrorMessage = null },
                text = { Text(message) },
                confirmButton = {
                    TextButton(onClick = { deleteErrorMessage = null }) {
                        Text(stringResource(R.string.cancel))
                    }
                },
            )
        }

        // ── Login Prompt ──


        if (viewModel.showSkillProviderPrompt) {
            AlertDialog(
                onDismissRequest = viewModel::dismissSkillProviderPrompt,
                title = { Text(stringResource(R.string.skills_providerRequiredTitle)) },
                text = { Text(stringResource(R.string.skills_providerRequiredMessage)) },
                confirmButton = {
                    TextButton(onClick = {
                        viewModel.dismissSkillProviderPrompt()
                        onNavigateToProviderSetup()
                    }) {
                        Text(stringResource(R.string.skills_addProvider))
                    }
                },
                dismissButton = {
                    TextButton(onClick = viewModel::dismissSkillProviderPrompt) {
                        Text(stringResource(R.string.cancel))
                    }
                },
            )
        }

    }
}

// ── Search Bar ──

@Composable
private fun SearchBar(value: String, onValueChange: (String) -> Unit) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(14.dp)

    val interactionSource = remember { MutableInteractionSource() }
    val isFocused by interactionSource.collectIsFocusedAsState()

    val animatedBorder by animateColorAsState(
        targetValue = if (isFocused) colors.primary.copy(alpha = 0.55f) else colors.border,
        animationSpec = tween(180),
        label = "search_border",
    )
    val animatedBg by animateColorAsState(
        targetValue = if (isFocused) colors.surface else colors.surfaceInset,
        animationSpec = tween(180),
        label = "search_bg",
    )
    val iconTint by animateColorAsState(
        targetValue = if (isFocused) colors.primary else colors.textTertiary,
        animationSpec = tween(180),
        label = "search_icon",
    )

    val baseModifier = Modifier
        .fillMaxWidth()
        .height(44.dp)

    val withShadow = if (isFocused) {
        baseModifier.shadow(
            elevation = 12.dp,
            shape = shape,
            ambientColor = colors.primary.copy(alpha = 0.25f),
            spotColor = colors.primary.copy(alpha = 0.25f),
        )
    } else {
        baseModifier
    }

    Row(
        modifier = withShadow
            .background(animatedBg, shape)
            .border(
                width = if (isFocused) 1.5.dp else 1.dp,
                color = animatedBorder,
                shape = shape,
            )
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(
            Icons.Default.Search,
            contentDescription = null,
            modifier = Modifier.size(18.dp),
            tint = iconTint,
        )
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            textStyle = OriveoTheme.typography.body.copy(color = colors.textPrimary),
            singleLine = true,
            cursorBrush = SolidColor(colors.primary),
            interactionSource = interactionSource,
            modifier = Modifier.weight(1f),
            decorationBox = { inner ->
                Box {
                    if (value.isEmpty()) {
                        Text(
                            stringResource(R.string.skills_searchSkills),
                            style = OriveoTheme.typography.body,
                            color = colors.textTertiary,
                        )
                    }
                    inner()
                }
            },
        )
        if (value.isNotEmpty()) {
            Box(
                modifier = Modifier
                    .size(22.dp)
                    .clip(CircleShape)
                    .clickable { onValueChange("") },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Default.Cancel,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                    tint = colors.textTertiary.copy(alpha = 0.8f),
                )
            }
        }
    }
}

// -- Section Label (accent bar + optional trailing chip) --

@Composable
private fun SectionLabel(text: String, trailing: String? = null) {
    val colors = OriveoTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Box(
            modifier = Modifier
                .size(width = 3.dp, height = 14.dp)
                .clip(RoundedCornerShape(1.5.dp))
                .background(colors.primary, RoundedCornerShape(1.5.dp)),
        )
        Text(
            text = text,
            fontSize = 16.sp,
            fontWeight = FontWeight.SemiBold,
            color = colors.textPrimary,
        )
        if (trailing != null) {
            Text(
                text = trailing,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                color = colors.textTertiary,
                modifier = Modifier
                    .clip(RoundedCornerShape(percent = 50))
                    .background(colors.surfaceInset, RoundedCornerShape(percent = 50))
                    .padding(horizontal = 8.dp, vertical = 2.dp),
            )
        }
    }
}

// ── Nav Tone Button ──

@Composable
private fun NavToneButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    contentDescription: String?,
    tint: Color,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(12.dp)
    Box(
        modifier = Modifier
            .size(36.dp)
            .clip(shape)
            .background(colors.surfaceInset, shape)
            .border(1.dp, colors.hairline, shape)
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon,
            contentDescription = contentDescription,
            tint = tint,
            modifier = Modifier.size(18.dp),
        )
    }
}


// ── Filter Pill ──

@Composable
private fun FilterPill(
    label: String,
    icon: String?,
    count: Int,
    isActive: Boolean,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(percent = 50)

    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (isPressed) 0.97f else 1f,
        animationSpec = tween(
            durationMillis = if (isPressed) 120 else 180,
            easing = FastOutSlowInEasing,
        ),
        label = "pill_press",
    )

    val activeBrush = Brush.linearGradient(
        colors = listOf(colors.primary, colors.primary.copy(alpha = 0.85f)),
    )

    Row(
        modifier = Modifier
            .scale(scale)
            .clip(shape)
            .then(
                if (isActive) {
                    Modifier.background(activeBrush, shape)
                } else {
                    Modifier.background(colors.surface, shape)
                }
            )
            .border(
                width = 1.dp,
                color = if (isActive) Color.Transparent else colors.border,
                shape = shape,
            )
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                role = Role.Button,
                onClick = onClick,
            )
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (icon != null) {
            Text(icon, fontSize = 13.sp)
        }
        Text(
            text = label,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            color = if (isActive) Color.White else colors.textSecondary,
        )
        Text(
            text = "$count",
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            color = if (isActive) {
                Color.White.copy(alpha = 0.75f)
            } else {
                colors.textSecondary.copy(alpha = 0.55f)
            },
        )
    }
}

// ── Skill Card ──

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SkillCardView(
    skill: Skill,
    isDark: Boolean,
    onUse: () -> Unit,
    onEdit: (() -> Unit)?,
    onDelete: (() -> Unit)?,
    onTogglePin: () -> Unit,
    onFork: (() -> Unit)?,
) {
    val colors = OriveoTheme.colors
    val haptic = LocalHapticFeedback.current

    val skillColor = remember(skill.color) { parseColor(skill.color) }
    val descriptionMinHeight = with(LocalDensity.current) { 32.sp.toDp() }
    var showMenu by remember { mutableStateOf(false) }

    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (isPressed) 0.97f else 1f,
        animationSpec = tween(
            durationMillis = if (isPressed) 120 else 180,
            easing = FastOutSlowInEasing,
        ),
        label = "card_press",
    )

    val cardShape = RoundedCornerShape(18.dp)
    val iconShape = RoundedCornerShape(14.dp)
    val ctaShape = RoundedCornerShape(10.dp)

    val washTopAlpha = if (isDark) 0.10f else 0.06f
    val washBottomAlpha = if (isDark) 0.02f else 0.012f
    // When the tinted padding alpha between the emoji and the icon block edge is too low, the
    // emoji looks like it's floating on a white veil; deepen fill + stroke so it sits on a
    // more visible colored background.
    val iconBgAlpha = if (isDark) 0.28f else 0.16f
    val iconStrokeAlpha = if (isDark) 0.42f else 0.30f
    val ctaAlpha = if (isDark) 0.18f else 0.10f

    val washBrush = Brush.verticalGradient(
        colors = listOf(
            skillColor.copy(alpha = washTopAlpha),
            skillColor.copy(alpha = washBottomAlpha),
        ),
    )

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .scale(scale)
            .shadow(
                elevation = if (isDark) 10.dp else 6.dp,
                shape = cardShape,
                ambientColor = Color.Black.copy(alpha = if (isDark) 0.22f else 0.05f),
                spotColor = Color.Black.copy(alpha = if (isDark) 0.22f else 0.05f),
            )
            .clip(cardShape)
            .background(colors.surface, cardShape)
            .background(washBrush, cardShape)
            .border(1.dp, colors.border, cardShape)
            .combinedClickable(
                interactionSource = interactionSource,
                indication = null,
                onClick = onUse,
                onLongClick = {
                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                    showMenu = true
                },
            )
            .padding(14.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // top: icon block + pin indicator
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.Top,
            ) {
                Box(
                    modifier = Modifier
                        .size(52.dp)
                        .clip(iconShape)
                        .background(skillColor.copy(alpha = iconBgAlpha), iconShape)
                        .border(1.dp, skillColor.copy(alpha = iconStrokeAlpha), iconShape),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(skill.icon, fontSize = 28.sp)
                }
                Spacer(Modifier.weight(1f))
                if (skill.isPinned) {
                    Box(
                        modifier = Modifier
                            .size(24.dp)
                            .clip(CircleShape)
                            .background(colors.primarySoft, CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            Icons.Default.PushPin,
                            contentDescription = null,
                            tint = colors.primary,
                            modifier = Modifier.size(12.dp),
                        )
                    }
                }
            }

            // title + description
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    text = skill.localizedName(),
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                val desc = skill.localizedDescription()
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = descriptionMinHeight),
                ) {
                    if (desc.isNotBlank()) {
                        Text(
                            text = desc,
                            fontSize = 12.sp,
                            color = colors.textSecondary,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            lineHeight = 16.sp,
                        )
                    }
                }
            }

            Spacer(Modifier.weight(1f))

            // CTA: "Use this skill ->"
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(ctaShape)
                    .background(skillColor.copy(alpha = ctaAlpha), ctaShape)
                    .padding(vertical = 11.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.Center,
            ) {
                Text(
                    text = stringResource(R.string.skills_useSkill),
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.textPrimary,
                )
                Spacer(Modifier.width(5.dp))
                Icon(
                    Icons.AutoMirrored.Filled.ArrowForward,
                    contentDescription = null,
                    tint = skillColor.copy(alpha = 0.9f),
                    modifier = Modifier.size(12.dp),
                )
            }
        }

        // Context menu
        DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.skills_useSkill)) },
                onClick = { showMenu = false; onUse() },
            )
            DropdownMenuItem(
                text = {
                    Text(
                        if (skill.isPinned) stringResource(R.string.skills_unpin)
                        else stringResource(R.string.skills_pinToHome)
                    )
                },
                onClick = { showMenu = false; onTogglePin() },
            )
            if (onEdit != null) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.skills_edit)) },
                    onClick = { showMenu = false; onEdit() },
                )
            }
            if (onFork != null) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.skills_forkAsMy)) },
                    onClick = { showMenu = false; onFork() },
                )
            }
            if (onDelete != null) {
                DropdownMenuItem(
                    text = {
                        Text(
                            stringResource(R.string.delete),
                            color = MaterialTheme.colorScheme.error,
                        )
                    },
                    onClick = { showMenu = false; onDelete() },
                )
            }
        }
    }
}

// -- Skill Chip (used in the home screen's pinned section) --
//
// Mirrors iOS's SkillChipButton (Aurora Ghost style):
// - 12dp rounded rectangle (not a capsule, matching ChatGPT/Claude/Material Assist Chip)
// - 44dp height, 18dp icon + 14sp/SemiBold text
// - skill.color at very low fill opacity (dark 12% / light 6%) + same-color border (dark 22% / light 14%)
// - pressed state: scale 0.97 + skill.color @ 0.10 highlight
// - mapped icons use Material Icons vectors; unmapped ones fall back to an emoji

@Composable
fun SkillChip(skill: Skill, onClick: () -> Unit) {
    val isDark = OriveoTheme.isDark
    val skillColor = remember(skill.color) {
        runCatching { Color(android.graphics.Color.parseColor(skill.color)) }.getOrNull()
            ?: Color(0xFF8B5CF6)
    }
    val chipFill = skillColor.copy(alpha = if (isDark) 0.12f else 0.06f)
    val chipBorder = skillColor.copy(alpha = if (isDark) 0.22f else 0.14f)

    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()
    val pressOverlay = if (isPressed) skillColor.copy(alpha = 0.10f) else Color.Transparent
    val scale by animateFloatAsState(
        targetValue = if (isPressed) 0.97f else 1f,
        animationSpec = tween(
            durationMillis = if (isPressed) 120 else 180,
            easing = FastOutSlowInEasing,
        ),
        label = "skill_chip_press_scale",
    )

    val shape = RoundedCornerShape(12.dp)

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .scale(scale)
            .height(44.dp)
            .shadow(
                elevation = if (isDark) 4.dp else 2.dp,
                shape = shape,
                ambientColor = Color.Black.copy(alpha = if (isDark) 0.20f else 0.03f),
                spotColor = Color.Black.copy(alpha = if (isDark) 0.20f else 0.03f),
            )
            .clip(shape)
            .background(chipFill, shape)
            .background(pressOverlay, shape)
            .border(0.6.dp, chipBorder, shape)
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                role = Role.Button,
                onClick = onClick,
            )
            .padding(start = 10.dp, end = 14.dp, top = 6.dp, bottom = 6.dp),
    ) {
        ai.oriveo.community.feature.home.SkillIcon(
            icon = skill.icon,
            tintColor = skillColor,
            size = 18.dp,
        )
        Text(
            text = skill.localizedName(),
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            color = if (isDark) Color(0xFFFAFAFB) else Color(0xFF0A0612),
        )
    }
}

// ── Empty State ──

@Composable
private fun EmptyUserSkills(onCreateFirst: () -> Unit) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val cardShape = RoundedCornerShape(20.dp)
    val pillShape = RoundedCornerShape(percent = 50)

    val washBrush = Brush.verticalGradient(
        colors = listOf(
            colors.primary.copy(alpha = if (isDark) 0.09f else 0.05f),
            Color.Transparent,
        ),
    )

    val ctaBrush = Brush.linearGradient(
        colors = listOf(colors.primary, colors.primary.copy(alpha = 0.88f)),
    )

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .shadow(
                elevation = if (isDark) 10.dp else 6.dp,
                shape = cardShape,
                ambientColor = Color.Black.copy(alpha = if (isDark) 0.22f else 0.05f),
                spotColor = Color.Black.copy(alpha = if (isDark) 0.22f else 0.05f),
            )
            .clip(cardShape)
            .background(colors.surface, cardShape)
            .background(washBrush, cardShape)
            .border(1.dp, colors.border, cardShape)
            .padding(vertical = 30.dp, horizontal = 20.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            // purple glow circle + sparkles
            Box(
                modifier = Modifier
                    .size(64.dp)
                    .clip(CircleShape)
                    .background(
                        colors.primary.copy(alpha = if (isDark) 0.18f else 0.10f),
                        CircleShape,
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Default.AutoAwesome,
                    contentDescription = null,
                    tint = colors.primary,
                    modifier = Modifier.size(28.dp),
                )
            }

            Text(
                text = stringResource(R.string.skills_noCustomSkills),
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                color = colors.textPrimary,
            )

            // gradient CTA
            Row(
                modifier = Modifier
                    .shadow(
                        elevation = 14.dp,
                        shape = pillShape,
                        ambientColor = colors.primary.copy(alpha = 0.35f),
                        spotColor = colors.primary.copy(alpha = 0.35f),
                    )
                    .clip(pillShape)
                    .background(ctaBrush, pillShape)
                    .clickable(onClick = onCreateFirst)
                    .padding(horizontal = 18.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Icon(
                    Icons.Default.Add,
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(14.dp),
                )
                Text(
                    text = stringResource(R.string.skills_createFirstSkill),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = Color.White,
                )
            }
        }
    }
}
