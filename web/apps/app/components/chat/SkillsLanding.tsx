'use client';

import { useTranslations } from 'next-intl';
import type { Skill } from '@oriveo/shared';
import { OriveoLogo } from '@oriveo/ui';
import styles from './SkillsLanding.module.css';

interface SkillsLandingProps {
  /** Historical props, kept for ChatView call sites; the minimal empty state does not render skill cards. */
  onSkillSelect?: (skill: Skill) => void;
  onSkillStarterPrompt?: (skill: Skill, message: string) => void;
  layout?: 'default' | 'compact';
}

/**
 * Empty state for a new conversation: a centered brand logo with a breathing glow, a warm
 * greeting and an encouraging subtitle. The skill card grid is not rendered here; the skills entry
 * points are the sidebar and the Skills page.
 */
export function SkillsLanding(_props: SkillsLandingProps) {
  const t = useTranslations('skills');

  return (
    <div className={styles.landing}>
      <header className={styles.hero}>
        <OriveoLogo size={72} withGlow className={styles.heroLogo} />
        <h2 className={styles.greeting}>{t('greeting')}</h2>
        <p className={styles.sub}>{t('greetingSub')}</p>
      </header>
    </div>
  );
}
