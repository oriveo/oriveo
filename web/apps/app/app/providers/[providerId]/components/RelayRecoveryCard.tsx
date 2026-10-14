'use client';

import { useId, type ComponentType } from 'react';
import { useTranslations } from 'next-intl';
import {
  ArrowClockwiseIcon,
  CaretRightIcon,
  CircleNotchIcon,
  KeyIcon,
  SlidersHorizontalIcon,
  WarningIcon,
  XIcon,
  type IconProps,
} from '@phosphor-icons/react';
import type {
  RelayRecoveryActionID,
  RelayRecoveryCard as RelayRecoveryCardState,
} from '../relay-detail-board';
import styles from './RelayDetailBoard.module.css';

const ACTION_ICONS: Record<RelayRecoveryActionID, ComponentType<IconProps>> = {
  editConnection: SlidersHorizontalIcon,
  apiKeys: KeyIcon,
  reverify: ArrowClockwiseIcon,
};

interface RelayRecoveryCardProps {
  card: RelayRecoveryCardState;
  /** Localization of the reason line (errors.* mapping); the board model only provides the original text. */
  localizeReason: (reason: string) => string;
  onAction: (id: RelayRecoveryActionID) => void;
  /** × at top right: the hidden state is held by the page (page-level, not persisted). */
  onDismiss: () => void;
}

/**
 * Relay / local connection error recovery card: neutral card surface, first row warning + title + reason + × at top right,
 * the action row below. The × is delegated to the page to hide (valid for this visit to the detail page, not persisted). The view renders only from the output of `relayDetailRecoveryCard`.
 */
export function RelayRecoveryCard({ card, localizeReason, onAction, onDismiss }: RelayRecoveryCardProps) {
  const tRoot = useTranslations();
  const titleID = useId();
  const TitleIcon = card.titleIcon === 'key' ? KeyIcon : WarningIcon;
  const titleContent = (
    <>
      <span className={styles.rowIcon} style={{ color: 'var(--o-warning)' }} aria-hidden="true">
        <TitleIcon size={22} weight="duotone" />
      </span>
      {/* Title body semibold primary color, reason footnote secondary color, reusing the title-only mode hierarchy. */}
      <span className={styles.rowStack} data-title-only="true">
        <span className={styles.rowTitle} id={titleID}>{tRoot(card.titleKey)}</span>
        {card.reason && <span className={styles.rowValue} data-recovery-reason>{localizeReason(card.reason)}</span>}
      </span>
      {card.titleAction && <CaretRightIcon size={16} className={styles.rowChevron} aria-hidden="true" />}
    </>
  );
  return (
    <section className={styles.recoveryCard} aria-labelledby={titleID} data-recovery-card={card.titleIcon}>
      <div className={styles.card}>
        <div className={styles.recoveryTitleLine}>
          {card.titleAction ? (
            <button type="button" className={styles.row} onClick={() => onAction('apiKeys')}>{titleContent}</button>
          ) : (
            <div className={styles.row}>{titleContent}</div>
          )}
          <button
            type="button"
            className={styles.recoveryDismiss}
            data-recovery-dismiss
            onClick={onDismiss}
            aria-label={tRoot('common.close')}
            title={tRoot('common.close')}
          >
            <XIcon size={14} weight="bold" aria-hidden="true" />
          </button>
        </div>
        {card.actions.map((action) => {
          const Icon = action.running ? CircleNotchIcon : ACTION_ICONS[action.id];
          return (
            <button
              key={action.id}
              type="button"
              className={styles.row}
              data-recovery-action={action.id}
              onClick={() => onAction(action.id)}
              disabled={action.disabled}
              aria-busy={action.running}
            >
              <span className={styles.rowIcon} aria-hidden="true">
                <Icon size={20} className={action.running ? styles.spin : undefined} />
              </span>
              <span className={styles.rowStack}>
                <span className={styles.rowTitle}>{tRoot(action.titleKey)}</span>
              </span>
              {action.destination && <CaretRightIcon size={16} className={styles.rowChevron} aria-hidden="true" />}
            </button>
          );
        })}
      </div>
    </section>
  );
}
