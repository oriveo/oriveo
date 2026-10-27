'use client';

import { useEffect, useRef } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import { BackButton } from '@oriveo/ui';
import { DARK_PALETTE_IDS } from '@oriveo/shared';
import { useAppStore, getVanillaStore } from '../../../providers/StoreProvider';
import * as preferenceOps from '../../../lib/core/preference-ops';
import {
  selectedSwatch,
  swatchLabelKey,
  themePageWrites,
  type SystemAppearance,
  type ThemePageAction,
  type ThemeSwatchId,
} from './theme-page-rules';
import styles from './ThemeSettings.module.css';

/** Inline code sample in the preview reply; code is never localized. */
const PREVIEW_CODE = '&T';
const OWNER_MARK = '\u0001';
const CODE_MARK = '\u0002';

/** Sample model name / cost / code in the mini chat; product data, never localized. */
const PREVIEW_MODEL = 'Claude Opus 5.5';
const PREVIEW_COST = '$0.04';
const PREVIEW_CODE_LANG = 'rust';
/** Same shape as ReasoningBlock formatDuration for 4 s. */
const PREVIEW_THOUGHT_DURATION = '4s';
/** Fixed moment shown in the user bubble, formatted in the user's locale. */
const PREVIEW_SENT_AT = new Date(2026, 9, 26, 21, 41);

/** Light first, then every dark palette in contract order (dark, Purple … Sunset). */
const SWATCHES: readonly ThemeSwatchId[] = ['light', ...DARK_PALETTE_IDS];

