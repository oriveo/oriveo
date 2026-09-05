import { useTranslations } from 'next-intl';
import { useCallback } from 'react';
import type { Skill, SkillCategory } from '@oriveo/shared';

export function useSkillL10n() {
  const t = useTranslations('builtinSkills');

  const localizedName = useCallback(
    (skill: Skill): string => {
      if (skill.source !== 'builtin' || !skill.key) return skill.name;
      try { return t(`${skill.key}.name` as any); } catch { return skill.name; }
    },
    [t],
  );

  const localizedDescription = useCallback(
    (skill: Skill): string => {
      if (skill.source !== 'builtin' || !skill.key) return skill.description;
      try { return t(`${skill.key}.description` as any); } catch { return skill.description; }
    },
    [t],
  );

  const localizedStarterMessages = useCallback(
    (skill: Skill): string[] => {
      if (skill.source !== 'builtin' || !skill.key || skill.starterMessages.length === 0) {
        return skill.starterMessages;
      }
      return skill.starterMessages.map((fallback, i) => {
        try { return t(`${skill.key}.starters.${i}` as any); } catch { return fallback; }
      });
    },
    [t],
  );

  const localizedCategoryName = useCallback(
    (category: SkillCategory): string => {
      try { return t(`category.${category.id}` as any); } catch { return category.name; }
    },
    [t],
  );

  return { localizedName, localizedDescription, localizedStarterMessages, localizedCategoryName };
}
