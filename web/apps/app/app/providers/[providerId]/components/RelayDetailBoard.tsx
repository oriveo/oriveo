'use client';

import { useId, type ComponentType, type ReactNode } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import {
  BrainIcon,
  CaretRightIcon,
  CheckIcon,
  DatabaseIcon,
  GlobeIcon,
  HardDrivesIcon,
  KeyIcon,
  LinkIcon,
  LockIcon,
  PlugIcon,
  PlusIcon,
  ScanIcon,
  SlidersHorizontalIcon,
  ThermometerSimpleIcon,
  XIcon,
  type IconProps,
} from '@phosphor-icons/react';
import { formatCompactRelativeTime } from '../../../../lib/utils/format-utils';
import { ProtocolDot } from '../../relay/new/setup-board-parts';
import { RelayAvatarPickerButton } from '../../../../components/RelayAvatarPicker';
import {
  RELAY_DETAIL_TEXT,
  relayDetailRowIconColorToken,
  type DetailRow,
  type DetailRowAction,
  type DetailRowID,
  type DetailText,
  type RelayDetailBoard as RelayDetailBoardState,
} from '../relay-detail-board';
import { RelayKeyRowView } from './RelayKeysPage';
import styles from './RelayDetailBoard.module.css';

const TITLE_ONLY_ROWS: ReadonlySet<DetailRowID> = new Set(['modelLibrary', 'thinking', 'webSearch', 'parameters']);

/** Whether this row renders inline keys; title-only mode uses the same check. */
function hasInlineKeys(row: DetailRow): boolean {
  return (row.keys?.length ?? 0) > 0;
}

const ROW_ICONS: Partial<Record<DetailRowID, ComponentType<IconProps>>> = {
  endpoint: LinkIcon,
  apiKey: KeyIcon,
  defaultProtocol: HardDrivesIcon,
  engineAddress: LinkIcon,
  engine: PlugIcon,
  channel: HardDrivesIcon,
  modelLibrary: DatabaseIcon,
  webSearch: GlobeIcon,
  thinking: BrainIcon,
  parameters: ThermometerSimpleIcon,
};

interface RelayDetailBoardProps {
  board: RelayDetailBoardState;
  nameSlot: ReactNode;
  /** Accessibility name of the single-key row (with a key = change key, without = add key); title rows with ≥2 keys use their own text. */
  apiKeyRowLabel: string;
  /** Exits under the key row: the two options of a failed verification / "Remove stored key" when no auth is needed but a key is stored. */
  apiKeyRowExtras?: ReactNode;
  onAction: (action: Exclude<DetailRowAction, null>) => void;
  onDetectAgain: () => void;
  isDetecting: boolean;
  onDelete: () => void;
  disabled: boolean;
  /** Footer content such as the privacy note. */
  footer?: ReactNode;
}

