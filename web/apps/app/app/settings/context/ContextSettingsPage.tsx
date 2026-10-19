'use client';

import { useState, type KeyboardEvent, type ReactNode } from 'react';
import { useRouter } from 'next/navigation';
import { useLocale, useTranslations } from 'next-intl';
import { type BudgetCapOption, CONTEXT_BUDGET_CONSTANTS } from '@oriveo/core/context/budget';
import { Circle, CircleCheck } from 'lucide-react';
import { BackButton } from '@oriveo/ui';
import { McpSwitch } from '../../../components/mcp/McpSwitch';
import { useAppStore } from '../../../providers/StoreProvider';
import { resolvePriceLineReminderEnabled } from '../../../lib/core/context-cap-preferences';
import {
  commitCustomCap,
  isolatedCompactCount,
  settingsCapOf,
  type SettingsCapSelection,
} from '../../../lib/core/chat/context-visibility/cap-presentation';
import styles from './ContextSettingsPage.module.css';

/**
 * Settings > AI > Context: the default cap and how to compact when the context is over the limit.
 * Compaction mode: false (default) = keep only what you said; true = AI summary. Writes only the local preference contextAISummaryEnabled.
 * Default cap: auto (default) / unlimited / a custom integer, writes only the local preference contextDefaultCap.
 * Remind when crossing the price line: on by default, writes only the local preference contextPriceLineReminderEnabled.
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
  };

  const radio = (
    selected: boolean,
    title: string,
    hint: string | null,
    testId: string,
    onSelect: () => void,
  ): ReactNode => {
    return (
      <button
        type="button"
        role="radio"
        aria-checked={selected}
        data-testid={testId}
        className={[styles.option, selected ? styles.optionSelected : ''].filter(Boolean).join(' ')}
        onClick={onSelect}
      >
        <span className={styles.optionCopy}>
          <span className={styles.optionTitle}>{title}</span>
          {hint ? <span className={styles.optionHint}>{hint}</span> : null}
        </span>
        <span className={styles.optionRadio} aria-hidden="true">
          {selected ? <CircleCheck size={18} strokeWidth={2.2} /> : <Circle size={18} strokeWidth={2} />}
        </span>
      </button>
    );
  };

  const option = (enabled: boolean, title: string, hint: string, testId: string): ReactNode =>
    radio(enabled === aiEnabled, title, hint, testId, () => select(enabled));

  const capOption = (selection: SettingsCapSelection): ReactNode =>
    radio(cap.selected === selection, tCap(selection), null, `settings-context-cap-${selection}`, () =>
      selectCap(selection),
    );

  return (
    <div className={styles.page}>
      <BackButton className={styles.backLink} label={tCommon('back')} onClick={() => router.push('/settings')} />
      <h1 className={styles.title}>{t('title')}</h1>

      <section className={styles.group}>
        <h2 className={styles.groupTitle} id="context-cap-header">{t('capHeader')}</h2>
        <div className={styles.options} role="radiogroup" aria-labelledby="context-cap-header">
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
                onBlur={commitDraft}
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
          </div>
        ) : null}
        <p className={styles.footer}>
          {t('capFooter', {
            max: isolatedCompactCount(CONTEXT_BUDGET_CONSTANTS.autoCapDefault, locale),
            min: isolatedCompactCount(CONTEXT_BUDGET_CONSTANTS.customCapMin, locale),
          })}
        </p>
      </section>

      <section className={styles.group}>
        <label className={styles.toggle}>
          <span className={styles.toggleTitle}>{t('priceLineReminder')}</span>
          <McpSwitch
            testId="settings-context-price-line-reminder"
            describedBy="context-price-line-reminder-footer"
            label={t('priceLineReminder')}
            checked={priceLineReminder}
            onChange={(next) => setPreferences({ contextPriceLineReminderEnabled: next })}
          />
        </label>
        <p className={styles.footer} id="context-price-line-reminder-footer">
          {t('priceLineReminderFooter')}
        </p>
      </section>

      <section className={styles.group}>
        <h2 className={styles.groupTitle} id="context-overflow-header">{t('overflowHeader')}</h2>
        <div className={styles.options} role="radiogroup" aria-labelledby="context-overflow-header">
          {option(false, t('modeFallback'), t('modeFallbackHint'), 'context-mode-fallback')}
          {option(true, t('modeAi'), t('modeAiHint'), 'context-mode-ai')}
        </div>
        <p className={styles.footer}>{t('overflowFooter')}</p>
      </section>
    </div>
  );
}
