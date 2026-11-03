'use client';

import { useMemo } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { CalendarDays, Plus } from 'lucide-react';
import { useAppStore } from '../../providers/StoreProvider';
import { ConversationList } from '../sidebar/ConversationList';
import styles from './MobileHomeView.module.css';

export function MobileHomeView() {
  const router = useRouter();
  const t = useTranslations('mobileHome');

  const account = useAppStore((s) => s.account);
  const conversations = useAppStore((s) => s.conversations);
  const setActiveConversationId = useAppStore((s) => s.setActiveConversationId);

  const visibleConversationCount = useMemo(
    () => conversations.filter((conversation) => !conversation.isDraft && !conversation.isConflictCopy).length,
    [conversations],
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

  return (
    <main className={styles.page} aria-label={t('title')}>
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
