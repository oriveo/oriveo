'use client';

/**
 * External web search activity: "Searching with {name}…" while the stream activity
 * is external_search, then "Answering from search results…" until the first token; query chips below (newest
 * three, the one in flight spins). What to show comes from searchActivityPresentation.
 */
import { useSyncExternalStore } from 'react';
import { useTranslations } from 'next-intl';
import { Loader2, Search } from 'lucide-react';
import {
  externalSearchActivityView,
  subscribeExternalSearchActivity,
  type ExternalSearchActivityView,
} from '../../lib/core/chat/external-search-activity';
import type { SearchActivityPresentation } from '../../lib/search/search-chat-presentation';
import lineStyles from './StreamActivityLine.module.css';
import styles from './ExternalSearchActivity.module.css';

/** This conversation's activity context (not persisted). */
export function useExternalSearchActivityView(conversationId: string | null | undefined): ExternalSearchActivityView | null {
  return useSyncExternalStore(
    subscribeExternalSearchActivity,
    () => externalSearchActivityView(conversationId),
    () => null,
  );
}

export function ExternalSearchActivity({ presentation }: { presentation: NonNullable<SearchActivityPresentation> }) {
  const t = useTranslations('webSearch');
  const text = presentation.kind === 'searching'
    ? t('chat.searching', { name: presentation.serviceName })
    : t('chat.answeringFromResults');
  return (
    <div className={styles.wrap} data-testid="external-search-activity">
      <div className={lineStyles.line} role="status">
        <span className={lineStyles.shimmer}>{text}</span>
      </div>
      <ul className={styles.chips}>
        {presentation.chips.map((chip, index) => (
          <li key={`${index}:${chip.label}`} className={styles.chip} data-searching={chip.searching ? 'true' : undefined}>
            {chip.searching
              ? <Loader2 size={12} aria-hidden="true" className={styles.spinner} />
              : <Search size={12} aria-hidden="true" />}
            <span className={styles.chipText}>{chip.label}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
