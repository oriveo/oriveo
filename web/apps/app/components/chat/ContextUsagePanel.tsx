'use client';

import { useCallback, useEffect, useRef, useState, useSyncExternalStore, type ReactNode } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import type { AIModel, Conversation, Provider } from '@oriveo/shared';
import { Button } from '@oriveo/ui';
import { formatCompactCount } from '../../lib/core/chat/context-compaction/context-compaction-presentation';
import {
  clearCompaction,
  manualCompact,
  type CompactionToast,
} from '../../lib/core/chat/context-compaction/context-compaction-actions';
import {
  CompactionBreakers,
  isAICompacting,
  subscribeAICompacting,
} from '../../lib/core/chat/context-pipeline/compaction-coordinator';
import type { ContextUsageState } from '../../lib/core/chat/context-visibility/use-context-usage';
import {
  capOptionText,
  capPanelOf,
  capPresentationInputOf,
  isolatedCompactCount,
  multiplierPhrase,
} from '../../lib/core/chat/context-visibility/cap-presentation';
import {
  breakerRetryShown,
  omittedRowsOf,
  panelArcsOf,
  panelBodyOf,
  panelButtonsOf,
  panelLegendOf,
  type OmittedKind,
  type UsageSegmentKind,
} from '../../lib/core/chat/context-visibility/usage-panel-model';
import { formatRelativeTime } from '../../lib/utils/format-utils';
import { useAppStore } from '../../providers/StoreProvider';
import { showToast } from '../Toast';
import { ContextCapPicker } from './ContextCapPicker';
import styles from './ContextUsagePanel.module.css';

interface ContextUsagePanelProps {
  open: boolean;
  onClose: () => void;
  /** Null for drafts: the panel still opens and shows the empty hint. */
  conversationId: string | null;
  state: ContextUsageState | null;
  /** Sending / generating: [Condense context] is disabled. */
  sending: boolean;
  onNewChatWithSummary: () => void;
  /** Window / price-line inputs of the "limit for this chat" and window rows. */
  conversation?: Conversation | null;
  provider?: Provider | null;
  currentModel?: AIModel | null;
  /** Panel "max output" of the current model (chatUserMaxOutputFor), same window input as the send path. */
  userMaxOutput?: number | null;
  /** Anchor (the composer ring); the popover opens above its right edge. */
  children?: ReactNode;
}

const SIZE = 200;
const STROKE = 14;
const RADIUS = (SIZE - STROKE) / 2;
const CIRCUMFERENCE = 2 * Math.PI * RADIUS;

const SEGMENT_LABEL: Record<UsageSegmentKind, string> = {
  conversation: 'segmentConversation',
  library: 'segmentLibrary',
  summary: 'segmentSummary',
  instructions: 'segmentInstructions',
  memory: 'segmentMemory',
  free: 'segmentFree',
};

const OMITTED_LABEL: Record<OmittedKind, string> = {
  notes: 'omittedNotes',
  knowledge: 'omittedKnowledge',
  memory: 'omittedMemory',
};

const TOAST_KEY: Record<CompactionToast, 'toastFallback' | 'toastNoop'> = {
  fallback: 'toastFallback',
  noop: 'toastNoop',
};

/**
 * context panel (contract item 4): popover above the composer, opened by the ring and by the
 * conversation settings usage row.
 */
