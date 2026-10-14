'use client';

import { useEffect, useRef, useState, type CSSProperties } from 'react';
import { useTranslations } from 'next-intl';
import {
  BrainIcon,
  CheckCircleIcon,
  DotsThreeIcon,
  EyeIcon,
  GlobeIcon,
  KeyIcon,
  PaperclipIcon,
  WrenchIcon,
  type Icon,
} from '@phosphor-icons/react';
import { ProtocolDot } from '../../relay/new/setup-board-parts';
import {
  RELAY_CATALOG_TEXT,
  isRelayCatalogKeyFilter,
  sameRelayCatalogFilter,
  type RelayCatalogCap,
  type RelayCatalogCapState,
  type RelayCatalogFilter,
  type RelayCatalogKeyStripItem,
  type RelayCatalogMenuItem,
  type RelayCatalogRow,
} from '../relay-catalog-board';
import styles from './RelayCatalogParts.module.css';

/** The five capability icons and capability color tokens (same set as the model option card: eye / paperclip / brain / wrench / globe). */
const CAP_ICONS: Record<RelayCatalogCap, { Icon: Icon; color: string }> = {
  image: { Icon: EyeIcon, color: 'var(--o-cap-vision)' },
  file: { Icon: PaperclipIcon, color: 'var(--o-cap-attachment)' },
  thinking: { Icon: BrainIcon, color: 'var(--o-cap-reasoning)' },
  tool: { Icon: WrenchIcon, color: 'var(--o-cap-tools)' },
  web: { Icon: GlobeIcon, color: 'var(--o-cap-web-search)' },
};

function CapIcon({ cap, state }: { cap: RelayCatalogCap; state: RelayCatalogCapState }) {
  const { Icon, color } = CAP_ICONS[cap];
  return (
    <span
      className={styles.capIcon}
      data-cap-icon={cap}
      data-cap-state={state}
      style={{ '--cap-color': color } as CSSProperties}
      aria-hidden="true"
    >
      <Icon size={16} weight={state === 'supported' ? 'duotone' : 'regular'} />
    </span>
  );
}

/**
 * Row content (matches iOS RelayCatalogRowContent): name alone on the first line; second line protocol chip → key chip (≥2 keys),
 * when it does not fit the key chip wraps whole to the next line (flex-wrap, no JS measuring); the five icons always sit alone on the line below the chips; status text in the trailing column.
 * `hideStatus`: the caller draws the status in the trailing column (enabled rows, on the same midline as chat / ⋯).
 */
export function RelayCatalogRowBody({ row, hideStatus = false }: { row: RelayCatalogRow; hideStatus?: boolean }) {
  return (
    <span className={styles.rowBody}>
      <span className={styles.rowMain} data-row-lead>
        <span className={styles.rowTitle}>
          <span className={styles.rowName}>{row.model.name}</span>
        </span>
        {(row.protocol || row.keyChip) && (
          <span className={styles.rowChips} data-row-chips>
            {row.protocol && (
              <span className={styles.protocolChip} data-protocol={row.protocol}>
                <ProtocolDot protocol={row.protocol} />
                {row.protocol}
              </span>
            )}
            {row.keyChip && (
              <span className={styles.keyChip} data-key-chip>
                <KeyIcon size={11} weight="bold" aria-hidden="true" />
                <span className={styles.keyChipText}>{row.keyChip}</span>
              </span>
            )}
          </span>
        )}
        <span className={styles.capRow} data-cap-row>
          {row.caps.map(({ cap, state }) => <CapIcon key={cap} cap={cap} state={state} />)}
        </span>
      </span>
      {row.status && !hideStatus && <RelayCatalogStatusText status={row.status} />}
    </span>
  );
}

/** Status text: trailing column, max width 84px, may wrap. */
export function RelayCatalogStatusText({ status }: { status: NonNullable<RelayCatalogRow['status']> }) {
  const tRoot = useTranslations();
  return (
    <span className={styles.status} data-status={status}>
      {tRoot(RELAY_CATALOG_TEXT.status[status])}
    </span>
  );
}

/** Row screen-reader value: the model name, then each icon in order as "capability name status word", joined with ", ". */
export function useRelayCatalogRowLabel(): (row: RelayCatalogRow) => string {
  const tRoot = useTranslations();
  return (row) => [
    row.model.name,
    ...row.accessibilityValue.map((item) => `${tRoot(item.titleKey)} ${tRoot(item.stateKey)}`),
  ].join(', ');
}

/**
 * Trailing "⋯" on enabled rows: the menu has only "Remove"; with just one left it is greyed out with a reason.
 * Click outside or press Esc to close.
 */
export function RelayCatalogMoreMenu({
  items,
  onRemove,
  buttonClassName,
}: {
  items: readonly RelayCatalogMenuItem[];
  onRemove: () => void;
  buttonClassName?: string;
}) {
  const tRoot = useTranslations();
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    if (!open) return;
    const onPointerDown = (event: MouseEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) setOpen(false);
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setOpen(false);
    };
    document.addEventListener('mousedown', onPointerDown);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('mousedown', onPointerDown);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [open]);
  return (
    <span className={styles.moreMenuRoot} ref={rootRef}>
      <button
        type="button"
        className={buttonClassName}
        data-trailing="more"
        onClick={() => setOpen((value) => !value)}
        aria-label={tRoot(RELAY_CATALOG_TEXT.more)}
        title={tRoot(RELAY_CATALOG_TEXT.more)}
        aria-haspopup="menu"
        aria-expanded={open}
      >
        <DotsThreeIcon size={16} weight="bold" aria-hidden="true" />
      </button>
      {open && (
        <span className={styles.moreMenu} role="menu">
          {items.map((item) => (
            <span key={item.action} className={styles.moreMenuEntry}>
              <button
                type="button"
                role="menuitem"
                className={styles.moreMenuItem}
                data-menu-action={item.action}
                disabled={!item.enabled}
                onClick={() => {
                  if (!item.enabled) return;
                  setOpen(false);
                  onRemove();
                }}
              >
                {tRoot(RELAY_CATALOG_TEXT.remove)}
              </button>
              {item.reasonKey && <span className={styles.moreMenuReason}>{tRoot(item.reasonKey)}</span>}
            </span>
          ))}
        </span>
      )}
    </span>
  );
}

