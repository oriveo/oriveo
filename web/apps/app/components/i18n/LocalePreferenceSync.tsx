'use client';

/**
 * Keeps the interface language in sync with the stored language preference.
 *
 * The interface language comes from the `NEXT_LOCALE` cookie - that is the only thing SSR's
 * `getLocale()` reads - while the dropdown on the settings page shows `preferences.language`
 * from the store. The two are only written together when the user picks an entry, so any write
 * that does **not** go through that dropdown makes them diverge: the preference becomes
 * `zh-Hans` while the cookie stays English, the dropdown reads "Simplified Chinese", the
 * interface stays English, and the user cannot fix it by clicking - the entry they want is
 * already selected, so `onChange` never fires.
 *
 * This converges on a single exit instead of patching every write site: preferences also arrive
 * through hydration and backup import, and patching them one by one brings the same bug back in
 * another shape as soon as one path is missed.
 *
 * `system` is excluded: it means "follow the browser", so the cookie stays `system` and
 * negotiation decides.
 *
 * The test is the language the server **actually rendered** (`useLocale()`), not "was this
 * language handled before". Remembering only the language skips the second pass when the
 * preference goes zh-Hans -> system -> zh-Hans (choosing System only rewrites the cookie, the
 * marker stays), which brings back "the dropdown says Simplified Chinese, the interface is
 * English".
 */
import { useEffect, useRef } from 'react';
import { useRouter } from 'next/navigation';
import { useLocale } from 'next-intl';
import { useAppStore } from '../../providers/StoreProvider';
import { getLocaleCookie, setLocaleCookie, SUPPORTED_LOCALES, type SupportedLocale } from '../../lib/i18n/locale-utils';

export function LocalePreferenceSync(): null {
  // Select the single field: this component is mounted for the whole app, and a broader
  // selector would re-render it on every unrelated store write.
  const language = useAppStore((s) => s.preferences?.language);
  const renderedLocale = useLocale();
  const router = useRouter();
  // One re-render per "preference -> rendered language" pair: the effect can run again before
  // the refresh settles, and a refresh that did not change the language (offline, for example)
  // must not spin in place.
  const attemptedRef = useRef<string | null>(null);

  useEffect(() => {
    if (
      !language || language === 'system'
      || !SUPPORTED_LOCALES.includes(language as SupportedLocale)
      || renderedLocale === language
    ) {
      // Nothing to chase, or already caught up: unlock so the next divergence is handled.
      attemptedRef.current = null;
      return;
    }
    const attempt = `${language}|${renderedLocale}`;
    if (attemptedRef.current === attempt) return;
    attemptedRef.current = attempt;
    if (getLocaleCookie() !== language) setLocaleCookie(language as SupportedLocale);
    // The cookie is read on the server, so the tree has to be re-rendered for it to take effect.
    router.refresh();
  }, [language, renderedLocale, router]);

  return null;
}
