'use client';

import type { Skill } from '@oriveo/shared';
import { useSkillL10n } from '../../lib/hooks/useSkillL10n';
import { SkillIcon } from '../skills/SkillIcon';
import styles from './SkillStarterView.module.css';

interface SkillStarterViewProps {
  skill: Skill;
  onStarterClick: (msg: string) => void;
}

export function SkillStarterView({ skill, onStarterClick }: SkillStarterViewProps) {
  const { localizedName, localizedDescription, localizedStarterMessages } = useSkillL10n();
  const starters = localizedStarterMessages(skill);

  return (
    <div className={styles.wrap}>
      <div className={styles.header}>
        {/* Icon: a soft glow behind the circle, both tinted by the skill's own colour. */}
        <div className={styles.iconWrap} style={{ '--skill-color': skill.color } as React.CSSProperties}>
          <div className={styles.iconGlow} />
          <div className={styles.iconCircle}>
            <SkillIcon
              icon={skill.icon}
              color="var(--skill-color)"
              size={32}
              className={styles.icon}
            />
          </div>
        </div>
        <h2 className={styles.name}>{localizedName(skill)}</h2>
        {skill.description && (
          <p className={styles.desc}>{localizedDescription(skill)}</p>
        )}
      </div>

      {starters.length > 0 && (
        <div className={styles.starters}>
          {starters.map((msg, i) => (
            <button
              key={i}
              type="button"
              className={styles.starter}
              onClick={() => onStarterClick(msg)}
              style={{ animationDelay: `${120 + i * 60}ms` }}
            >
              <span className={styles.starterText}>{msg}</span>
              <svg className={styles.starterIcon} width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                <path d="M22 2L11 13" /><path d="M22 2L15 22L11 13L2 9L22 2Z" />
              </svg>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
