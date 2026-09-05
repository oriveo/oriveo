'use client';

import type { Skill } from '@oriveo/shared';
import { useTranslations } from 'next-intl';
import { useSkillL10n } from '../../lib/hooks/useSkillL10n';
import { SkillIcon } from '../skills/SkillIcon';
import styles from './SkillsPills.module.css';

/** Maximum number of skills shown in the home sidebar. */
const MAX_VISIBLE = 8;

interface SkillsPillsProps {
  skills: Skill[];
  onSkillClick: (skill: Skill) => void;
  onAddClick: () => void;
  /** Show a placeholder while loading. */
  loading?: boolean;
}

export function SkillsPills({ skills, onSkillClick, onAddClick, loading }: SkillsPillsProps) {
  const t = useTranslations('sidebar');
  const { localizedName } = useSkillL10n();

  if (loading) {
    return (
      <div className={styles.pills}>
        {[1, 2, 3].map((i) => (
          <div key={i} className={styles.pillSkeleton} />
        ))}
      </div>
    );
  }

  const visible = skills.slice(0, MAX_VISIBLE);

  return (
    <div className={styles.pills}>
      {visible.map((skill) => (
        <button
          key={skill.id}
          className={styles.pill}
          onClick={() => onSkillClick(skill)}
          title={localizedName(skill)}
          style={{
            '--skill-color': skill.color,
          } as React.CSSProperties}
        >
          <SkillIcon
            icon={skill.icon}
            color="var(--skill-color)"
            size={13}
            className={styles.pillIcon}
          />
          <span className={styles.pillName}>{localizedName(skill)}</span>
        </button>
      ))}
      <button
        className={styles.pillMore}
        onClick={onAddClick}
        title={t('more')}
      >
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
          <line x1="12" y1="5" x2="12" y2="19" />
          <line x1="5" y1="12" x2="19" y2="12" />
        </svg>
        <span className={styles.pillName}>{t('more')}</span>
      </button>
    </div>
  );
}
