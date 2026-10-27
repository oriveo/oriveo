'use client';

import { useRef, useState, type CSSProperties, type KeyboardEvent, type ReactNode } from 'react';
import { useRouter } from 'next/navigation';
import { useLocale, useTranslations } from 'next-intl';
import { type BudgetCapOption, CONTEXT_BUDGET_CONSTANTS } from '@oriveo/core/context/budget';
import { BackButton } from '@oriveo/ui';
import { McpSwitch } from '../../../components/mcp/McpSwitch';
import { useAppStore } from '../../../providers/StoreProvider';
import {
  CONTEXT_SETTINGS_HERO_CONSTANTS,
  contextSettingsHeroOf,
  resolvePriceLineReminderEnabled,
} from '../../../lib/core/context-cap-preferences';
import {
  commitCustomCap,
  isolatedCompactCount,
  settingsCapOf,
  type SettingsCapSelection,
} from '../../../lib/core/chat/context-visibility/cap-presentation';
import { ContextSettingsIcon, type ContextSettingsIconName } from './ContextSettingsIcons';
import styles from './ContextSettingsPage.module.css';

const CAP_ICONS: Record<SettingsCapSelection, ContextSettingsIconName> = {
  auto: 'cap-auto',
  unlimited: 'cap-unlimited',
  custom: 'cap-custom',
};

function cx(...names: Array<string | false | null | undefined>): string {
  return names.filter(Boolean).join(' ');
}

/**
 * Settings > AI > Context: the default cap and how to compact when the context is over the limit.
 * Compaction mode: false (default) = keep only what you said; true = AI summary. Writes only the local preference contextAISummaryEnabled.
 * Default cap: auto (default) / unlimited / a custom integer, writes only the local preference contextDefaultCap.
 * Remind when crossing the price line: on by default, writes only the local preference contextPriceLineReminderEnabled.
 * Layout: overview card on top (contextSettingsHeroOf) > default-cap segmented control > price reminder card > two overflow strategy cards.
 */
