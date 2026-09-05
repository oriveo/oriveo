'use client';

import { useMemo, useState, type CSSProperties } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { CalendarDays, Plus } from 'lucide-react';
import type { Skill } from '@oriveo/shared';
import { useAppStore, getVanillaStore } from '../../providers/StoreProvider';
import { getHomeSkills } from '../../lib/core/skills/query';
import { startConversationWithSkill } from '../../lib/core/skills/start-conversation';
import { markNewConversationRoutePromotion } from '../../lib/core/chat/route-transition';
import { useSkillL10n } from '../../lib/hooks/useSkillL10n';
import { showToast } from '../Toast';
import { SkillActionPromptDialog } from '../skills/SkillActionPromptDialog';
import { SkillIcon } from '../skills/SkillIcon';
import { ConversationList } from '../sidebar/ConversationList';
import styles from './MobileHomeView.module.css';

export function MobileHomeView() {
  const router = useRouter();
  const t = useTranslations('mobileHome');
  const tSkills = useTranslations('skills');
  const { localizedName } = useSkillL10n();

  const account = useAppStore((s) => s.account);
  const conversations = useAppStore((s) => s.conversations);
  const catalogSkills = useAppStore((s) => s.catalogSkills);
  const userSkills = useAppStore((s) => s.userSkills);
  const setActiveConversationId = useAppStore((s) => s.setActiveConversationId);

  const [showSkillProviderPrompt, setShowSkillProviderPrompt] = useState(false);

  const visibleConversationCount = useMemo(
    () => conversations.filter((conversation) => !conversation.isDraft && !conversation.isConflictCopy).length,
    [conversations],
  );

  const homeSkills = useMemo(
    () => getHomeSkills(getVanillaStore()).slice(0, 7),
    [catalogSkills, userSkills],
  );

  const greeting = useMemo(() => {
    const fallbackName = account?.name?.trim().split(/\s+/)[0];
    return fallbackName ? t('greetingName', { name: fallbackName }) : t('greeting');
  }, [account?.name, t]);

  const dateLabel = useMemo(
    () => new Intl.DateTimeFormat(undefined, { weekday: 'long', month: 'long', day: 'numeric' }).format(new Date()),
    [],
  );

  const handleNewChat = () => {
    setActiveConversationId(null);
    router.push('/chat?compose=1');
  };

  const handleSkillClick = (skill: Skill) => {
    const result = startConversationWithSkill(getVanillaStore(), skill, {
      title: localizedName(skill),
    });

    if (result.kind === 'no-provider') {
      showToast(tSkills('needProvider'));
      setShowSkillProviderPrompt(true);
      return;
    }

    markNewConversationRoutePromotion(result.conversationId);
    router.push(`/chat/${result.conversationId}`);
  };

  return (
    <main className={styles.page} aria-label={t('title')}>
      <SkillActionPromptDialog
        open={showSkillProviderPrompt}
        kind="provider"
        title={tSkills('providerRequiredTitle')}
        message={tSkills('providerRequiredMessage')}
        actionLabel={tSkills('providerRequiredAction')}
        cancelLabel={tSkills('promptCancel')}
        onClose={() => setShowSkillProviderPrompt(false)}
        onAction={() => {
          setShowSkillProviderPrompt(false);
          router.push('/providers/new');
        }}
      />

      <section className={styles.header}>
        <div className={styles.dateRow}>
          <CalendarDays size={14} aria-hidden="true" />
          <span>{dateLabel}</span>
        </div>

        <div className={styles.titleRow}>
          <div>
            <h1 className={styles.title}>{greeting}</h1>
            <p className={styles.subtitle}>{t('subtitle')}</p>
          </div>
          <button
            type="button"
            className={styles.primaryIconButton}
            onClick={handleNewChat}
            aria-label={t('newChat')}
            title={t('newChat')}
          >
            <Plus size={22} aria-hidden="true" />
          </button>
        </div>
      </section>

      <section className={styles.quickComposer} aria-label={t('quickStart')}>
        <button type="button" className={styles.quickInput} onClick={handleNewChat}>
          <span>{t('composerPlaceholder')}</span>
          <span className={styles.sendGlyph}>
            <Plus size={18} aria-hidden="true" />
          </span>
        </button>
      </section>

      {homeSkills.length > 0 && (
        <section className={styles.skills} aria-label={tSkills('title')}>
          <div className={styles.sectionHeader}>
            <span>{tSkills('title')}</span>
            <button type="button" onClick={() => router.push('/skills')}>{tSkills('allSkills')}</button>
          </div>
          <div className={styles.skillScroller}>
            {homeSkills.map((skill) => (
              <button
                key={skill.id}
                type="button"
                className={styles.skillChip}
                style={{ '--skill-color': skill.color } as CSSProperties}
                onClick={() => handleSkillClick(skill)}
              >
                <SkillIcon
                  icon={skill.icon}
                  color="var(--skill-color)"
                  size={15}
                  strokeWidth={1.9}
                />
                <span>{localizedName(skill)}</span>
              </button>
            ))}
          </div>
        </section>
      )}

      <section className={styles.history}>
        <div className={styles.sectionHeader}>
          <span>{t('history')}</span>
          <span className={styles.historyCount}>{visibleConversationCount}</span>
        </div>
        <div className={styles.historySurface}>
          <ConversationList variant="mobileHome" />
        </div>
      </section>
    </main>
  );
}
