'use client';

import { useEffect, useSyncExternalStore } from 'react';
import { useTranslations } from 'next-intl';
import { getVanillaStore } from '../../providers/StoreProvider';
import {
  acceptDirectiveSuggestion,
  clearDirectiveSuggestion,
  getPendingDirectiveSuggestion,
  ignoreDirectiveSuggestion,
  subscribeDirectiveSuggestion,
  type DirectiveSuggestion,
} from '../../lib/core/chat/conversation-instructions/directive-suggestion';
import { showToast } from '../Toast';
import styles from './DirectiveSuggestionBar.module.css';

const serverSuggestion = (): DirectiveSuggestion | null => null;

/**
 * P4·U3: the pending "set as instruction" suggestion for this conversation, or null.
 * Switching away from the suggested conversation drops it without counting an ignore.
 */
export function useDirectiveSuggestion(conversationId: string | null | undefined): DirectiveSuggestion | null {
  const suggestion = useSyncExternalStore(subscribeDirectiveSuggestion, getPendingDirectiveSuggestion, serverSuggestion);
  useEffect(() => {
    const current = getPendingDirectiveSuggestion();
    if (current && current.conversationId !== conversationId) clearDirectiveSuggestion();
  }, [conversationId]);
  if (!suggestion || !conversationId || suggestion.conversationId !== conversationId) return null;
  return suggestion;
}

/** P4·U3 suggestion bar rendered under the user message that looked like a durable directive. */
export function DirectiveSuggestionBar() {
  const t = useTranslations('pages.chat.directiveSuggestion');
  const tCommon = useTranslations('common');

  const handleAccept = () => {
    const undo = acceptDirectiveSuggestion(getVanillaStore());
    if (!undo) return;
    showToast(t('added'), 5000, undo, 'warning', tCommon('undo'));
  };

  return (
    <div className={styles.bar} role="status" data-testid="directive-suggestion-bar">
      <span className={styles.text}>{t('prompt')}</span>
      <div className={styles.actions}>
        <button type="button" className={styles.secondary} onClick={ignoreDirectiveSuggestion}>
          {t('ignore')}
        </button>
        <button type="button" className={styles.primary} onClick={handleAccept}>
          {t('accept')}
        </button>
      </div>
    </div>
  );
}
