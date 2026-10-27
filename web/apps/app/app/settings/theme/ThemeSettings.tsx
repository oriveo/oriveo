'use client';

import { useCallback, useEffect, useRef, useState, useSyncExternalStore, type CSSProperties, type KeyboardEvent } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import { BackButton } from '@oriveo/ui';
import {
  CUSTOM_HUE_SLIDER,
  DEFAULT_CUSTOM_SEED,
  customLightBrandCssVars,
  customPaletteCssVars,
  deriveCustom,
  deriveCustomLight,
  hueSliderSeed,
  oklch,
  parseSeed,
  resolvePaletteChoice,
  type PaletteChoice,
  type ThemeOption,
} from '@oriveo/shared';
import { useAppStore, getVanillaStore } from '../../../providers/StoreProvider';
import * as preferenceOps from '../../../lib/core/preference-ops';
import {
  APPEARANCE_SEGMENTS,
  CUSTOM_PRESET_DOTS,
  PALETTE_CARDS,
  appearanceLabelKey,
  appearancePageWrites,
  cardLabelKey,
  selectedCard,
  type AppearancePageAction,
  type PaletteCardId,
} from './theme-page-rules';
import { highlightCode } from '../../../lib/markdown/highlight-setup';
import { anchoredBubbleGradient } from '../../../components/chat/user-bubble-gradient';
import '../../../components/chat/highlight-theme.css';
import styles from './ThemeSettings.module.css';

/** Inline code sample in the preview reply; code is never localized. */
const PREVIEW_CODE = '&T';
const OWNER_MARK = '\u0001';
const CODE_MARK = '\u0002';

/** Sample model name / cost / code in the mini chat; product data, never localized. */
const PREVIEW_MODEL = 'Claude Opus 5.5';
const PREVIEW_COST = '$0.04';
const PREVIEW_CODE_LANG = 'rust';
const PREVIEW_CODE_SOURCE = 'let s = String::from("hi");\nlet r = &s;';
/** Same highlight.js pass and theme CSS as chat code blocks, so the preview shows the real Oriveo Code colors. */
const PREVIEW_CODE_HTML = highlightCode(PREVIEW_CODE_SOURCE, PREVIEW_CODE_LANG);
/** Same shape as ReasoningBlock formatDuration for 4 s. */
const PREVIEW_THOUGHT_DURATION = '4s';
/** Fixed moment shown in the user bubble, formatted in the user's locale. */
const PREVIEW_SENT_AT = new Date(2026, 9, 26, 21, 41);

/** Hue slider track: the slider's own seeds every 30°, so the track shows exactly what a drag picks. */
const HUE_TRACK = `linear-gradient(90deg, ${Array.from({ length: 13 }, (_, i) => hueSliderSeed(Math.min(i * 30, CUSTOM_HUE_SLIDER.max))).join(', ')})`;

type Appearance = 'light' | 'dark';

const DARK_QUERY = '(prefers-color-scheme: dark)';

function subscribeSystemAppearance(onChange: () => void): () => void {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return () => {};
  const mq = window.matchMedia(DARK_QUERY);
  mq.addEventListener('change', onChange);
  return () => mq.removeEventListener('change', onChange);
}

function systemAppearance(): Appearance {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return 'light';
  return window.matchMedia(DARK_QUERY).matches ? 'dark' : 'light';
}

/** Appearance in effect right now (system follows the OS); cards and preview draw in it. */
function useEffectiveAppearance(theme: ThemeOption): Appearance {
  const system = useSyncExternalStore(subscribeSystemAppearance, systemAppearance, () => 'light' as const);
  return theme === 'system' ? system : theme;
}

/**
 * data-theme / data-palette (+ inline variables for custom) that scope the palette tokens to an element.
 * Custom seeds may be a not-yet-saved drag preview, so their variables go inline instead of the global <style>.
 */
function paletteScope(choice: PaletteChoice, appearance: Appearance) {
  if (choice.kind === 'preset') return { 'data-theme': appearance, 'data-palette': choice.id };
  const vars = appearance === 'dark' ? customPaletteCssVars(choice.seed) : customLightBrandCssVars(choice.seed);
  return { 'data-theme': appearance, 'data-palette': 'custom', style: vars as CSSProperties };
}

/** Primary / accent shown under the hue slider, in the appearance in effect (light = ink / accent). */
function customSwatchColors(seed: string, appearance: Appearance): { primary: string; accent: string } {
  if (appearance === 'dark') {
    const { primary, accent } = deriveCustom(seed).palette;
    return { primary, accent };
  }
  const brand = deriveCustomLight(seed);
  return { primary: brand.ink, accent: brand.accent };
}

