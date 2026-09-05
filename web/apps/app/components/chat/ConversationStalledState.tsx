'use client';

import { useTranslations } from 'next-intl';
import { CloudOff } from 'lucide-react';
import { Button } from '@oriveo/ui';
import styles from './ConversationStalledState.module.css';

interface ConversationStalledStateProps {
  onRetry: () => void;
}

/**
 * Error state for a conversation whose message bodies cannot be loaded from local storage.
 * Offers retry rather than an empty composer, so the user does not type into a thread that
 * still has unread history.
 */
export function ConversationStalledState({
  onRetry,
}: ConversationStalledStateProps) {
  const t = useTranslations('pages.chat');

  return (
    <div className={styles.state} data-testid="conversation-stalled-state" role="status">
      <CloudOff className={styles.icon} size={28} aria-hidden="true" />
      <h3 className={styles.title}>{t('historyUnavailableTitle')}</h3>
      <p className={styles.description}>{t('historyUnavailableMessage')}</p>
      <div className={styles.actions}>
        <Button size="sm" onClick={onRetry} data-testid="conversation-stalled-retry">
          {t('historyUnavailableRetry')}
        </Button>
      </div>
    </div>
  );
}