/** Detail page board: header / connection card / model card / two bottom buttons / footnote (RelayDetail.png, LocalDetail.png). */
export function RelayDetailBoard({
  board,
  nameSlot,
  apiKeyRowLabel,
  apiKeyRowExtras,
  onAction,
  onDetectAgain,
  isDetecting,
  onDelete,
  disabled,
  footer,
}: RelayDetailBoardProps) {
  const tRoot = useTranslations();
  const tr = useTranslations('pages.relayDetail');
  const locale = useLocale();
  const apiKeyHintID = useId();
  const text = (value: DetailText | undefined) => {
    if (!value) return '';
    return 'literal' in value ? value.literal : tRoot(value.key, value.values);
  };
  const checked = board.checkedAt
    ? formatCompactRelativeTime(board.checkedAt, new Date(), locale, {
      justNow: tr('relativeJustNow'),
      minutesAgo: (count) => tr('relativeMinutesAgo', { count }),
      hoursAgo: (count) => tr('relativeHoursAgo', { count }),
      yesterday: tr('relativeYesterday'),
    })
    : '';

  const renderRow = (row: DetailRow) => {
    if (row.id === 'basePaths') {
      return (
        <div key={row.id} className={styles.basePathsRow} data-board-row={row.id}>
          <span className={styles.basePathsTitle}>{tRoot(row.titleKey)}</span>
          {row.basePaths?.map((item) => (
            <span key={item.protocol} className={styles.basePath}>
              <ProtocolDot protocol={item.protocol} />
              <span>{item.protocol}</span>
              <span className={styles.basePathValue}>{item.path}</span>
            </span>
          ))}
        </div>
      );
    }
    const Icon = ROW_ICONS[row.id];
    const iconColorToken = relayDetailRowIconColorToken(row.id);
    const { action } = row;
    // Title-only mode: model library / thinking / web search, plus the API key row that renders inline keys (same check as inline), body.semibold title + footnote value.
    const titleOnly = TITLE_ONLY_ROWS.has(row.id) || hasInlineKeys(row);
    // Web search configured: check + success color.
    const webSearchSet = row.id === 'webSearch' && row.trailingKey === 'pages.relayDetail.webSearch.statusSet';
    const content = (
      <>
        {Icon && (
          <span
            className={styles.rowIcon}
            data-row={row.id}
            style={iconColorToken ? { color: `var(${iconColorToken})` } : undefined}
            aria-hidden="true"
          >
            <Icon size={22} weight="duotone" />
          </span>
        )}
        <span className={styles.rowStack} data-row-lead data-title-only={titleOnly ? 'true' : undefined}>
          <span className={styles.rowTitle}>{tRoot(row.titleKey)}</span>
          {row.value && (
            <span className={styles.rowValue} data-mono={row.id === 'apiKey' && 'literal' in row.value ? 'true' : undefined}>
              {text(row.value)}
            </span>
          )}
          {renderInlineKeys(row)}
        </span>
        {row.trailingKey && (
          <span
            className={styles.rowTrailing}
            data-row-trailing
            data-tone={webSearchSet ? 'success' : 'muted'}
            {...(row.id === 'apiKey' ? { id: apiKeyHintID, 'data-row-hint': 'addMoreKeys' } : {})}
          >
            {row.id === 'apiKey'
              // A hint for when only one key is stored, not a button: the whole row is still a single tap target.
              ? <PlusIcon size={14} aria-hidden="true" />
              // The web search row's trailing text is a configuration status word, not a read-only lock.
              : row.id === 'webSearch'
                ? (webSearchSet ? <CheckIcon size={14} weight="bold" aria-hidden="true" /> : null)
                : <LockIcon size={14} aria-hidden="true" />}
            <span>{tRoot(row.trailingKey)}</span>
          </span>
        )}
        {action && <CaretRightIcon size={16} className={styles.rowChevron} aria-hidden="true" />}
      </>
    );
    if (!action) {
      return <div key={row.id} className={styles.row} data-board-row={row.id}>{content}</div>;
    }
    return (
      <button
        key={row.id}
        type="button"
        className={styles.row}
        data-board-row={row.id}
        onClick={() => onAction(action)}
        // Entering sub-pages (model library / keys page) and editing the connection are navigation and are not disabled by the write lock; the write entry is locked inside the sub-page.
        {...(row.id === 'apiKey' && !row.keys ? { 'aria-label': apiKeyRowLabel } : {})}
        // The row has its own accessible name (change key / add key); the hint is folded into this row's reading rather than being a separate target.
        {...(row.id === 'apiKey' && row.trailingKey ? { 'aria-describedby': apiKeyHintID } : {})}
      >
        {content}
      </button>
    );
  };

  /**
   * With ≥2 keys, the key row's left column inlines the first 3 keys + "N more", each the same key-row component as the keys page;
   * read-only, the whole row is still one tap target (enters the keys page).
   */
  function renderInlineKeys(row: DetailRow) {
    return hasInlineKeys(row) && (
      <span className={styles.inlineKeys}>
        {(row.keys ?? []).map((key) => (
          <RelayKeyRowView
            key={key.id}
            element="span"
            className={styles.inlineKey}
            chevron={false}
            rootAttrs={{ 'data-key-inline': key.id }}
            data={{
              title: key.title,
              primaryBadge: key.primaryBadge,
              primaryBadgeText: tRoot('pages.relayDetail.keyPrimaryBadge'),
              preview: key.preview,
              catalog: text(key.catalog),
              statusText: key.statusKey ? tRoot(key.statusKey) : null,
              statusMark: key.statusMark,
            }}
          />
        ))}
        {row.keysMore !== undefined && (
          <span className={styles.inlineKeysMore}>{tRoot(RELAY_DETAIL_TEXT.keysMore, { count: row.keysMore })}</span>
        )}
      </span>
    );
  }

  return (
    <div className={styles.board} data-form={board.form}>
      <header className={styles.header}>
        {board.avatarSource
          ? (
            <span className={styles.headerIcon}>
              <RelayAvatarPickerButton source={board.avatarSource} size={40} />
            </span>
          )
          : (
            <span className={styles.headerIcon} aria-hidden="true">
              <HardDrivesIcon size={40} weight="duotone" />
            </span>
          )}
        <div className={styles.headerIdentity}>
          <div className={styles.headerName}>{nameSlot}</div>
          <p className={styles.statusLine}>
            <span>{tRoot(RELAY_DETAIL_TEXT.modelCount, { count: board.modelCount })}</span>
            {checked && (
              <>
                <span aria-hidden="true"> · </span>
                <span>{tRoot(RELAY_DETAIL_TEXT.checkedAt, { time: checked })}</span>
              </>
            )}
          </p>
        </div>
        <button
          type="button"
          className={styles.editConnectionButton}
          onClick={() => onAction('editConnection')}
          aria-label={tr('editConnection')}
          title={tr('editConnection')}
        >
          <SlidersHorizontalIcon size={22} aria-hidden="true" />
        </button>
      </header>

      <section className={styles.section} data-board-section="connection">
        <h2 className={styles.sectionTitle}>{tRoot('pages.relayDetail.connectionTitle')}</h2>
        <div className={styles.card}>
          {board.connectionRows.map((row) => (
            row.id === 'apiKey'
              ? (
                <div key={row.id} className={styles.rowGroup}>
                  {renderRow(row)}
                  {apiKeyRowExtras}
                </div>
              )
              : renderRow(row)
          ))}
        </div>
      </section>

      <section className={styles.section} data-board-section="models">
        <h2 className={styles.sectionTitle}>{tRoot('pages.relayDetail.models')}</h2>
        <div className={styles.card}>{board.modelRows.map(renderRow)}</div>
      </section>

      <div className={styles.actions}>
        <button
          type="button"
          className={styles.detectButton}
          onClick={onDetectAgain}
          disabled={disabled || isDetecting}
          aria-busy={isDetecting}
        >
          <ScanIcon size={20} aria-hidden="true" />
          <span>{tRoot(isDetecting ? 'pages.relaySetup.detecting' : board.detectButtonKey)}</span>
        </button>
        <button type="button" className={styles.deleteButton} onClick={onDelete} disabled={disabled}>
          <XIcon size={20} aria-hidden="true" />
          <span>{tRoot(board.deleteButtonKey)}</span>
        </button>
      </div>
      <p className={styles.footnote}>{tRoot(board.footnoteKey)}</p>
      {footer}
    </div>
  );
}