export function ContextUsagePanel({
  open,
  onClose,
  conversationId,
  state,
  sending,
  onNewChatWithSummary,
  conversation,
  provider,
  currentModel,
  userMaxOutput,
  children,
}: ContextUsagePanelProps) {
  const t = useTranslations('pages.chat.contextUsage');
  const tCap = useTranslations('pages.chat.contextCap');
  const preferences = useAppStore((s) => s.preferences);
  const tCompaction = useTranslations('pages.chat.contextCompaction');
  const tCommon = useTranslations('common');
  const locale = useLocale();
  const anchorRef = useRef<HTMLDivElement>(null);
  const [running, setRunning] = useState(false);
  // Tapping the cap row swaps the popover content to the cap picker; closing returns to the panel.
  const [view, setView] = useState<'panel' | 'capPicker'>('panel');
  useEffect(() => {
    if (!open) setView('panel');
  }, [open]);
  // Breakers are in-memory and not observable; bump after [Retry] to re-read the mode.
  const [, setBreakerVersion] = useState(0);

  const subscribeCompacting = useCallback((onChange: () => void) => subscribeAICompacting(() => onChange()), []);
  const aiCompacting = useSyncExternalStore(
    subscribeCompacting,
    () => (conversationId ? isAICompacting(conversationId) : false),
    () => false,
  );

  useEffect(() => {
    if (!open) return undefined;
    const onMouseDown = (event: MouseEvent) => {
      if (anchorRef.current && !anchorRef.current.contains(event.target as Node)) onClose();
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose();
    };
    document.addEventListener('mousedown', onMouseDown);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('mousedown', onMouseDown);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [open, onClose]);

  const summary = state?.summary ?? null;
  const checkpoint = state?.checkpoint ?? null;
  const body = panelBodyOf(summary);
  const legend = body.kind === 'ring' ? panelLegendOf(summary?.segments ?? null) : [];
  const arcs = body.kind === 'ring' ? panelArcsOf(summary?.segments ?? null, summary?.B ?? null) : [];
  const omitted = omittedRowsOf(summary?.omitted ?? null);
  const buttons = panelButtonsOf({
    hasCheckpoint: checkpoint !== null,
    compacting: running || aiCompacting,
    sending,
  });
  const breakerPaused = conversationId !== null && breakerRetryShown(CompactionBreakers.mode(conversationId));
  const compact = (value: number) => formatCompactCount(value, locale);
  const isolated = (value: number) => isolatedCompactCount(value, locale);

  // "limit for this chat" row + window row (replaces the effective-limit note).
  const capInput = capPresentationInputOf({ conversation, preferences, provider, model: currentModel, userMaxOutput });
  const capPanel = capInput ? capPanelOf({ ...capInput, used: summary?.used ?? 0 }) : null;
  const priceLine = capInput?.priceLineTokens ?? null;
  const aboveLine = capPanel?.windowLine === 'aboveLine' && priceLine !== null ? priceLine : null;
  const capValueText = capInput && capPanel
    ? capPanel.capValue !== null
      ? isolated(capPanel.capValue)
      : capOptionText(capInput.conversationCap ?? capInput.globalCap, locale, {
        auto: tCap('auto'),
        unlimited: tCap('unlimited'),
      })
    : null;
  let windowRowText: string | null = null;
  if (capInput && capPanel) {
    const W = capInput.W;
    if (capPanel.windowLine === 'window' && W !== null) {
      windowRowText = tCap('windowLine', { window: isolated(W) });
    } else if (capPanel.windowLine === 'windowPriceLine' && W !== null && priceLine !== null) {
      const mult = multiplierPhrase(capPanel.multiplier, locale, tCap);
      windowRowText = mult
        ? tCap('windowLinePrice', { window: isolated(W), line: isolated(priceLine), mult })
        : tCap('windowLinePricePlain', { window: isolated(W), line: isolated(priceLine) });
    } else if (aboveLine !== null) {
      windowRowText = tCap('aboveLine', { line: isolated(aboveLine) });
    }
  }
  const observed = body.kind === 'ring' && body.basis === 'observed';
  // Used unknown: fall back to the plain measured / estimated label (no distance to the price line).
  const distance = aboveLine !== null && summary?.used != null ? capPanel?.priceLineDistance ?? null : null;
  let basisText: string;
  if (distance === null) basisText = observed ? t('measured') : t('estimated');
  else if (distance > 0) {
    basisText = observed
      ? t('measuredPriceLine', { value: isolated(distance) })
      : t('estimatedPriceLine', { value: isolated(distance) });
  } else basisText = observed ? t('measuredPriceLineCrossed') : t('estimatedPriceLineCrossed');
  // Price-line tick on the ring: fraction of the ring's B (T < B only).
  const ringB = summary?.B ?? capPanel?.capValue ?? null;
  const tickFraction = aboveLine !== null && ringB !== null && ringB > 0 && aboveLine < ringB ? aboveLine / ringB : null;

  const handleCompact = async () => {
    if (!conversationId || running) return;
    setRunning(true);
    try {
      const toast = await manualCompact(conversationId);
      if (toast) showToast(tCompaction(TOAST_KEY[toast]));
    } catch (error) {
      console.error('[ContextUsage] manual compaction failed:', error);
      showToast(tCommon('error'), 3000, undefined, 'error');
    } finally {
      setRunning(false);
    }
  };

  const handleClear = async () => {
    if (!conversationId || running) return;
    setRunning(true);
    try {
      await clearCompaction(conversationId);
      showToast(tCompaction('toastCleared'));
    } catch (error) {
      console.error('[ContextUsage] clearing compaction failed:', error);
      showToast(tCommon('error'), 3000, undefined, 'error');
    } finally {
      setRunning(false);
    }
  };

  const handleRetry = () => {
    if (!conversationId) return;
    CompactionBreakers.retry(conversationId);
    setBreakerVersion((v) => v + 1);
  };

  const handleNewChat = () => {
    onNewChatWithSummary();
    onClose();
  };

  return (
    <div className={styles.anchor} ref={anchorRef}>
      {children}
      {open && view === 'capPicker' && conversationId !== null && capInput && currentModel ? (
        <section className={styles.popover} role="dialog" aria-labelledby="context-cap-picker-title">
          <ContextCapPicker
            conversationId={conversationId}
            capInput={capInput}
            modelName={currentModel.name || currentModel.id}
            onBack={() => setView('panel')}
          />
        </section>
      ) : open && (
        <section className={styles.popover} role="dialog" aria-labelledby="context-usage-title">
          <header className={styles.header}>
            <h2 id="context-usage-title" className={styles.title}>
              {t('title')}
            </h2>
            <button type="button" className={styles.done} onClick={onClose}>
              {tCommon('done')}
            </button>
          </header>

          {body.kind === 'ring' ? (
            <div className={styles.ringBlock} data-tone={summary?.tone ?? 'neutral'}>
              <div className={styles.ring}>
                <svg width={SIZE} height={SIZE} viewBox={`0 0 ${SIZE} ${SIZE}`} aria-hidden="true">
                  <circle className={styles.track} cx={SIZE / 2} cy={SIZE / 2} r={RADIUS} strokeWidth={STROKE} fill="none" />
                  {arcs.map((arc) => (
                    <circle
                      key={arc.kind}
                      className={styles.arc}
                      data-kind={arc.kind}
                      cx={SIZE / 2}
                      cy={SIZE / 2}
                      r={RADIUS}
                      strokeWidth={STROKE}
                      fill="none"
                      strokeDasharray={`${arc.length * CIRCUMFERENCE} ${CIRCUMFERENCE}`}
                      strokeDashoffset={-arc.start * CIRCUMFERENCE}
                      transform={`rotate(-90 ${SIZE / 2} ${SIZE / 2})`}
                    />
                  ))}
                  {tickFraction !== null ? <PriceLineTick fraction={tickFraction} /> : null}
                </svg>
                <div className={styles.center}>
                  <span className={styles.percent}>
                    {body.about ? t('aboutPercent', { percent: body.percent }) : `${body.percent}%`}
                  </span>
                  {summary?.used != null && summary.B != null ? (
                    <span className={styles.used}>{`${compact(summary.used)} / ${compact(summary.B)}`}</span>
                  ) : null}
                </div>
              </div>
              <span className={styles.basis}>{basisText}</span>
            </div>
          ) : (
            <div className={styles.ringBlock}>
              <div className={styles.ring}>
                <svg width={SIZE} height={SIZE} viewBox={`0 0 ${SIZE} ${SIZE}`} aria-hidden="true">
                  <circle className={styles.dashed} cx={SIZE / 2} cy={SIZE / 2} r={RADIUS} strokeWidth={2} fill="none" />
                </svg>
                <div className={styles.center}>
                  <span className={styles.unavailable}>{t('unavailable')}</span>
                </div>
              </div>
              <p className={styles.hint}>{t(body.hint)}</p>
            </div>
          )}

          {legend.length > 0 ? (
            <ul className={styles.legend}>
              {legend.map((item) => (
                <li key={item.kind} className={styles.legendRow}>
                  <span className={styles.swatch} data-kind={item.kind} aria-hidden="true" />
                  <span className={styles.legendLabel}>{t(SEGMENT_LABEL[item.kind])}</span>
                  <span className={styles.legendValue}>{compact(item.tokens)}</span>
                </li>
              ))}
              {aboveLine !== null ? (
                <li className={styles.legendRow}>
                  <span className={styles.swatch} data-kind="priceLine" aria-hidden="true" />
                  <span className={styles.legendLabel}>{t('legendPriceLine')}</span>
                  <span className={styles.legendValue}>{compact(aboveLine)}</span>
                </li>
              ) : null}
            </ul>
          ) : null}

          {conversationId !== null && capValueText !== null ? (
            <button
              type="button"
              className={styles.capRow}
              data-testid="chat-context-cap-row"
              onClick={() => setView('capPicker')}
            >
              <span className={styles.capLabel}>{tCap('title')}</span>
              <span className={styles.capValue}>{capValueText}</span>
              <span className={styles.chevron} aria-hidden="true">›</span>
            </button>
          ) : null}
          {conversationId !== null && capPanel?.limitedByModel && capPanel.actual !== null ? (
            <p className={styles.note} data-testid="chat-context-cap-limited">
              {tCap('rowLimited', { value: isolated(capPanel.actual) })}
            </p>
          ) : null}
          {windowRowText !== null ? (
            <p className={styles.note} data-testid="chat-context-window-row">
              {windowRowText}
            </p>
          ) : null}
          {omitted.map((row) => (
            <p key={row.kind} className={styles.note}>
              {t(OMITTED_LABEL[row.kind], { count: row.count })}
            </p>
          ))}
          {checkpoint ? (
            <p className={styles.note}>
              {t('compactedCount', {
                count: checkpoint.count,
                time: formatRelativeTime(new Date(checkpoint.latestCreatedAt).toISOString(), locale),
              })}
            </p>
          ) : null}
          {breakerPaused ? (
            <div className={styles.breaker}>
              <p className={styles.breakerText}>{t('breakerPaused')}</p>
              <Button tone="secondary" size="sm" onClick={handleRetry}>
                {t('retry')}
              </Button>
            </div>
          ) : null}

          <div className={styles.actions}>
            <Button
              tone="secondary"
              size="sm"
              disabled={buttons.compact.disabled || !conversationId}
              onClick={() => void handleCompact()}
            >
              {tCompaction('actionCompact')}
            </Button>
            {buttons.newChatWithSummary ? (
              <Button tone="secondary" size="sm" disabled={running} onClick={handleNewChat}>
                {tCompaction('actionNewChatWithSummary')}
              </Button>
            ) : null}
            {buttons.clear ? (
              <Button tone="secondary" size="sm" disabled={running} onClick={() => void handleClear()}>
                {tCompaction('actionClear')}
              </Button>
            ) : null}
          </div>
        </section>
      )}
    </div>
  );
}

const TICK_INNER = RADIUS - STROKE / 2 - 3;
const TICK_OUTER = RADIUS + STROKE / 2 + 3;

/** Long-context price line marker across the ring at fraction of B (clockwise from the top). */
function PriceLineTick({ fraction }: { fraction: number }) {
  const angle = 2 * Math.PI * fraction - Math.PI / 2;
  const cx = SIZE / 2;
  const cy = SIZE / 2;
  return (
    <line
      className={styles.priceLineTick}
      data-testid="chat-context-price-line-tick"
      x1={cx + TICK_INNER * Math.cos(angle)}
      y1={cy + TICK_INNER * Math.sin(angle)}
      x2={cx + TICK_OUTER * Math.cos(angle)}
      y2={cy + TICK_OUTER * Math.sin(angle)}
    />
  );
}