function seedHue(seed: string): number {
  return Math.round(oklch(seed)[2]) % 360;
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
  const hueInputRef = useRef<HTMLInputElement | null>(null);
  const previewRef = useRef<HTMLDivElement | null>(null);
  const previewBubbleRef = useRef<HTMLDivElement | null>(null);
  const theme = useAppStore((s) => s.preferences.theme);
  const darkPalette = useAppStore((s) => s.preferences.darkPalette);
  const storedSeed = useAppStore((s) => s.preferences.darkPaletteCustom);
  const appearance = useEffectiveAppearance(theme);
  /** Seed while the hue slider is being dragged: recolors this page only; preferences are written on release. */
  const [draftSeed, setDraftSeed] = useState<string | null>(null);
  /** Last slider position, kept so the thumb does not snap by the hue rounding of its own seed. */
  const [sliderHue, setSliderHue] = useState<number | null>(null);

  const selected: PaletteCardId = draftSeed ? 'custom' : selectedCard(darkPalette, storedSeed);
  const customSeed = draftSeed ?? parseSeed(storedSeed) ?? DEFAULT_CUSTOM_SEED;
  const customChoice: PaletteChoice = { kind: 'custom', seed: customSeed };
  const shownChoice: PaletteChoice = draftSeed ? customChoice : resolvePaletteChoice(darkPalette, storedSeed);
  const choiceOf = (card: PaletteCardId): PaletteChoice => (card === 'custom' ? customChoice : { kind: 'preset', id: card });
  const hue = sliderHue !== null && hueSliderSeed(sliderHue) === customSeed ? sliderHue : seedHue(customSeed);

  // Bring the selected card into the horizontal row on first entry only (not on every pick);
  // scrolls the row itself so the page never jumps vertically.
  useEffect(() => {
    const card = selectedCardRef.current;
    const row = card?.parentElement;
    if (!card || !row || row.scrollWidth <= row.clientWidth) return;
    row.scrollLeft = Math.max(0, card.offsetLeft - row.offsetLeft - (row.clientWidth - card.offsetWidth) / 2);
  }, []);

  const apply = useCallback((action: AppearancePageAction) => {
    const store = getVanillaStore();
    const prefs = store.getState().preferences;
    const writes = appearancePageWrites({ theme: prefs.theme, darkPalette: prefs.darkPalette, seed: prefs.darkPaletteCustom }, action);
    if (writes.theme !== undefined) preferenceOps.updateTheme(store, writes.theme);
    if (writes.palette !== undefined) preferenceOps.updateDarkPalette(store, writes.palette);
  }, []);

  // Release (native `change`: pointer up or a keyboard step) is the only point the slider writes preferences.
  // React's onChange fires on every `input` event, so the commit listens to the native event.
  const customShown = selected === 'custom';
  useEffect(() => {
    const input = hueInputRef.current;
    if (!input) return;
    const commit = () => {
      const value = Number(input.value);
      setSliderHue(value);
      apply({ kind: 'pickSeed', seed: hueSliderSeed(value) });
      setDraftSeed(null);
    };
    input.addEventListener('change', commit);
    return () => input.removeEventListener('change', commit);
  }, [apply, customShown]);

  const onAppearanceKey = (event: KeyboardEvent<HTMLDivElement>) => {
    const step = event.key === 'ArrowRight' || event.key === 'ArrowDown' ? 1 : event.key === 'ArrowLeft' || event.key === 'ArrowUp' ? -1 : 0;
    if (step === 0) return;
    event.preventDefault();
    const rtl = getComputedStyle(event.currentTarget).direction === 'rtl' && (event.key === 'ArrowRight' || event.key === 'ArrowLeft');
    const index = APPEARANCE_SEGMENTS.indexOf(theme);
    const next = APPEARANCE_SEGMENTS[(index + (rtl ? -step : step) + APPEARANCE_SEGMENTS.length) % APPEARANCE_SEGMENTS.length]!;
    apply({ kind: 'setAppearance', theme: next });
    event.currentTarget.querySelector<HTMLButtonElement>(`[data-appearance="${next}"]`)?.focus();
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

  const renderCard = (card: PaletteCardId) => {
    const on = selected === card;
    const name = t(cardLabelKey(card));
    return (
      <button
        key={card}
        ref={on ? selectedCardRef : undefined}
        type="button"
        className={styles.swatch}
        aria-pressed={on}
        aria-label={name}
        data-swatch={card}
        onClick={() => apply({ kind: 'tap', card })}
      >
        <span className={`${styles.cardRing} ${on ? styles.cardRingOn : ''}`} aria-hidden>
          <span className={styles.cardFace} {...paletteScope(choiceOf(card), appearance)}>
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

  // Preview bubble: same stops as the chat bubble, anchored on the preview card. Only re-measured when
  // the card resizes (locale / width); writes style directly, so it never re-renders the page.
  useEffect(() => {
    const box = previewRef.current;
    const bubble = previewBubbleRef.current;
    if (!box || !bubble || typeof ResizeObserver === 'undefined') return;
    const observer = new ResizeObserver(() => {
      const top = bubble.getBoundingClientRect().top - box.getBoundingClientRect().top - box.clientTop;
      const g = anchoredBubbleGradient(box.clientHeight, top);
      bubble.style.backgroundSize = g.backgroundSize;
      bubble.style.backgroundPosition = g.backgroundPosition;
    });
    observer.observe(box);
    return () => observer.disconnect();
  }, []);

  const swatchColors = customSwatchColors(customSeed, appearance);
  const adjusted = deriveCustom(customSeed).adjusted;
  const pickedSeed = parseSeed(customSeed);

  return (
    <div className={styles.page}>
      <BackButton className={styles.backLink} label={tCommon('back')} onClick={() => router.push('/settings')} />
      <h1 className={styles.title}>{t('theme')}</h1>

      <div
        ref={previewRef}
        className={styles.preview}
        data-testid="theme-preview"
        role="img"
        aria-label={tPages('backup.preview')}
        {...paletteScope(shownChoice, appearance)}
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
            <div ref={previewBubbleRef} className={styles.previewBubble}>
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
                <code
                  className={`hljs language-${PREVIEW_CODE_LANG}`}
                  dangerouslySetInnerHTML={{ __html: PREVIEW_CODE_HTML }}
                />
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
        <h2 id="theme-appearance-title" className={styles.groupTitle}>{t('themeAppearance')}</h2>
        <div
          className={styles.segmented}
          role="radiogroup"
          aria-labelledby="theme-appearance-title"
          onKeyDown={onAppearanceKey}
        >
          {APPEARANCE_SEGMENTS.map((option) => {
            const on = theme === option;
            return (
              <button
                key={option}
                type="button"
                role="radio"
                aria-checked={on}
                tabIndex={on ? 0 : -1}
                data-appearance={option}
                className={`${styles.segment} ${on ? styles.segmentOn : ''}`}
                onClick={() => apply({ kind: 'setAppearance', theme: option })}
              >
                {t(appearanceLabelKey(option))}
              </button>
            );
          })}
        </div>
      </section>

      <section className={styles.group}>
        <h2 className={styles.groupTitle}>{t('themeSectionPalettes')}</h2>
        <div className={styles.cardRow}>{PALETTE_CARDS.map(renderCard)}</div>
      </section>

      {customShown && (
        <section
          className={`${styles.group} ${styles.customGroup}`}
          data-testid="theme-custom-color"
          {...paletteScope(customChoice, appearance)}
        >
          <h2 className={styles.groupTitle}>{t('themeCustomColor')}</h2>
          <div className={styles.dotGrid}>
            {CUSTOM_PRESET_DOTS.map((dot) => {
              const on = pickedSeed === dot.seed;
              return (
                <button
                  key={dot.seed}
                  type="button"
                  className={styles.dotButton}
                  aria-pressed={on}
                  aria-label={t(dot.labelKey)}
                  data-seed={dot.seed}
                  onClick={() => {
                    setDraftSeed(null);
                    apply({ kind: 'pickSeed', seed: dot.seed });
                  }}
                >
                  <span className={`${styles.dot} ${on ? styles.dotOn : ''}`} style={{ backgroundColor: dot.seed }} aria-hidden />
                </button>
              );
            })}
          </div>
          <input
            ref={hueInputRef}
            className={styles.hueSlider}
            type="range"
            min={CUSTOM_HUE_SLIDER.min}
            max={CUSTOM_HUE_SLIDER.max}
            step={1}
            value={hue}
            aria-label={t('themeHue')}
            style={{ backgroundImage: HUE_TRACK }}
            onChange={(event) => {
              const value = Number(event.currentTarget.value);
              setSliderHue(value);
              setDraftSeed(hueSliderSeed(value));
            }}
          />
          <div className={styles.customColors}>
            <span className={styles.customColor}>
              <span className={styles.customChip} style={{ backgroundColor: swatchColors.primary }} aria-hidden />
              <span className={styles.customColorName}>{t('themePrimaryColor')}</span>
              <span className={styles.customHex}>{swatchColors.primary}</span>
            </span>
            <span className={styles.customColor}>
              <span className={styles.customChip} style={{ backgroundColor: swatchColors.accent }} aria-hidden />
              <span className={styles.customColorName}>{t('themeAccentColor')}</span>
              <span className={styles.customHex}>{swatchColors.accent}</span>
            </span>
          </div>
          {adjusted && (
            <p className={styles.customNotice} data-testid="theme-custom-adjusted">
              {t(adjusted === 'lightened' ? 'themeCustomLightened' : 'themeCustomDarkened')}
            </p>
          )}
        </section>
      )}
    </div>
  );
}
