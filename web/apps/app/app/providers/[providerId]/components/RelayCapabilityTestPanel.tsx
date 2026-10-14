'use client';

import { useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { useLocale, useTranslations } from 'next-intl';
import {
  CheckCircleIcon,
  CheckIcon,
  CircleIcon,
  CircleNotchIcon,
  InfoIcon,
  KeyIcon,
  MinusCircleIcon,
  WarningCircleIcon,
  XCircleIcon,
  type Icon,
} from '@phosphor-icons/react';
import { Button } from '@oriveo/ui';
import { useFocusTrap } from '../../../../lib/hooks/useFocusTrap';
import { setupProtocolForTransport } from '../../relay/new/setup-board';
import {
  relayCapabilityTestPanel,
  type RelayCapabilityTestPanelIcon,
  type RelayCapabilityTestPanelInput,
  type RelayCapabilityTestPanelText,
} from '../relay-capability-test-panel';
import styles from './RelayCapabilityTestPanel.module.css';

const SHORT_TO_TRANSPORT = {
  chat: 'openai_chat_completions',
  responses: 'openai_responses',
  messages: 'anthropic_messages',
  gemini: 'gemini_generate_content',
} as const;

const ICONS: Record<RelayCapabilityTestPanelIcon, Icon> = {
  waiting: CircleIcon,
  running: CircleNotchIcon,
  accepted: CheckCircleIcon,
  rejected: XCircleIcon,
  undetermined: WarningCircleIcon,
  notRun: MinusCircleIcon,
};

export interface RelayCapabilityTestPanelProps {
  modelName: string;
  /** running.elapsedMs is refreshed by the panel every 0.1 s from startedAt. */
  state: Omit<RelayCapabilityTestPanelInput, 'running'> & {
    running: { kind: RelayCapabilityTestPanelInput['items'][number]; startedAt: number } | null;
  };
  onCancel: () => void;
  onDone: () => void;
}

/**
 * Capability test bottom panel (two states of the CapabilityTest board): docked at the bottom on small screens, centered on large ones, modeled on CrosscheckSheet.
 * While running, the backdrop / Esc cannot close it, only "Cancel"; after completion / interruption, "Done", the backdrop or Esc can all close it.
 */
export function RelayCapabilityTestPanel({ modelName, state, onCancel, onDone }: RelayCapabilityTestPanelProps) {
  const tr = useTranslations('pages.relayDetail');
  const tc = useTranslations('common');
  const locale = useLocale();
  const sheetRef = useRef<HTMLElement | null>(null);
  const [now, setNow] = useState(() => Date.now());
  const isRunning = state.phase === 'running';

  // While running, refresh elapsed time every 0.1 s.
  useEffect(() => {
    if (!isRunning) return;
    setNow(Date.now());
    const timer = window.setInterval(() => setNow(Date.now()), 100);
    return () => window.clearInterval(timer);
  }, [isRunning, state.running?.startedAt]);

  const panel = relayCapabilityTestPanel({
    ...state,
    running: state.running ? { kind: state.running.kind, elapsedMs: Math.max(0, now - state.running.startedAt) } : null,
  });
  const dismissibleRef = useRef(panel.dismissible);
  dismissibleRef.current = panel.dismissible;

  useFocusTrap(sheetRef, true);

  useEffect(() => {
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'Escape' || !dismissibleRef.current) return;
      event.preventDefault();
      onDone();
    };
    document.addEventListener('keydown', handleKeyDown);
    return () => {
      document.removeEventListener('keydown', handleKeyDown);
      document.body.style.overflow = previousOverflow;
    };
  }, [onDone]);

  const seconds = useMemo(
    () => new Intl.NumberFormat(locale, { minimumFractionDigits: 1, maximumFractionDigits: 1 }),
    [locale],
  );
  const text = (value: RelayCapabilityTestPanelText): string => {
    const values = value.values
      ? Object.fromEntries(Object.entries(value.values).map(([name, item]) => [name, typeof item === 'object' ? text(item) : item]))
      : undefined;
    const t = value.namespace === 'common' ? tc : tr;
    return values ? t(value.key, values) : t(value.key);
  };

  const title = tr('capabilityTest.panel.title', { model: modelName });
  const [finished, total] = panel.progressFraction;

  return createPortal(
    <div className={styles.layer} role="dialog" aria-modal="true" aria-label={title}>
      <div
        className={styles.backdrop}
        data-captest-backdrop=""
        aria-hidden="true"
        onClick={() => { if (panel.dismissible) onDone(); }}
      />
      <section className={styles.sheet} ref={sheetRef} data-phase={state.phase}>
        <header className={styles.header}>
          <div className={styles.headerText}>
            <h2 className={styles.title}>{title}</h2>
            <div className={styles.chips}>
              <span className={styles.chip}>
                {setupProtocolForTransport(SHORT_TO_TRANSPORT[panel.chips.transport])}
              </span>
              {panel.chips.key !== null && (
                <span className={styles.chip}>
                  <KeyIcon size={13} aria-hidden="true" />
                  {panel.chips.key}
                </span>
              )}
            </div>
          </div>
          {panel.header.kind === 'progress' ? (
            <span className={styles.progressBadge}>
              {tr('capabilityTest.panel.progress', { current: panel.header.current, total: panel.header.total })}
            </span>
          ) : panel.header.kind === 'done' ? (
            <span className={styles.doneBadge}>
              <CheckIcon size={14} weight="bold" aria-hidden="true" />
              {tr('capabilityTest.panel.doneBadge')}
            </span>
          ) : (
            <span className={styles.stoppedBadge}>{tr('capabilityTest.panel.stoppedBadge')}</span>
          )}
        </header>

        <div
          className={styles.progress}
          role="progressbar"
          aria-valuemin={0}
          aria-valuemax={total}
          aria-valuenow={finished}
        >
          <span style={{ width: `${total > 0 ? (finished / total) * 100 : 0}%` }} />
        </div>

        <ul className={styles.rows}>
          {panel.rows.map((row) => {
            const RowIcon = ICONS[row.icon];
            return (
              <li key={row.kind} className={styles.row} data-icon={row.icon}>
                <span className={styles.rowIconFrame} aria-hidden="true">
                  <RowIcon className={styles.rowIcon} size={22} />
                </span>
                <div className={styles.rowText}>
                  <span className={styles.rowTitle}>{tr(row.title)}</span>
                  {row.subtitle && <span className={styles.rowSubtitle}>{text(row.subtitle)}</span>}
                </div>
                {row.trailing && (
                  <span className={styles.rowTrailing}>
                    {row.trailing.kind === 'waiting'
                      ? tr('capabilityTest.panel.waiting')
                      : row.trailing.kind === 'running'
                        ? tr('capabilityTest.panel.elapsedRunning', { seconds: seconds.format(row.trailing.seconds) })
                        : tr('capabilityTest.panel.elapsed', { seconds: seconds.format(row.trailing.seconds) })}
                  </span>
                )}
              </li>
            );
          })}
        </ul>

        <p className={styles.footer}>
          <InfoIcon size={15} aria-hidden="true" />
          <span>{text(panel.footer)}</span>
        </p>

        {panel.button === 'cancel' ? (
          <Button tone="secondary" className={styles.action} onClick={onCancel}>{tc('cancel')}</Button>
        ) : (
          <Button tone="primary" className={styles.action} onClick={onDone}>{tc('done')}</Button>
        )}
      </section>
    </div>,
    document.body,
  );
}
