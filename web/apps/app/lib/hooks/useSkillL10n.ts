import { useTranslations } from 'next-intl';
import { useCallback } from 'react';
import type { Skill, SkillCategory } from '@oriveo/shared';

export function useSkillL10n() {
  const t = useTranslations('builtinSkills');
  // next-intl logs and returns the key path for a missing message instead of throwing,
  // so check presence explicitly and fall back to the server-provided text.
  const tr = useCallback(
    (key: string, fallback: string): string => (t.has(key as any) ? t(key as any) : fallback),
    [t],
  );

  const localizedName = useCallback(
    (skill: Skill): string => {
      if (skill.source !== 'builtin' || !skill.key) return skill.name;
      return tr(`${skill.key}.name`, skill.name);
    },
    [tr],
  );

  const localizedDescription = useCallback(
    (skill: Skill): string => {
      if (skill.source !== 'builtin' || !skill.key) return skill.description;
      return tr(`${skill.key}.description`, skill.description);
    },
    [tr],
  );

  const localizedStarterMessages = useCallback(
    (skill: Skill): string[] => {
      if (skill.source !== 'builtin' || !skill.key || skill.starterMessages.length === 0) {
        return skill.starterMessages;
      }
      return skill.starterMessages.map((fallback, i) => {
        return tr(`${skill.key}.starters.${i}`, fallback);
      });
    },
    [tr],
  );

  const localizedCategoryName = useCallback(
    (category: SkillCategory): string => {
      return tr(`category.${category.id}`, category.name);
    },
    [tr],
  );

  return { localizedName, localizedDescription, localizedStarterMessages, localizedCategoryName };
}
