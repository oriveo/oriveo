package ai.oriveo.community.feature.home.homescreen

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.feature.home.AuroraSectionRule
import ai.oriveo.community.feature.home.AuroraTheme
import ai.oriveo.community.feature.skills.SkillChip
import ai.oriveo.community.ui.theme.OriveoTheme


@Composable
internal fun SkillsRow(
    skills: List<Skill>,
    onSkillClick: (Skill) -> Unit,
    onAddClick: () -> Unit,
) {
    val displaySkills = remember(skills) { skills.take(7) }
    val accent = AuroraTheme.accent()

    Column(
        modifier = Modifier.padding(vertical = OriveoTheme.spacing.sm),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = OriveoTheme.layout.screenH),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            AuroraSectionRule()
            Text(
                text = stringResource(R.string.skills_title),
                style = AuroraTheme.Typography.section,
                color = AuroraTheme.textPrimary(),
            )
            Spacer(modifier = Modifier.weight(1f))
            Row(
                modifier = Modifier.clickable(role = androidx.compose.ui.semantics.Role.Button, onClick = onAddClick),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    text = stringResource(R.string.skills_more),
                    fontSize = 13.sp,
                    fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                    color = accent,
                )
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.ArrowForward,
                    contentDescription = null,
                    modifier = Modifier.size(12.dp),
                    tint = accent,
                )
            }
        }

        
        LazyRow(
            contentPadding = PaddingValues(horizontal = OriveoTheme.layout.screenH),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier.padding(vertical = 4.dp),
        ) {
            items(displaySkills.size, key = { displaySkills[it].id }) { index ->
                val skill = displaySkills[index]
                SkillChip(skill = skill, onClick = { onSkillClick(skill) })
            }
        }
    }
}
