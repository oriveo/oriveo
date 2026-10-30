'use client';

/**
 * External web search sources card. The header reads the persisted search
 * facts (same facts as finishSearchReply.sourcesLine); rows are this message's external_search citations.
 * Collapsed by default; no chevron when nothing was found.
 */
import { memo, useId, useState } from 'react';
import { useTranslations } from 'next-intl';
import { ChevronDown, Globe } from 'lucide-react';
import type { ChatMessage, Citation } from '@oriveo/shared';
import { normalizeUrl } from '../../lib/core/providers/transport/citation-utils';
import { searchSourceRows, searchSourcesHeader } from '../../lib/search/search-chat-presentation';
import { CitationRow } from './CitationsBlock';
import citationStyles from './CitationsBlock.module.css';
import styles from './SearchSourcesCard.module.css';

type SearchRecord = NonNullable<ChatMessage['capabilityResults']>[number];

export const SearchSourcesCard = memo(function SearchSourcesCard({
  record,
  citations,
  defaultExpanded = false,
}: {
  record: SearchRecord;
  citations: readonly Citation[] | undefined;
  /** Dev shots only (sourcesExpanded). */
  defaultExpanded?: boolean;
}) {
  const t = useTranslations('webSearch');
  const header = searchSourcesHeader(record);
  const rows = searchSourceRows(citations);
  const expandable = header.expandable && rows.length > 0;
  const [expanded, setExpanded] = useState(defaultExpanded);
  const listId = useId();
  const lead = header.lead.key === 'chat.reusedSearch' ? t('chat.reusedSearch') : t('chat.searchedTimes', { count: header.lead.count });
  const count = header.count.key === 'chat.noSources' ? t('chat.noSources') : t('chat.sourcesCount', { count: header.count.count });
  const title = (
    <>
      <Globe size={14} aria-hidden="true" className={styles.globe} />
      <span className={styles.titleText}>
        <span>{lead}</span>
        <span aria-hidden="true"> · </span>
        <span>{header.serviceName}</span>
        {header.custom ? <span className={styles.badge}>{t('badge.custom')}</span> : null}
        <span aria-hidden="true"> · </span>
        <span>{count}</span>
      </span>
    </>
  );
  return (
    <section className={`${citationStyles.container} ${styles.card}`} data-testid="search-sources-card">
      {expandable ? (
        <button
          type="button"
          className={styles.header}
          aria-expanded={expanded}
          aria-controls={listId}
          onClick={() => setExpanded((value) => !value)}
        >
          {title}
          <ChevronDown size={14} aria-hidden="true" className={expanded ? styles.chevronOpen : styles.chevron} />
        </button>
      ) : (
        <div className={styles.header}>{title}</div>
      )}
      {expandable && expanded ? (
        <div id={listId} className={citationStyles.list}>
          {rows.map((citation, idx) => (
            <CitationRow
              key={`${citation.index ?? idx}:${normalizeUrl(citation.url)}`}
              citation={citation}
              positionIndex={idx + 1}
              hideSnippet
            />
          ))}
        </div>
      ) : null}
    </section>
  );
});