/**
 * With ≥2 keys, the top of the catalog area shows one line per key: the left column has two lines, "name or mask" / "Catalog: N models", each truncated to 1 line;
 * trailing = status (✓, or on failure "<code> <status word>", ≤ 50% of row width, ≤ 2 lines) + Retry (refreshes only this key, intrinsic width, neither wrapping nor squeezed).
 */
export function RelayCatalogKeyStrip({
  items,
  onRetry,
  disabled = false,
}: {
  items: readonly RelayCatalogKeyStripItem[];
  onRetry: (keyID: string) => void;
  disabled?: boolean;
}) {
  const tRoot = useTranslations();
  if (items.length === 0) return null;
  return (
    // Per-key status bar: card surface, row min height 44 + hairline separators.
    <ul className={styles.keyStrip}>
      {items.map((item) => (
        <li key={item.id} className={styles.keyStripItem} data-key-strip-item={item.id} data-state={item.state}>
          <KeyIcon size={14} weight="bold" aria-hidden="true" />
          {/* Column area: total = after the icons, before Retry; status column = min(ideal single-line width, total × 50%). */}
          <span className={styles.keyStripColumns} data-key-strip-columns>
            <span className={styles.keyStripLead} data-key-strip-lead>
              {/* Name on 1 line: CSS approximates iOS middle truncation with single-line ellipsis. */}
              <span className={styles.keyStripTitle} data-key-strip-title>{item.title}</span>
              <span className={styles.keyStripMeta} data-key-strip-meta>
                {tRoot('pages.relayDetail.keyCatalogCount', { count: item.catalogCount })}
              </span>
            </span>
            {item.state === 'ok' && (
              <span className={styles.keyStripStatus} data-key-strip-status>
                <span className={styles.keyStripOk} data-key-strip-ok aria-hidden="true">
                  <CheckCircleIcon size={16} weight="duotone" />
                </span>
              </span>
            )}
            {item.state === 'failed' && (
              <span className={styles.keyStripStatus} data-key-strip-status>
                <span className={styles.keyStripFailure} data-key-strip-failure>
                  {[item.httpStatus, item.statusKey ? tRoot(item.statusKey) : undefined].filter((part) => part !== undefined).join(' ')}
                </span>
              </span>
            )}
          </span>
          {item.state === 'failed' && (
            <button
              type="button"
              className={styles.keyStripRetry}
              data-key-strip-retry
              onClick={() => onRetry(item.id)}
              disabled={disabled}
            >
              {tRoot('common.retry')}
            </button>
          )}
        </li>
      ))}
    </ul>
  );
}

export function RelayCatalogChips({
  chips,
  selected,
  keyTitle,
  onSelect,
}: {
  chips: readonly RelayCatalogFilter[];
  selected: RelayCatalogFilter;
  /** Key display name for the key(id) chip (filterKeyTitle on the board). */
  keyTitle: string | null;
  onSelect: (filter: RelayCatalogFilter) => void;
}) {
  const tRoot = useTranslations();
  if (chips.length === 0) return null;
  return (
    <div className={styles.chips} role="group">
      {chips.map((chip) => {
        const active = sameRelayCatalogFilter(selected, chip);
        const id = isRelayCatalogKeyFilter(chip) ? 'key' : chip;
        return (
          <button
            key={id}
            type="button"
            className={styles.chip}
            data-catalog-chip={id}
            data-active={active}
            aria-pressed={active}
            onClick={() => onSelect(chip)}
          >
            {isRelayCatalogKeyFilter(chip) ? tRoot(RELAY_CATALOG_TEXT.filterKey, { name: keyTitle ?? '' }) : chip === 'all' ? tRoot(RELAY_CATALOG_TEXT.filterAll) : (
              <>
                <ProtocolDot protocol={chip} />
                {chip}
              </>
            )}
          </button>
        );
      })}
    </div>
  );
}

/** Bottom legend with three items + footnote (the source shows only under "Advanced", not in the row). */
export function RelayCatalogLegend() {
  const tRoot = useTranslations();
  const items: { key: string; state: RelayCatalogCapState }[] = [
    { key: RELAY_CATALOG_TEXT.legendSupported, state: 'supported' },
    { key: RELAY_CATALOG_TEXT.legendUnknown, state: 'unknown' },
    { key: RELAY_CATALOG_TEXT.legendUnsupported, state: 'unsupported' },
  ];
  return (
    <div className={styles.legendBlock}>
      <ul className={styles.legend} data-catalog-legend>
        {items.map((item) => (
          <li key={item.key} className={styles.legendItem}>
            <span className={styles.legendDot} data-state={item.state} aria-hidden="true" />
            <span data-legend-item>{tRoot(item.key)}</span>
          </li>
        ))}
      </ul>
      <p className={styles.footnote} data-catalog-footnote>{tRoot(RELAY_CATALOG_TEXT.sourcesFootnote)}</p>
    </div>
  );
}
