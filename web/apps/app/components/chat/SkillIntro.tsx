'use client';

import { useTranslations } from 'next-intl';
import type { Skill } from '@oriveo/shared';
import { useSkillL10n } from '../../lib/hooks/useSkillL10n';
import { SkillIcon } from '../skills/SkillIcon';
import styles from './SkillIntro.module.css';

interface SkillIntroProps {
  skill: Skill;
}

/**
 * Empty state for a skill conversation: the skill icon, the shared greeting used by SkillsLanding,
 * and the skill's one-line description. It renders no starter prompt cards, since the skill marker at the top and the description already provide the cue.
 */
export function SkillIntro({ skill }: SkillIntroProps) {
  const t = useTranslations('skills');
  const { localizedDescription } = useSkillL10n();
  const description = localizedDescription(skill);

  return (
    <div
      className={styles.intro}
      data-testid="skill-intro"
      style={{ '--skill-color': skill.color } as React.CSSProperties}
    >
      <div className={styles.iconWrap}>
        <SkillIcon
          icon={skill.icon}
          color="var(--skill-color)"
          size={60}
          className={styles.icon}
        />
      </div>

      <h2 className={styles.greeting}>{t('greeting')}</h2>

      {description && <p className={styles.description}>{description}</p>}
    </div>
  );
}
