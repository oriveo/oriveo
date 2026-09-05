'use client';

import type { CSSProperties, ReactNode } from 'react';
import { useTranslations } from 'next-intl';
import { CheckCircle2, ChevronsUpDown, Link2, LinkIcon, Loader2, TriangleAlert } from 'lucide-react';
import type { Provider, RelayKind } from '@oriveo/shared';
import { ProviderIcon } from '../../../../components/ProviderIcon';
import { RELAY_KIND_OPTIONS } from '../../../../components/providers/RelayKindPicker';
import styles from './RelayEditorHeroCard.module.css';

interface RelayEditorHeroCardProps {
  provider: Provider;
  /** Current endpoint text; the caller trims it, and an empty string means none. */
  endpointText: string | null;
  relayKind: RelayKind;
  /** The name area is injected by the caller, keeping EditableProviderName's inline rename behaviour. */
  nameSlot: ReactNode;
  /** Clicking the kind pill asks the caller to open the switch modal. */
  onChangeKind: () => void;
}

const KIND_TITLE_KEY: Record<RelayKind, string> = {
  openai_compatible: 'kind.openai.title',
  codex_style: 'kind.codex.title',
  anthropic_compatible: 'kind.anthropic.title',
  gemini_compatible: 'kind.gemini.title',
  custom: 'kind.custom.title',
};

export function RelayEditorHeroCard({
  provider,
  endpointText,
  relayKind,
  nameSlot,
  onChangeKind,
}: RelayEditorHeroCardProps) {
  const tSetup = useTranslations('pages.relaySetup');
  const tr = useTranslations('pages.relayDetail');
  const tc = useTranslations('common');

  const option = RELAY_KIND_OPTIONS.find((opt) => opt.kind === relayKind);
  const accent = option?.accent ?? '#64748b';
  const kindLabel = tSetup(KIND_TITLE_KEY[relayKind]);

  const statusKind = provider.status.kind;
  const statusLabel =
    statusKind === 'connected' ? tc('connected')
    : statusKind === 'syncing' ? tc('syncing')
    : tc('issue');

  const trimmedEndpoint = endpointText?.trim() ?? '';

  return (
    <section
      className={styles.card}
      style={{ ['--kind-accent' as never]: accent } as CSSProperties}
    >
      <div className={styles.header}>
        <span className={styles.badge} aria-hidden="true">
          <ProviderIcon
            kind="relay"
            relayKind={relayKind}
            baseURLText={provider.baseURLText}
            size={44}
            bare
          />
        </span>

        <div className={styles.identity}>
          <div className={styles.nameRow}>{nameSlot}</div>
          <span className={styles.kindLabel}>{kindLabel}</span>
        </div>
      </div>

      <div className={styles.metaRow}>
        <button
          type="button"
          className={styles.kindPill}
          onClick={onChangeKind}
          aria-label={`${tr('relayType')}: ${kindLabel}`}
        >
          <Link2 size={11} strokeWidth={2.6} className={styles.kindPillIcon} aria-hidden="true" />
          <span>{kindLabel}</span>
          <ChevronsUpDown size={10} strokeWidth={2.6} className={styles.kindPillChevron} aria-hidden="true" />
        </button>

        <span className={styles.statusPill} data-status={statusKind}>
          {statusKind === 'connected' && (
            <CheckCircle2 size={11} strokeWidth={2.6} className={styles.statusIcon} aria-hidden="true" />
          )}
          {statusKind === 'syncing' && (
            <Loader2
              size={11}
              strokeWidth={2.6}
              className={styles.statusIcon}
              data-spin="true"
              aria-hidden="true"
            />
          )}
          {statusKind === 'issue' && (
            <TriangleAlert size={11} strokeWidth={2.6} className={styles.statusIcon} aria-hidden="true" />
          )}
          <span>{statusLabel}</span>
        </span>
      </div>

      {trimmedEndpoint ? (
        <div className={styles.endpointPreview}>
          <span className={styles.endpointIconBox} aria-hidden="true">
            <LinkIcon size={12} strokeWidth={2.4} />
          </span>
          <span className={styles.endpointText} title={trimmedEndpoint}>
            {trimmedEndpoint}
          </span>
        </div>
      ) : (
        <div className={styles.endpointPlaceholder}>
          <span className={styles.endpointIconBox} aria-hidden="true">
            <LinkIcon size={12} strokeWidth={2.4} />
          </span>
          <span className={styles.endpointPlaceholderText}>{tr('noEndpointSet')}</span>
        </div>
      )}
    </section>
  );
}
