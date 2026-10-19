'use client';

import { useEffect, useRef, useSyncExternalStore } from 'react';
import { useTranslations } from 'next-intl';
import { FoldVertical } from 'lucide-react';
import type { QuoteContext } from '@oriveo/shared';
import {
  dismissCompactionHint,
  pendingCompactionHint,
  subscribeCompactionHint,
  takePendingComposerQuote,
} from '../../lib/core/chat/context-compaction/context-compaction-actions';
import styles from './CompactionHintBanner.module.css';

interface CompactionHintBannerProps {
  conversationId: string | null | undefined;
  onNewChat: () => void;
}

const serverHint = (): string | null => null;

/** P3·U4: third-compaction hint shown above the composer while this conversation is the pending one. */
export function CompactionHintBanner({ conversationId, onNewChat }: CompactionHintBannerProps) {
  const t = useTranslations('pages.chat.contextCompaction');
  const hinted = useSyncExternalStore(subscribeCompactionHint, pendingCompactionHint, serverHint);
  if (!conversationId || hinted !== conversationId) return null;

  return (
    <div className={styles.banner} role="status">
      <FoldVertical className={styles.icon} size={14} aria-hidden="true" />
      <span className={styles.text}>{t('thirdHint')}</span>
      <div className={styles.actions}>
        <button
          type="button"
          className={styles.secondary}
          onClick={dismissCompactionHint}
        >
          {t('thirdHintDismiss')}
        </button>
        <button
          type="button"
          className={styles.primary}
          onClick={() => {
            dismissCompactionHint();
            onNewChat();
          }}
        >
          {t('thirdHintNewChat')}
        </button>
      </div>
    </div>
  );
}

/**
 * P3·U4: when a conversation view mounts (or switches) to `conversationId`, take the pending
 * composer quote once and hand it to `onQuote`. A new chat has no id yet, so it takes the null slot.
 */
export function usePendingComposerQuote(
  conversationId: string | null | undefined,
  onQuote: (quote: QuoteContext) => void,
): void {
  const onQuoteRef = useRef(onQuote);
  onQuoteRef.current = onQuote;
  const key = conversationId ?? null;
  useEffect(() => {
    const quote = takePendingComposerQuote(key);
    if (quote) onQuoteRef.current(quote);
  }, [key]);
}
