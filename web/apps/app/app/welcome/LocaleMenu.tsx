'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import { SUPPORTED_LOCALES, setLocaleCookie, type SupportedLocale } from '../../lib/i18n/locale-utils';
import styles from './LocaleMenu.module.css';

const LOCALE_LABELS: Record<SupportedLocale, string> = {
  en: 'English',
  'zh-Hans': '简体中文',
  'zh-Hant': '繁體中文',
  ja: '日本語',
  ko: '한국어',
  es: 'Español',
  fr: 'Français',
  de: 'Deutsch',
  'pt-BR': 'Português',
  ar: 'العربية',
  hi: 'हिन्दी',
  id: 'Bahasa Indonesia',
  vi: 'Tiếng Việt',
  th: 'ไทย',
  tr: 'Türkçe',
  ru: 'Русский',
};

export function LocaleMenu() {
  const locale = useLocale();
  const tSettings = useTranslations('pages.settings');
  const [open, setOpen] = useState(false);
  const wrapperRef = useRef<HTMLDivElement>(null);

  const currentLabel =
    LOCALE_LABELS[locale as SupportedLocale] ?? LOCALE_LABELS.en;

  useEffect(() => {
    if (!open) return;
    const onDocClick = (event: MouseEvent) => {
      if (!wrapperRef.current?.contains(event.target as Node)) {
        setOpen(false);
      }
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setOpen(false);
    };
    document.addEventListener('mousedown', onDocClick);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onDocClick);
      document.removeEventListener('keydown', onKey);
    };
  }, [open]);

  const choose = useCallback(
    (next: SupportedLocale) => {
      setOpen(false);
      if (next === locale) return;
      setLocaleCookie(next);
      // The welcome page messages are resolved from the cookie in RootLayout, a server component, so a
      // full page reload is needed to re-render on the server; the client router's refresh is not enough.
      window.location.reload();
    },
    [locale],
  );

  return (
    <div className={styles.root} ref={wrapperRef}>
      <button
        type="button"
        className={styles.trigger}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label={tSettings('language')}
        onClick={() => setOpen((v) => !v)}
      >
        <GlobeIcon />
        <span className={styles.label}>{currentLabel}</span>
        <ChevronIcon open={open} />
      </button>

      {open && (
        <ul
          className={styles.menu}
          role="listbox"
          aria-label={tSettings('language')}
          onKeyDown={(event) => {
            const items = Array.from(
              event.currentTarget.querySelectorAll<HTMLButtonElement>('[role="option"]'),
            );
            const idx = items.indexOf(event.target as HTMLButtonElement);
            if (event.key === 'ArrowDown') {
              event.preventDefault();
              items[(idx + 1) % items.length]?.focus();
            } else if (event.key === 'ArrowUp') {
              event.preventDefault();
              items[(idx - 1 + items.length) % items.length]?.focus();
            }
          }}
        >
          {SUPPORTED_LOCALES.map((code) => {
            const active = code === locale;
            return (
              <li key={code}>
                <button
                  type="button"
                  role="option"
                  aria-selected={active}
                  className={`${styles.option} ${active ? styles.active : ''}`}
                  onClick={() => choose(code)}
                >
                  <span className={styles.optionLabel}>{LOCALE_LABELS[code]}</span>
                  {active && <CheckIcon />}
                </button>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}

function GlobeIcon() {
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <circle cx="12" cy="12" r="10" />
      <path d="M2 12h20" />
      <path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z" />
    </svg>
  );
}

function ChevronIcon({ open }: { open: boolean }) {
  return (
    <svg
      width="12"
      height="12"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      style={{
        transition: 'transform 200ms ease',
        transform: open ? 'rotate(180deg)' : 'rotate(0)',
      }}
    >
      <path d="M6 9l6 6 6-6" />
    </svg>
  );
}

function CheckIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <polyline points="20 6 9 17 4 12" />
    </svg>
  );
}