function currentSystemAppearance(): SystemAppearance {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return 'light';
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

/** data-theme / data-palette pair that scopes the palette tokens to an element. */
function swatchScope(swatch: ThemeSwatchId) {
  return swatch === 'light'
    ? { 'data-theme': 'light' }
    : { 'data-theme': 'dark', 'data-palette': swatch };
}

export function ThemeSettings() {
  const t = useTranslations('pages.settings');
  const tCommon = useTranslations('common');
  const tPages = useTranslations('pages');
  const tChat = useTranslations('pages.chat');
  const tCapability = useTranslations('capability');
  const locale = useLocale();
  const router = useRouter();
  const selectedCardRef = useRef<HTMLButtonElement | null>(null);
  const theme = useAppStore((s) => s.preferences.theme);
  const darkPalette = useAppStore((s) => s.preferences.darkPalette);

  const follow = theme === 'system';
  const selected = selectedSwatch(theme, darkPalette);

  // Bring the selected card into the horizontal row on first entry only (not on every pick).
  useEffect(() => {
    const card = selectedCardRef.current;
    const row = card?.parentElement;
    if (!card || !row || row.scrollWidth <= row.clientWidth) return;
    row.scrollLeft = Math.max(0, card.offsetLeft - row.offsetLeft - (row.clientWidth - card.offsetWidth) / 2);
  }, []);

  const apply = (action: ThemePageAction) => {
    const writes = themePageWrites({ theme, darkPalette }, action, currentSystemAppearance());
    const store = getVanillaStore();
    if (writes.darkPalette !== undefined) preferenceOps.updateDarkPalette(store, writes.darkPalette);
    if (writes.theme !== undefined) preferenceOps.updateTheme(store, writes.theme);
  };

  const reply = t('themePreviewReply', { owner: OWNER_MARK, code: CODE_MARK })
    .split(new RegExp(`(${OWNER_MARK}|${CODE_MARK})`))
    .map((part, index) => {
      if (part === OWNER_MARK) {
        return <strong key={index} className={styles.previewStrong}>{t('themePreviewOwner')}</strong>;
      }
      if (part === CODE_MARK) {
        return <code key={index} className={styles.previewCode}>{PREVIEW_CODE}</code>;
      }
      return part;
    });

  const sentAt = new Intl.DateTimeFormat(locale, { hour: 'numeric', minute: '2-digit' }).format(PREVIEW_SENT_AT);

  const renderSwatch = (swatch: ThemeSwatchId) => {
    const on = selected === swatch;
    const name = t(swatchLabelKey(swatch));
    return (
      <button
        key={swatch}
        ref={on ? selectedCardRef : undefined}
        type="button"
        className={styles.swatch}
        aria-pressed={on}
        aria-label={name}
        data-swatch={swatch}
        onClick={() => apply({ kind: 'tap', swatch })}
      >
        <span className={`${styles.cardRing} ${on ? styles.cardRingOn : ''}`} aria-hidden>
          <span className={styles.cardFace} {...swatchScope(swatch)}>
            <span className={styles.cardGlow} />
            <span className={`${styles.cardBar} ${styles.cardBarWide}`} />
            <span className={`${styles.cardBar} ${styles.cardBarShort}`} />
            <span className={styles.cardMine} />
          </span>
        </span>
        <span className={`${styles.swatchName} ${on ? styles.swatchNameOn : ''}`} aria-hidden>
          {name}
        </span>
      </button>
    );
  };

  return (
    <div className={styles.page}>
      <BackButton className={styles.backLink} label={tCommon('back')} onClick={() => router.push('/settings')} />
      <h1 className={styles.title}>{t('theme')}</h1>

      <div
        className={styles.preview}
        data-testid="theme-preview"
        role="img"
        aria-label={tPages('backup.preview')}
        {...swatchScope(selected)}
      >
        <div className={styles.previewGlow} aria-hidden />
        <div className={styles.previewBody} aria-hidden>
          <div className={styles.previewTopBar}>
            <svg className={styles.previewBack} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M15 18l-6-6 6-6" />
            </svg>
            <span className={styles.previewModel}>
              <span className={styles.previewModelDot} />
              {PREVIEW_MODEL}
            </span>
            <span className={styles.previewCost}>{PREVIEW_COST}</span>
          </div>

          <div className={styles.previewChat}>
            <div className={styles.previewBubble}>
              <span>{t('themePreviewQuestion')}</span>
              <span className={styles.previewTime}>{sentAt}</span>
            </div>
            <div className={styles.previewThought}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round">
                <circle cx="12" cy="12" r="9" />
                <path d="M12 7v5l3 2" />
              </svg>
              {tChat('thinkingBlock.thoughtFor', { duration: PREVIEW_THOUGHT_DURATION })}
            </div>
            <p className={styles.previewReply}>{reply}</p>
            <div className={styles.previewCodeBlock}>
              <div className={styles.previewCodeHead}>
                <span>{PREVIEW_CODE_LANG}</span>
                <span>{tChat('copy')}</span>
              </div>
              <pre className={styles.previewCodeBody}>
                <span className={styles.previewKeyword}>let</span>
                {' s = '}
                <span className={styles.previewType}>String</span>
                {'::from('}
                <span className={styles.previewString}>{'"hi"'}</span>
                {');\n'}
                <span className={styles.previewKeyword}>let</span>
                {' r = &s;'}
              </pre>
            </div>
            <div className={styles.previewTags}>
              <span className={styles.previewTagReasoning}>{tCapability('reasoning')}</span>
              <span className={styles.previewTagWeb}>{tCapability('web')}</span>
            </div>
          </div>

          <div className={styles.previewComposerWrap}>
            <div className={styles.previewComposer}>
              <span className={styles.previewPlaceholder}>{tChat('placeholder')}</span>
              <span className={styles.previewSend}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M12 19V5M5 12l7-7 7 7" />
                </svg>
              </span>
            </div>
          </div>
        </div>
      </div>

      <section className={styles.group}>
        <h2 className={styles.groupTitle}>{t('themeSectionPalettes')}</h2>
        <div className={styles.cardRow}>{SWATCHES.map(renderSwatch)}</div>
      </section>

      <section className={styles.followCard}>
        <div className={styles.followText}>
          <span id="theme-follow-system-title" className={styles.followTitle}>{t('themeSystem')}</span>
          <span id="theme-follow-system-hint" className={styles.followHint}>
            {t('themeFollowSystemHint')}
          </span>
        </div>
        <button
          type="button"
          role="switch"
          className={styles.followSwitch}
          aria-checked={follow}
          aria-labelledby="theme-follow-system-title"
          aria-describedby="theme-follow-system-hint"
          onClick={() => apply({ kind: 'toggleFollow', on: !follow })}
        >
          <span className={styles.followThumb} aria-hidden />
        </button>
      </section>
    </div>
  );
}