export function ContextSettingsPage() {
  const t = useTranslations('pages.settings.context');
  const tCap = useTranslations('pages.chat.contextCap');
  const tCommon = useTranslations('common');
  const locale = useLocale();
  const router = useRouter();
  const aiEnabled = useAppStore((s) => s.preferences.contextAISummaryEnabled === true);
  const storedCap = useAppStore((s) => s.preferences.contextDefaultCap);
  const priceLineReminder = useAppStore((s) => resolvePriceLineReminderEnabled(s.preferences));
  const setPreferences = useAppStore((s) => s.setPreferences);
  const cap = settingsCapOf(storedCap);
  // Draft of the custom input box; null = show the currently stored value
  const [draft, setDraft] = useState<string | null>(null);
  const [adjustedTo, setAdjustedTo] = useState<number | null>(null);
  // After Enter has committed, blur on purpose: skip the onBlur commit that follows so the same draft is not written twice
  const skipBlurCommit = useRef(false);

  const select = (enabled: boolean) => {
    if (enabled === aiEnabled) return;
    setPreferences({ contextAISummaryEnabled: enabled });
  };

  const selectCap = (selection: SettingsCapSelection) => {
    if (selection === cap.selected) return;
    const next: BudgetCapOption = selection === 'custom' ? cap.customPrefill : selection;
    setDraft(null);
    setAdjustedTo(null);
    setPreferences({ contextDefaultCap: next });
  };

  const inputText = draft ?? String(cap.customPrefill);
  // The global default maps to no specific model, so there is no U: just clamp to [32000, 2^31-1]
  const preview = commitCustomCap(inputText, null, cap.customPrefill);

  const commitDraft = () => {
    if (draft === null) return;
    const result = commitCustomCap(draft, null, cap.customPrefill);
    setDraft(null);
    if (result.restored) return;
    setAdjustedTo(result.adjusted ? result.value : null);
    if (result.value !== cap.customPrefill) setPreferences({ contextDefaultCap: result.value });
  };

  const onInputKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key !== 'Enter' || event.nativeEvent.isComposing) return;
    event.preventDefault();
    commitDraft();
    skipBlurCommit.current = true;
    event.currentTarget.blur();
    skipBlurCommit.current = false;
  };

  const onInputBlur = () => {
    if (skipBlurCommit.current) return;
    commitDraft();
  };

  // Overview card: while custom, read and echo the same preview (a parsable value shows clamped), fall back to the stored value only when it cannot be parsed
  const hero = contextSettingsHeroOf(
    cap.selected === 'custom' ? (preview.restored ? cap.customPrefill : preview.value) : cap.selected,
  );
  const heroValue =
    hero.valueKind === 'count' && hero.valueTokens !== null
      ? isolatedCompactCount(hero.valueTokens, locale)
      : t('heroFullWindow');
  const markerPosition = `${CONTEXT_SETTINGS_HERO_CONSTANTS.priceLineMarker * 100}%`;
  // The price-line label sits above the bar, its trailing edge aligned to the tick and the text extending toward inline-start (no longer overlapping the end labels below the bar)
  const markerTrailing = `${100 - CONTEXT_SETTINGS_HERO_CONSTANTS.priceLineMarker * 100}%`;

  const capOption = (selection: SettingsCapSelection): ReactNode => {
    const selected = cap.selected === selection;
    return (
      <button
        type="button"
        role="radio"
        aria-checked={selected}
        data-testid={`settings-context-cap-${selection}`}
        className={cx(styles.segment, selected && styles.segmentSelected)}
        onClick={() => selectCap(selection)}
      >
        <ContextSettingsIcon name={CAP_ICONS[selection]} size={22} />
        <span className={styles.segmentLabel}>{tCap(selection)}</span>
      </button>
    );
  };

  const strategyIllustration = (summary: boolean): ReactNode =>
    summary ? (
      <>
        <span className={styles.summaryBlock}>
          <span className={cx(styles.summaryLine, styles.ink)} style={{ width: '84%' }} />
          <span className={cx(styles.summaryLine, styles.ghostFill)} style={{ width: '64%' }} />
          <span className={cx(styles.summaryLine, styles.ghostFill)} style={{ width: '74%' }} />
        </span>
        <span className={cx(styles.bubble, styles.bubbleEnd, styles.ink)} style={{ width: '50%' }} />
        <span className={cx(styles.bubble, styles.trackFill)} style={{ width: '66%' }} />
      </>
    ) : (
      <>
        <span className={cx(styles.bubble, styles.bubbleGhost)} style={{ width: '62%' }} />
        <span className={cx(styles.bubble, styles.bubbleEnd, styles.ink)} style={{ width: '54%' }} />
        <span className={cx(styles.bubble, styles.bubbleGhost)} style={{ width: '70%' }} />
        <span className={cx(styles.bubble, styles.bubbleEnd, styles.ink)} style={{ width: '44%' }} />
      </>
    );

  const option = (enabled: boolean, title: string, hint: string, testId: string): ReactNode => {
    const selected = enabled === aiEnabled;
    return (
      <button
        type="button"
        role="radio"
        aria-checked={selected}
        data-testid={testId}
        className={cx(styles.strategy, selected && styles.strategySelected)}
        onClick={() => select(enabled)}
      >
        <span className={styles.strategyArt} aria-hidden="true">
          {strategyIllustration(enabled)}
        </span>
        <span className={styles.strategyTitleRow}>
          <span className={styles.strategyTitle}>{title}</span>
          <span className={styles.strategyDot} aria-hidden="true">
            {selected ? (
              <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={3.4} strokeLinecap="round" strokeLinejoin="round">
                <path d="M5 12.5l4.5 4.5L19 7.5" />
              </svg>
            ) : null}
          </span>
        </span>
        <span className={styles.strategyHint}>{hint}</span>
        <span className={cx(styles.costTag, enabled ? styles.costExtra : styles.costNone)}>
          <ContextSettingsIcon name={enabled ? 'cost-extra' : 'cost-none'} size={12} />
          {enabled ? t('costExtra') : t('costNone')}
        </span>
      </button>
    );
  };

  return (
    <div className={styles.page}>
      <BackButton className={styles.backLink} label={tCommon('back')} onClick={() => router.push('/settings')} />
      <h1 className={styles.title}>{t('title')}</h1>

      <div className={styles.stack}>
        <section className={styles.hero} aria-labelledby="context-hero-label" data-testid="settings-context-hero">
          <div className={styles.heroHead}>
            <span className={styles.heroLabel} id="context-hero-label">
              <ContextSettingsIcon name="limit-window" size={16} className={styles.heroLabelIcon} />
              {t('heroLabel')}
            </span>
            <span className={styles.heroChip}>{tCap(cap.selected)}</span>
          </div>
          <div className={styles.heroValueRow}>
            <span className={styles.heroValue} data-testid="settings-context-hero-value">
              {heroValue}
            </span>
            {hero.hasUnit ? <span className={styles.heroUnit}>{tCap('inputUnit')}</span> : null}
          </div>
          <div className={styles.scale} aria-hidden="true">
            <div className={styles.scaleLabels}>
              <span className={styles.scaleMarkerLabel} style={{ insetInlineEnd: markerTrailing } as CSSProperties}>
                {t('scalePriceLine')}
              </span>
            </div>
            <div className={styles.scaleTrack}>
              <div
                className={styles.scaleFill}
                data-testid="settings-context-hero-fill"
                style={{ width: `${hero.fill * 100}%` }}
              />
              <div className={styles.scaleMarker} style={{ insetInlineStart: markerPosition } as CSSProperties} />
            </div>
            <div className={styles.scaleLabels}>
              <span className={styles.scaleStart}>0</span>
              <span className={styles.scaleEnd}>{t('scaleWindow')}</span>
            </div>
          </div>
          <p className={styles.heroCaption}>{t(hero.captionKey)}</p>
        </section>

        <section className={styles.group}>
          <h2 className={styles.groupTitle} id="context-cap-header">
            <ContextSettingsIcon name="header-cap" size={15} />
            {t('capHeader')}
          </h2>
          <div className={styles.segments} role="radiogroup" aria-labelledby="context-cap-header">
            {capOption('auto')}
            {capOption('unlimited')}
            {capOption('custom')}
          </div>
          {cap.selected === 'custom' ? (
            <div className={styles.customCap}>
              <label className={styles.customCapField}>
                <span className={styles.customCapLabel}>{tCap('inputLabel')}</span>
                <input
                  type="text"
                  inputMode="numeric"
                  autoComplete="off"
                  className={styles.customCapInput}
                  data-testid="settings-context-cap-input"
                  value={inputText}
                  onChange={(event) => {
                    setDraft(event.target.value);
                    setAdjustedTo(null);
                  }}
                  onBlur={onInputBlur}
                  onKeyDown={onInputKeyDown}
                />
                <span className={styles.customCapUnit}>{tCap('inputUnit')}</span>
              </label>
              {/* Echo is the clamped value that will be stored; hidden while the text does not parse. */}
              {preview.restored ? null : (
                <p className={styles.customCapEcho}>
                  {tCap('inputEcho', { value: isolatedCompactCount(preview.value, locale) })}
                </p>
              )}
              {adjustedTo !== null ? (
                <p className={styles.customCapAdjusted} role="status">
                  {tCap('adjusted', { value: isolatedCompactCount(adjustedTo, locale) })}
                </p>
              ) : null}
              <p className={styles.customCapMin}>
                {t('customMin', { min: isolatedCompactCount(CONTEXT_BUDGET_CONSTANTS.customCapMin, locale) })}
              </p>
            </div>
          ) : null}
          <p className={styles.footer}>{t('perChat')}</p>
        </section>

        <label className={styles.reminder}>
          <span className={styles.reminderIcon} aria-hidden="true">
            <ContextSettingsIcon name="price-line" size={20} />
          </span>
          <span className={styles.reminderCopy}>
            <span className={styles.reminderTitle}>{t('priceLineReminder')}</span>
            <span className={styles.reminderFooter} id="context-price-line-reminder-footer">
              {t('priceLineReminderFooter')}
            </span>
          </span>
          <McpSwitch
            testId="settings-context-price-line-reminder"
            describedBy="context-price-line-reminder-footer"
            label={t('priceLineReminder')}
            checked={priceLineReminder}
            onChange={(next) => setPreferences({ contextPriceLineReminderEnabled: next })}
          />
        </label>

        <section className={styles.group}>
          <h2 className={styles.groupTitle} id="context-overflow-header">
            <ContextSettingsIcon name="header-overflow" size={15} />
            {t('overflowHeader')}
          </h2>
          <div className={styles.strategies} role="radiogroup" aria-labelledby="context-overflow-header">
            {option(false, t('modeFallback'), t('modeFallbackHint'), 'context-mode-fallback')}
            {option(true, t('modeAi'), t('modeAiHint'), 'context-mode-ai')}
          </div>
        </section>

        <div className={styles.localNote}>
          <ContextSettingsIcon name="local-kept" size={16} className={styles.localNoteIcon} />
          <p className={styles.localNoteText}>{t('overflowFooter')}</p>
        </div>
      </div>
    </div>
  );
}
